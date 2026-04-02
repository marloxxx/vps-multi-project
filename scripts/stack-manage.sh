#!/usr/bin/env bash
#
# Stack management helper for /opt/stack.
# Supports command mode and interactive menu mode.
#
set -euo pipefail

OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required."; exit 1; }

SERVICE_LIST="traefik postgres redis minio monitoring"
CORE_LIST="traefik postgres redis minio"

service_compose_file() {
  case "$1" in
    traefik) echo "$ROOT/infra/traefik/docker-compose.yml" ;;
    postgres) echo "$ROOT/services/postgres/docker-compose.yml" ;;
    redis) echo "$ROOT/services/redis/docker-compose.yml" ;;
    minio) echo "$ROOT/services/minio/docker-compose.yml" ;;
    monitoring) echo "$ROOT/services/monitoring/docker-compose.yml" ;;
    *)
      echo "Unknown service: $1"
      echo "Valid services: $SERVICE_LIST"
      return 1
      ;;
  esac
}

require_compose_file() {
  local file
  file="$(service_compose_file "$1")" || return 1
  [[ -f "$file" ]] || {
    echo "Compose file not found for service '$1': $file"
    return 1
  }
}

compose_run() {
  local service="$1"
  shift
  local file
  file="$(service_compose_file "$service")"
  docker compose -f "$file" --env-file "$ENV_FILE" "$@"
}

run_on_group() {
  local action="$1"
  local group="$2"
  local item
  for item in $group; do
    require_compose_file "$item" || continue
    echo "==> $action $item"
    compose_run "$item" "$action" -d
  done
}

show_status() {
  echo "==> Docker containers"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

show_services() {
  echo "$SERVICE_LIST"
}

start_service() {
  local target="${1:-core}"
  case "$target" in
    all) run_on_group up "$SERVICE_LIST" ;;
    core) run_on_group up "$CORE_LIST" ;;
    *)
      require_compose_file "$target"
      echo "==> starting $target"
      compose_run "$target" up -d
      ;;
  esac
}

stop_service() {
  local target="${1:-core}"
  case "$target" in
    all) run_on_group down "$SERVICE_LIST" ;;
    core) run_on_group down "$CORE_LIST" ;;
    *)
      require_compose_file "$target"
      echo "==> stopping $target"
      compose_run "$target" down
      ;;
  esac
}

restart_service() {
  local target="${1:-core}"
  stop_service "$target"
  start_service "$target"
}

logs_service() {
  local service="${1:-postgres}"
  shift || true
  require_compose_file "$service"
  compose_run "$service" logs -f --tail "${TAIL_LINES:-200}" "$@"
}

backup_db() {
  "$ROOT/scripts/backup-postgres.sh"
}

backup_all_dbs() {
  "$ROOT/scripts/backup-postgres-all-dbs.sh"
}

restore_drill() {
  "$ROOT/scripts/restore-drill.sh" "${1:-}"
}

psql_shell() {
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  local db="${1:-$POSTGRES_DB}"
  docker exec -it postgres psql -U "$POSTGRES_USER" -d "$db"
}

db_port() {
  case "${1:-}" in
    postgres|pgsql|postgresql) echo "5432" ;;
    mysql) echo "3306" ;;
    *)
      echo "Unsupported database type: ${1:-}"
      echo "Use one of: postgres, mysql"
      return 1
      ;;
  esac
}

open_db_port() {
  local db_type="${1:-postgres}"
  local source_ip="${2:-}"
  local port
  port="$(db_port "$db_type")"

  if [[ -n "$source_ip" ]]; then
    echo "Opening ${db_type} (${port}/tcp) for ${source_ip}"
    sudo ufw allow from "$source_ip" to any port "$port" proto tcp
    echo "Rule added. Close later with:"
    echo "  stackctl close-db-port $db_type $source_ip"
  else
    echo "Opening ${db_type} (${port}/tcp) for any source (less safe)"
    sudo ufw allow "${port}/tcp"
    echo "Rule added. Close later with:"
    echo "  stackctl close-db-port $db_type"
  fi
}

