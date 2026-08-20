#!/usr/bin/env bash
#
# Backup every non-system database on the mysql container.
#
# Usage:
#   ./scripts/backup-mysql-all-dbs.sh
#   DB_PREFIX=myapp_ ./scripts/backup-mysql-all-dbs.sh
#
set -euo pipefail
OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
set -a && source "$ENV_FILE" && set +a

[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] || {
  echo "MYSQL_ROOT_PASSWORD is not set in $ENV_FILE"
  exit 1
}

docker ps --format '{{.Names}}' | grep -Fx 'mysql' >/dev/null || {
  echo "MySQL container is not running (expected name: mysql)."
  exit 1
}

BACKUP_DIR="${BACKUP_DIR_MYSQL:-${BACKUP_DIR:-$OPT_BASE/backups/mysql}}"
# If BACKUP_DIR still points at postgres path from .env, prefer dedicated mysql dir
if [[ "$BACKUP_DIR" == *"/postgres"* && -z "${BACKUP_DIR_MYSQL:-}" ]]; then
  BACKUP_DIR="$OPT_BASE/backups/mysql"
fi
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
PREFIX="${DB_PREFIX:-${TENANT_PREFIX:-}}"

list_dbs() {
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -N -e \
    "SELECT schema_name FROM information_schema.schemata
     WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')
     ORDER BY schema_name;"
}

count=0
while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  if [[ -n "$PREFIX" && "$db" != ${PREFIX}* ]]; then
    continue
  fi
  FILE="$BACKUP_DIR/mysql_${db}_${STAMP}.sql.gz"
  echo "Backing up $db -> $FILE"
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
    mysqldump -uroot --single-transaction --routines --triggers --events "$db" \
    | gzip > "$FILE"
  count=$((count + 1))
done < <(list_dbs)

echo "Done. $count MySQL dump(s) in $BACKUP_DIR"
