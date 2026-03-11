#!/usr/bin/env bash
#
# Restore drill – proves backups are restorable without touching production DB.
# Creates a temporary database, restores latest (or given) dump, then drops it.
#
# Usage:
#   ./scripts/restore-drill.sh              # uses latest .sql.gz in BACKUP_DIR
#   ./scripts/restore-drill.sh /path/to/dump.sql.gz
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
DUMP="${1:-}"

if [[ -z "$DUMP" ]]; then
  DUMP="$(ls -t "$BACKUP_DIR"/pg_*.sql.gz 2>/dev/null | head -1)"
  [[ -n "$DUMP" && -f "$DUMP" ]] || { echo "No dump found in $BACKUP_DIR"; exit 1; }
  echo "Using latest backup: $DUMP"
else
  [[ -f "$DUMP" ]] || { echo "File not found: $DUMP"; exit 1; }
fi

DB_NAME="restore_drill_$(date +%Y%m%d_%H%M%S)"

echo "==> Creating temp database $DB_NAME"
docker exec postgres psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\";"

echo "==> Restoring (this may take a while)"
gunzip -c "$DUMP" | docker exec -i postgres psql -U "$POSTGRES_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q

echo "==> Restore finished – verifying connection"
docker exec postgres psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "SELECT current_database(), now();"

# Non-interactive: RESTORE_DRILL_AUTO_DROP=1 ./scripts/restore-drill.sh
if [[ "${RESTORE_DRILL_AUTO_DROP:-0}" == "1" ]]; then
  ans=y
else
  read -r -p "Drop temp database $DB_NAME? [Y/n] " ans
fi
if [[ "${ans:-Y}" =~ ^[Yy]|^$ ]]; then
  docker exec postgres psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE \"$DB_NAME\";"
  echo "Dropped $DB_NAME – drill complete."
else
  echo "Left $DB_NAME in place – drop manually: DROP DATABASE \"$DB_NAME\";"
fi