close_db_port() {
  local db_type="${1:-postgres}"
  local source_ip="${2:-}"
  local port
  port="$(db_port "$db_type")"

  if [[ -n "$source_ip" ]]; then
    echo "Closing ${db_type} (${port}/tcp) for ${source_ip}"
    sudo ufw delete allow from "$source_ip" to any port "$port" proto tcp
  else
    echo "Closing ${db_type} (${port}/tcp) for any source"
    sudo ufw delete allow "${port}/tcp"
  fi
}

install_bin() {
  local bin_name="${1:-stackctl}"
  local target="/usr/bin/$bin_name"
  local source_script="$ROOT/scripts/stack-manage.sh"

  [[ -f "$source_script" ]] || {
    echo "Script not found: $source_script"
    return 1
  }

  chmod +x "$source_script"
  echo "Installing symlink: $target -> $source_script"
  sudo ln -sf "$source_script" "$target"
  echo "Installed. Use: $bin_name menu"
}

print_help() {
  cat <<'EOF'
Usage:
  ./scripts/stack-manage.sh <command> [args]
  ./scripts/stack-manage.sh menu

Commands:
  status                       Show running containers
  services                     Show service names
  start [core|all|service]     Start stack/service (default: core)
  stop [core|all|service]      Stop stack/service (default: core)
  restart [core|all|service]   Restart stack/service (default: core)
  logs <service>               Follow logs for a service
  backup                       Backup default database
  backup-all                   Backup all databases
  restore-drill [dump-file]    Test restore into temp database
  psql [db]                    Open psql shell in postgres container
  open-db-port [db] [ip]       Open DB firewall port (db: postgres|mysql)
  close-db-port [db] [ip]      Close DB firewall port (db: postgres|mysql)
  install-bin [name]           Install /usr/bin command (default: stackctl)
  menu                         Interactive menu
  help                         Show this help

Examples:
  ./scripts/stack-manage.sh status
  ./scripts/stack-manage.sh start all
  ./scripts/stack-manage.sh logs postgres
  ./scripts/stack-manage.sh open-db-port postgres 203.0.113.10
  ./scripts/stack-manage.sh install-bin stackctl
EOF
}

menu_loop() {
  while true; do
    cat <<'EOF'

Stack Management Menu
1) Status
2) Start core
3) Stop core
4) Restart core
5) Start one service
6) Stop one service
7) Logs one service
8) Backup default DB
9) Backup all DBs
10) Restore drill
11) Open psql shell
12) Install /usr/bin command
0) Exit
EOF
    read -r -p "Choose: " choice
    case "$choice" in
      1) show_status ;;
      2) start_service core ;;
      3) stop_service core ;;
      4) restart_service core ;;
      5)
        read -r -p "Service name ($(show_services)): " svc
        start_service "$svc"
        ;;
      6)
        read -r -p "Service name ($(show_services)): " svc
        stop_service "$svc"
        ;;
      7)
        read -r -p "Service name ($(show_services)): " svc
        logs_service "$svc"
        ;;
      8) backup_db ;;
      9) backup_all_dbs ;;
      10)
        read -r -p "Dump file path (empty = latest): " dump
        restore_drill "$dump"
        ;;
      11)
        read -r -p "Database name (empty = POSTGRES_DB): " db
        psql_shell "$db"
        ;;
      12)
        read -r -p "Command name (default stackctl): " name
        install_bin "${name:-stackctl}"
        ;;
      0) exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

cmd="${1:-menu}"
case "$cmd" in
  status) show_status ;;
  services) show_services ;;
  start) start_service "${2:-core}" ;;
  stop) stop_service "${2:-core}" ;;
  restart) restart_service "${2:-core}" ;;
  logs) logs_service "${2:-postgres}" ;;
  backup) backup_db ;;
  backup-all) backup_all_dbs ;;
  restore-drill) restore_drill "${2:-}" ;;
  psql) psql_shell "${2:-}" ;;
  open-db-port) open_db_port "${2:-postgres}" "${3:-}" ;;
  close-db-port) close_db_port "${2:-postgres}" "${3:-}" ;;
  install-bin) install_bin "${2:-stackctl}" ;;
  menu) menu_loop ;;
  help|-h|--help) print_help ;;
  *)
    echo "Unknown command: $cmd"
    print_help
    exit 1
    ;;
esac
