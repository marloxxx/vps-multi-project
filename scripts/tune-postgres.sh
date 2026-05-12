#!/usr/bin/env bash
# Apply PostgreSQL ALTER SYSTEM tuning, then you must restart the postgres container.
# Override any value via env before running, e.g.:
#   TUNE_SHARED_BUFFERS=1GB ./scripts/tune-postgres.sh
#
# Defaults target a ~16 GiB RAM host with Postgres + other services; adjust down for smaller VPS.
set -euo pipefail

OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
set -a && source "$ENV_FILE" && set +a

[[ -n "${POSTGRES_USER:-}" ]] || { echo "POSTGRES_USER is not set in $ENV_FILE"; exit 1; }

docker ps --filter name=^postgres$ --filter status=running --format '{{.Names}}' | grep -qx postgres || {
  echo "Postgres container 'postgres' is not running."
  exit 1
}

# --- defaults (override via env) ---
TUNE_SHARED_BUFFERS="${TUNE_SHARED_BUFFERS:-2GB}"
TUNE_EFFECTIVE_CACHE_SIZE="${TUNE_EFFECTIVE_CACHE_SIZE:-10GB}"
TUNE_WORK_MEM="${TUNE_WORK_MEM:-4MB}"
TUNE_MAINTENANCE_WORK_MEM="${TUNE_MAINTENANCE_WORK_MEM:-512MB}"
TUNE_MAX_CONNECTIONS="${TUNE_MAX_CONNECTIONS:-80}"
TUNE_MAX_WAL_SIZE="${TUNE_MAX_WAL_SIZE:-2GB}"
TUNE_CHECKPOINT_TIMEOUT="${TUNE_CHECKPOINT_TIMEOUT:-15min}"
TUNE_CHECKPOINT_COMPLETION_TARGET="${TUNE_CHECKPOINT_COMPLETION_TARGET:-0.9}"
# SSD-friendly planner hints (set TUNE_RANDOM_PAGE_COST=4 to skip if HDD)
TUNE_RANDOM_PAGE_COST="${TUNE_RANDOM_PAGE_COST:-1.1}"
TUNE_EFFECTIVE_IO_CONCURRENCY="${TUNE_EFFECTIVE_IO_CONCURRENCY:-200}"

echo "Applying ALTER SYSTEM (user=$POSTGRES_USER) …"
docker exec -i postgres psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET shared_buffers = '${TUNE_SHARED_BUFFERS}';
ALTER SYSTEM SET effective_cache_size = '${TUNE_EFFECTIVE_CACHE_SIZE}';
ALTER SYSTEM SET work_mem = '${TUNE_WORK_MEM}';
ALTER SYSTEM SET maintenance_work_mem = '${TUNE_MAINTENANCE_WORK_MEM}';
ALTER SYSTEM SET max_connections = '${TUNE_MAX_CONNECTIONS}';
ALTER SYSTEM SET max_wal_size = '${TUNE_MAX_WAL_SIZE}';
ALTER SYSTEM SET checkpoint_timeout = '${TUNE_CHECKPOINT_TIMEOUT}';
ALTER SYSTEM SET checkpoint_completion_target = '${TUNE_CHECKPOINT_COMPLETION_TARGET}';
ALTER SYSTEM SET random_page_cost = '${TUNE_RANDOM_PAGE_COST}';
ALTER SYSTEM SET effective_io_concurrency = '${TUNE_EFFECTIVE_IO_CONCURRENCY}';
SQL

echo ""
echo "Done. shared_buffers and max_connections require a full Postgres restart (not reload)."
echo "Restart:"
echo "  docker compose -f ${ROOT}/services/postgres/docker-compose.yml --env-file ${ENV_FILE} restart postgres"
echo "Or:  cd ${ROOT} && ./scripts/stack-manage.sh restart postgres"
echo ""
echo "Verify after restart:"
echo "  docker exec postgres psql -U \"\$POSTGRES_USER\" -d postgres -c \"SHOW shared_buffers; SHOW work_mem; SHOW max_wal_size;\""
