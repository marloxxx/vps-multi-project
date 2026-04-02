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

SERVICE_LIST="traefik postgres redis minio monitoring mysql portainer"
CORE_LIST="traefik postgres redis minio mysql"
LOG_DIR="${STACK_LOG_DIR:-$ROOT/logs}"
AUDIT_LOG_FILE="${STACK_AUDIT_LOG_FILE:-$LOG_DIR/stackctl.log}"
PROJECT_CREDS_FILE="${STACK_PROJECT_CREDS_FILE:-$ROOT/.project-db-credentials.txt}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

audit_log() {
  local action="$1"
  local actor host ts
  actor="${SUDO_USER:-${USER:-unknown}}"
  host="$(hostname 2>/dev/null || echo unknown-host)"
  ts="$(date -Iseconds)"
  printf '%s | host=%s | user=%s | action=%s\n' "$ts" "$host" "$actor" "$action" >> "$AUDIT_LOG_FILE" 2>/dev/null || true
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd"
    return 1
  }
}

generate_secret() {
  require_cmd openssl
  openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

normalise_project_name() {
  local raw="${1:-}"
  local name
  name="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/__+/_/g')"
  [[ -n "$name" ]] || {
    echo "Invalid project name: '$raw'"
    return 1
  }
  echo "$name"
}

sql_escape_single() {
  local s="${1:-}"
  printf "%s" "${s//\'/\'\'}"
}

save_project_credentials() {
  local engine="$1"
  local project="$2"
  local db_name="$3"
  local db_user="$4"
  local db_password="$5"

  {
    echo "# $(date -Iseconds)"
    echo "ENGINE=$engine"
    echo "PROJECT=$project"
    echo "DB_NAME=$db_name"
    echo "DB_USER=$db_user"
    echo "DB_PASSWORD=$db_password"
    echo ""
  } >> "$PROJECT_CREDS_FILE"
  chmod 600 "$PROJECT_CREDS_FILE" 2>/dev/null || true
}

service_compose_file() {
  case "$1" in
    traefik) echo "$ROOT/infra/traefik/docker-compose.yml" ;;
    postgres) echo "$ROOT/services/postgres/docker-compose.yml" ;;
    redis) echo "$ROOT/services/redis/docker-compose.yml" ;;
    minio) echo "$ROOT/services/minio/docker-compose.yml" ;;
    monitoring) echo "$ROOT/services/monitoring/docker-compose.yml" ;;
    mysql) echo "$ROOT/services/mysql/docker-compose.yml" ;;
    portainer) echo "$ROOT/services/portainer/docker-compose.yml" ;;
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

# Bind-mounted MySQL data: Docker does not create the host path for driver local + bind.
prepare_mysql_data_dir() {
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  local dir="${MYSQL_DATA_DIR:-/opt/volumes/mysql}"
  mkdir -p "$dir"
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
    if [[ "$action" == "up" ]]; then
      [[ "$item" != "mysql" ]] || prepare_mysql_data_dir
      compose_run "$item" "$action" -d
    else
      compose_run "$item" "$action"
    fi
  done
}

show_status() {
  audit_log "status"
  echo "==> Docker containers"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

show_services() {
  audit_log "services"
  echo "$SERVICE_LIST"
}

start_service() {
  local target="${1:-core}"
  audit_log "start target=$target"
  case "$target" in
    all) run_on_group up "$SERVICE_LIST" ;;
    core) run_on_group up "$CORE_LIST" ;;
    *)
      require_compose_file "$target"
      echo "==> starting $target"
      [[ "$target" != "mysql" ]] || prepare_mysql_data_dir
      compose_run "$target" up -d
      ;;
  esac
}

stop_service() {
  local target="${1:-core}"
  audit_log "stop target=$target"
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
  audit_log "restart target=$target"
  stop_service "$target"
  start_service "$target"
}

logs_service() {
  local service="${1:-postgres}"
  audit_log "logs service=$service"
  shift || true
  require_compose_file "$service"
  compose_run "$service" logs -f --tail "${TAIL_LINES:-200}" "$@"
}

backup_db() {
  audit_log "backup default-db"
  "$ROOT/scripts/backup-postgres.sh"
}

backup_all_dbs() {
  audit_log "backup all-dbs"
  "$ROOT/scripts/backup-postgres-all-dbs.sh"
}

