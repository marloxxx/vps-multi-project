#!/usr/bin/env bash
#
# Backup every database on the postgres container.
# Skips template DBs and the default "postgres" DB name.
#
# Usage:
#   ./scripts/backup-postgres-all-dbs.sh
#   DB_PREFIX=myapp_ ./scripts/backup-postgres-all-dbs.sh   # only DBs starting with myapp_
#
set -euo pipefail
OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
set -a && source "$ENV_FILE" && set +a

BACKUP_DIR="${BACKUP_DIR:-$OPT_BASE/backups/postgres}"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
PREFIX="${DB_PREFIX:-${TENANT_PREFIX:-}}"

list_dbs() {
  docker exec postgres psql -U "$POSTGRES_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"
}

while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  [[ "$db" == "postgres" ]] && continue
  if [[ -n "$PREFIX" && "$db" != ${PREFIX}* ]]; then
    continue
  fi
  FILE="$BACKUP_DIR/pg_${db}_${STAMP}.sql.gz"
  echo "Backing up $db -> $FILE"
  docker exec postgres pg_dump -U "$POSTGRES_USER" "$db" | gzip > "$FILE"
done < <(list_dbs)

echo "Done. Backups in $BACKUP_DIR"
