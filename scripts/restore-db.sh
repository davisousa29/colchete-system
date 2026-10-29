#!/usr/bin/env bash
# Restaura um backup POR CIMA do banco de produção do Colchete.
#
# Uso:
#   ./scripts/restore-db.sh                    → lista os backups disponíveis (servidor e R2)
#   ./scripts/restore-db.sh --ultimo           → restaura o backup mais recente do servidor
#   ./scripts/restore-db.sh colchete_AAAA-MM-DD_HHMM.dump
#                                              → restaura esse arquivo (do servidor ou, se não
#                                                estiver mais aqui, baixado do R2)
#
# O que ele faz, nesta ordem:
#   1. confere se o arquivo de backup é legível (antes de tirar o app do ar)
#   2. pede confirmação: é preciso digitar RESTAURAR
#   3. coloca a API em manutenção e para a fila e o agendador
#   4. faz um backup de SEGURANÇA do estado atual (a restauração pode ser desfeita)
#   5. apaga o conteúdo do banco e restaura o backup escolhido
#   6. roda as migrations (se o backup for anterior a alguma)
#   7. religa fila, agendador e a API, e mostra contagens para conferência
set -Eeuo pipefail  # -E: o tratamento de erro também vale dentro das funções

BACKUP_DIR="/srv/colchete/backups"
REMOTE="r2crypt:"
LOG="$BACKUP_DIR/restore.log"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKEND="colchete_backend"
POSTGRES="colchete_postgres"
WORKERS=(colchete_queue colchete_scheduler)

log() { echo "[$(date -u +%FT%TZ)] $*"; }
artisan() { docker exec -u www-data "$BACKEND" php artisan "$@"; }
psql_prod() { docker exec "$POSTGRES" sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -v ON_ERROR_STOP=1 $1"; }

listar() {
  echo "Backups no servidor (últimos 7 dias, mais recentes primeiro):"
  ls -1t "$BACKUP_DIR"/colchete_*.dump 2>/dev/null | head -10 | xargs -r -n1 basename || true
  echo
  echo "Backups no R2 (últimos 30 dias, mais recentes primeiro):"
  rclone lsf "$REMOTE" | sort -r | head -10
  echo
  echo "Uso: $0 --ultimo  |  $0 colchete_AAAA-MM-DD_HHMM.dump"
}

if [ $# -ne 1 ]; then
  listar
  exit 1
fi

# ── 1. Localiza o arquivo ─────────────────────────────────────────────────────
TMP_DIR=""
limpar_tmp() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; return 0; }
trap limpar_tmp EXIT

if [ "$1" = "--ultimo" ]; then
  ARQUIVO="$(ls -1t "$BACKUP_DIR"/colchete_*.dump 2>/dev/null | head -1 || true)"
  [ -n "$ARQUIVO" ] || { echo "Nenhum backup encontrado em $BACKUP_DIR."; exit 1; }
else
  NOME="$(basename "$1")"
  if ! [[ "$NOME" =~ ^colchete_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.dump$ ]]; then
    echo "Nome inválido: $NOME (esperado: colchete_AAAA-MM-DD_HHMM.dump)"
    exit 1
  fi

  if [ -f "$BACKUP_DIR/$NOME" ]; then
    ARQUIVO="$BACKUP_DIR/$NOME"
  else
    log "Não está no servidor; baixando do R2: $NOME"
    TMP_DIR="$(mktemp -d)"
    rclone copy "${REMOTE}${NOME}" "$TMP_DIR"
    ARQUIVO="$TMP_DIR/$NOME"
    [ -s "$ARQUIVO" ] || { echo "Arquivo não encontrado no R2: $NOME"; exit 1; }
  fi
fi

# Lê o índice do dump: arquivo corrompido falha aqui, com o app ainda no ar
if ! docker exec -i "$POSTGRES" pg_restore --list < "$ARQUIVO" > /dev/null; then
  echo "O arquivo não é um backup válido: $ARQUIVO"
  exit 1
fi

# ── 2. Confirmação ────────────────────────────────────────────────────────────
echo
echo "Backup escolhido: $(basename "$ARQUIVO")  ($(du -h "$ARQUIVO" | cut -f1))"
echo "O banco de PRODUÇÃO volta ao estado desse backup. Tudo o que foi gravado"
echo "depois do horário dele (UTC, no nome do arquivo) deixa de existir no banco."
echo "A API fica em manutenção durante a restauração (geralmente menos de 1 minuto)."
echo
read -r -p "Digite RESTAURAR para continuar: " RESPOSTA
[ "$RESPOSTA" = "RESTAURAR" ] || { echo "Cancelado. Nada foi alterado."; exit 1; }

# Daqui em diante, tudo também vai para o log
exec > >(tee -a "$LOG") 2>&1
log "Restauração iniciada: $(basename "$ARQUIVO")"

SEGURANCA=""
falhou() {
  log "ERRO: a restauração falhou. A API continua EM MANUTENÇÃO e a fila/agendador parados."
  if [ -n "$SEGURANCA" ]; then
    log "Para voltar ao estado de antes: $0 $(basename "$SEGURANCA")"
  fi
}
trap falhou ERR

# ── 3. Manutenção ─────────────────────────────────────────────────────────────
log "3/7 Colocando a API em manutenção e parando fila e agendador"
artisan down --retry=60
docker stop "${WORKERS[@]}" > /dev/null

# ── 4. Backup de segurança do estado atual ────────────────────────────────────
log "4/7 Backup de segurança do estado atual"
"$SCRIPTS_DIR/backup-db.sh"
SEGURANCA="$(ls -1t "$BACKUP_DIR"/colchete_*.dump | head -1)"
log "Backup de segurança: $(basename "$SEGURANCA")"

# ── 5. Restauração ────────────────────────────────────────────────────────────
# Recria o schema vazio em vez de --clean: assim não sobra nenhuma tabela criada
# depois do backup (que faria as migrations do passo 6 falharem com "already exists")
log "5/7 Restaurando o banco"
psql_prod "-c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'" > /dev/null
docker exec -i "$POSTGRES" sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error --single-transaction' \
  < "$ARQUIVO"

# ── 6. Migrations ─────────────────────────────────────────────────────────────
log "6/7 Aplicando migrations pendentes"
artisan migrate --force

# ── 7. Religa tudo ────────────────────────────────────────────────────────────
log "7/7 Religando fila, agendador e API"
docker start "${WORKERS[@]}" > /dev/null
artisan queue:restart
artisan up
trap - ERR

log "Restauração concluída. Conferência:"
psql_prod "-c \"select (select count(*) from users) as usuarios,
                      (select count(*) from subscriptions) as assinaturas,
                      (select count(*) from payments) as pagamentos;\""

echo
echo "PRÓXIMO PASSO (obrigatório): no painel do Asaas, confira as cobranças pagas depois"
echo "do horário do backup e, em Integrações > Logs de Webhooks, use 'Reenviar' em cada uma,"
echo "para que as assinaturas pagas nesse intervalo sejam ativadas de novo."