restore_drill() {
  audit_log "restore-drill dump=${1:-latest}"
  "$ROOT/scripts/restore-drill.sh" "${1:-}"
}

psql_shell() {
  audit_log "psql db=${1:-default}"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  local db="${1:-${POSTGRES_DB:-postgres}}"
  docker exec -it postgres psql -U "$POSTGRES_USER" -d "$db"
}

mysql_shell() {
  audit_log "mysql-shell db=${1:-default}"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a

  local db="${1:-${MYSQL_DATABASE:-}}"
  [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] || {
    echo "MYSQL_ROOT_PASSWORD is not set in $ENV_FILE"
    return 1
  }
  docker ps --format '{{.Names}}' | grep -Fx 'mysql' >/dev/null || {
    echo "MySQL container is not running (expected name: mysql)."
    echo "Start it with: stackctl start mysql"
    return 1
  }

  if [[ -n "$db" ]]; then
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -it mysql mysql -uroot "$db"
  else
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -it mysql mysql -uroot
  fi
}

print_var() {
  local name="$1"
  # shellcheck disable=SC2154
  local value="${!name-}"
  if [[ -n "${value:-}" ]]; then
    printf '%s=%s\n' "$name" "$value"
  else
    printf '%s=%s\n' "$name" "<not-set>"
  fi
}

show_credentials() {
  local target="${1:-all}"
  audit_log "credentials target=$target"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a

  echo "WARNING: showing sensitive values from $ENV_FILE"
  echo "Copy to password manager and avoid sharing this output."
  echo ""

  case "$target" in
    all)
      show_credentials postgres
      echo ""
      show_credentials redis
      echo ""
      show_credentials minio
      echo ""
      show_credentials monitoring
      echo ""
      show_credentials mysql
      echo ""
      show_credentials portainer
      ;;
    postgres)
      echo "[postgres]"
      print_var POSTGRES_USER
      print_var POSTGRES_PASSWORD
      print_var POSTGRES_DB
      ;;
    redis)
      echo "[redis]"
      print_var REDIS_PASSWORD
      ;;
    minio)
      echo "[minio]"
      print_var MINIO_ROOT_USER
      print_var MINIO_ROOT_PASSWORD
      print_var MINIO_API_HOST
      print_var MINIO_CONSOLE_HOST
      ;;
    monitoring|grafana)
      echo "[monitoring]"
      print_var GRAFANA_HOST
      print_var GRAFANA_ADMIN_PASSWORD
      ;;
    mysql)
      echo "[mysql]"
      print_var MYSQL_ROOT_PASSWORD
      print_var MYSQL_DATABASE
      ;;
    portainer)
      echo "[portainer]"
      print_var PORTAINER_HOST
      print_var PORTAINER_TRAEFIK_AUTH
      ;;
    *)
      echo "Unknown credential target: $target"
      echo "Valid targets: all, postgres, redis, minio, monitoring, mysql, portainer"
      return 1
      ;;
  esac
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
  audit_log "open-db-port db=$db_type source=${source_ip:-any}"
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
  audit_log "close-db-port db=$db_type source=${source_ip:-any}"
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
  audit_log "install-bin name=$bin_name"
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

is_running() {
  local name="$1"
  docker ps --format '{{.Names}}' | grep -Fx "$name" >/dev/null
}

check_service_health() {
  local service="$1"
  case "$service" in
    traefik|minio|portainer)
      if is_running "$service"; then
        echo "OK   $service is running"
      else
        echo "FAIL $service is not running"
      fi
      ;;
    postgres)
      if ! is_running postgres; then
        echo "FAIL postgres is not running"
        return
      fi
      set -a
      # shellcheck source=/dev/null
      source "$ENV_FILE"
      set +a
      local pg_db="${POSTGRES_DB:-postgres}"
      if docker exec postgres pg_isready -U "$POSTGRES_USER" -d "$pg_db" >/dev/null 2>&1; then
        echo "OK   postgres accepts connections"
      else
        echo "FAIL postgres is running but not ready"
      fi
      ;;
    redis)
      if ! is_running redis; then
        echo "FAIL redis is not running"
        return
      fi
      set -a
      # shellcheck source=/dev/null
      source "$ENV_FILE"
      set +a
      if docker exec redis redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -Fx "PONG" >/dev/null; then
        echo "OK   redis ping=PONG"
      else
        echo "FAIL redis ping failed"
      fi
      ;;
    mysql)
      if ! is_running mysql; then
        echo "FAIL mysql is not running"
        return
      fi
      set -a
      # shellcheck source=/dev/null
      source "$ENV_FILE"
      set +a
      if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
        echo "WARN mysql running but MYSQL_ROOT_PASSWORD is not set"
      elif docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysqladmin -uroot ping >/dev/null 2>&1; then
        echo "OK   mysql accepts connections"
      else
        echo "FAIL mysql is running but ping failed"
      fi
      ;;
    monitoring)
      local missing=0
      for ctr in prometheus grafana cadvisor; do
        if is_running "$ctr"; then
          echo "OK   $ctr is running"
        else
          echo "FAIL $ctr is not running"
          missing=1
        fi
      done
      [[ "$missing" -eq 0 ]] || true
      ;;
    *)
      echo "Unknown health target: $service"
      echo "Valid targets: all, core, $SERVICE_LIST"
      return 1
      ;;
  esac
}

health_check() {
  local target="${1:-all}"
  audit_log "health target=$target"
  echo "==> Health check ($target)"

  case "$target" in
    all)
      for svc in $SERVICE_LIST; do
        check_service_health "$svc"
      done
      ;;
    core)
      for svc in $CORE_LIST; do
        check_service_health "$svc"
      done
      ;;
    *)
      check_service_health "$target"
      ;;
  esac
}

provision_mysql_project() {
  local raw_project="${1:-}"
  [[ -n "$raw_project" ]] || {
    echo "Usage: stackctl provision-mysql <project-name>"
    return 1
  }
  audit_log "provision-mysql project=$raw_project"

  local project db_name db_user db_password user_host esc_pass
  project="$(normalise_project_name "$raw_project")"
  db_name="${project}_db"
  db_user="${project}_app"
  db_password="$(generate_secret)"
  user_host="${PROJECT_DB_USER_HOST:-%}"
  esc_pass="$(sql_escape_single "$db_password")"

  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a

  [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] || {
    echo "MYSQL_ROOT_PASSWORD is not set in $ENV_FILE"
    return 1
  }
  is_running mysql || {
    echo "MySQL container is not running."
    echo "Start it with: stackctl start mysql"
    return 1
  }

  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "CREATE USER IF NOT EXISTS '$db_user'@'$user_host' IDENTIFIED BY '$esc_pass';"
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "ALTER USER '$db_user'@'$user_host' IDENTIFIED BY '$esc_pass';"
  docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP ON \`$db_name\`.* TO '$db_user'@'$user_host'; FLUSH PRIVILEGES;"

  save_project_credentials "mysql" "$project" "$db_name" "$db_user" "$db_password"

  echo "MySQL project provisioned:"
  echo "  PROJECT=$project"
  echo "  DB_NAME=$db_name"
  echo "  DB_USER=$db_user"
  echo "  DB_PASSWORD=$db_password"
  echo "Saved to: $PROJECT_CREDS_FILE"
}

provision_postgres_project() {
  local raw_project="${1:-}"
  [[ -n "$raw_project" ]] || {
    echo "Usage: stackctl provision-postgres <project-name>"
    return 1
  }
  audit_log "provision-postgres project=$raw_project"

  local project db_name db_user db_password esc_pass role_exists db_exists
  project="$(normalise_project_name "$raw_project")"
  db_name="${project}_db"
  db_user="${project}_app"
  db_password="$(generate_secret)"
  esc_pass="$(sql_escape_single "$db_password")"

  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a

  is_running postgres || {
    echo "PostgreSQL container is not running."
    echo "Start it with: stackctl start postgres"
    return 1
  }

  role_exists="$(docker exec postgres psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_user';" | tr -d '[:space:]')"
  if [[ "$role_exists" == "1" ]]; then
    docker exec postgres psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$db_user\" WITH LOGIN PASSWORD '$esc_pass';"
  else
    docker exec postgres psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$db_user\" WITH LOGIN PASSWORD '$esc_pass';"
  fi

  db_exists="$(docker exec postgres psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name';" | tr -d '[:space:]')"
  if [[ "$db_exists" != "1" ]]; then
    docker exec postgres psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$db_name\" OWNER \"$db_user\";"
  fi

  docker exec postgres psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO \"$db_user\";"

  save_project_credentials "postgres" "$project" "$db_name" "$db_user" "$db_password"

  echo "PostgreSQL project provisioned:"
  echo "  PROJECT=$project"
  echo "  DB_NAME=$db_name"
  echo "  DB_USER=$db_user"
  echo "  DB_PASSWORD=$db_password"
  echo "Saved to: $PROJECT_CREDS_FILE"
}

provision_project_db() {
  local engine="${1:-}"
  local project="${2:-}"
  case "$engine" in
    mysql) provision_mysql_project "$project" ;;
    postgres|pgsql|postgresql) provision_postgres_project "$project" ;;
    *)
      echo "Usage: stackctl provision-db <mysql|postgres> <project-name>"
      return 1
      ;;
  esac
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
  health [core|all|service]    Run basic health checks
  logs <service>               Follow logs for a service
  backup                       Backup default database
  backup-all                   Backup all databases
  restore-drill [dump-file]    Test restore into temp database
  psql [db]                    Open psql shell in postgres container
  mysql [db]                   Open mysql shell in mysql container
  provision-mysql <project>    Create isolated mysql db/user/password
  provision-postgres <project> Create isolated postgres db/user/password
  provision-db <engine> <name> Create isolated db/user/password
  credentials [service|all]    Show credentials from .env
  open-db-port [db] [ip]       Open DB firewall port (db: postgres|mysql)
  close-db-port [db] [ip]      Close DB firewall port (db: postgres|mysql)
  install-bin [name]           Install /usr/bin command (default: stackctl)
  menu                         Interactive menu
  help                         Show this help

Examples:
  ./scripts/stack-manage.sh status
  ./scripts/stack-manage.sh start all
  ./scripts/stack-manage.sh health all
  ./scripts/stack-manage.sh logs postgres
  ./scripts/stack-manage.sh mysql app
  ./scripts/stack-manage.sh provision-db mysql billing
  ./scripts/stack-manage.sh provision-db postgres clay_erp
  ./scripts/stack-manage.sh credentials postgres
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
5) Health check
6) Start one service
7) Stop one service
8) Logs one service
9) Backup default DB
10) Backup all DBs
11) Restore drill
12) Open psql shell
13) Open mysql shell
14) Provision MySQL project DB
15) Provision PostgreSQL project DB
16) Show credentials
17) Install /usr/bin command
0) Exit
EOF
    read -r -p "Choose: " choice
    case "$choice" in
      1) show_status ;;
      2) start_service core ;;
      3) stop_service core ;;
      4) restart_service core ;;
      5)
        read -r -p "Target (core/all/service) [all]: " target
        health_check "${target:-all}"
        ;;
      6)
        read -r -p "Service name ($(show_services)): " svc
        start_service "$svc"
        ;;
      7)
        read -r -p "Service name ($(show_services)): " svc
        stop_service "$svc"
        ;;
      8)
        read -r -p "Service name ($(show_services)): " svc
        logs_service "$svc"
        ;;
      9) backup_db ;;
      10) backup_all_dbs ;;
      11)
        read -r -p "Dump file path (empty = latest): " dump
        restore_drill "$dump"
        ;;
      12)
        read -r -p "Database name (empty = POSTGRES_DB or postgres): " db
        psql_shell "$db"
        ;;
      13)
        read -r -p "Database name (empty = MYSQL_DATABASE): " db
        mysql_shell "$db"
        ;;
      14)
        read -r -p "Project name: " project
        provision_mysql_project "$project"
        ;;
      15)
        read -r -p "Project name: " project
        provision_postgres_project "$project"
        ;;
      16)
        read -r -p "Target (all/postgres/redis/minio/monitoring/mysql/portainer) [all]: " target
        show_credentials "${target:-all}"
        ;;
      17)
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
  health) health_check "${2:-all}" ;;
  logs) logs_service "${2:-postgres}" ;;
  backup) backup_db ;;
  backup-all) backup_all_dbs ;;
  restore-drill) restore_drill "${2:-}" ;;
  psql) psql_shell "${2:-}" ;;
  mysql) mysql_shell "${2:-}" ;;
  provision-mysql) provision_mysql_project "${2:-}" ;;
  provision-postgres) provision_postgres_project "${2:-}" ;;
  provision-db) provision_project_db "${2:-}" "${3:-}" ;;
  credentials) show_credentials "${2:-all}" ;;
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
