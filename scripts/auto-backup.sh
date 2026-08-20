#!/usr/bin/env bash
#
# Scheduled / on-demand stack backup:
#   - all Postgres DBs (default), or only POSTGRES_DB if BACKUP_POSTGRES_MODE=default
#   - all MySQL DBs when container is up (unless BACKUP_INCLUDE_MYSQL=0)
#   - prune dumps older than BACKUP_RETENTION_DAYS
#   - optional off-site upload via rclone (Google Drive, etc.) when BACKUP_RCLONE_REMOTE is set
#
# Usage:
#   ./scripts/auto-backup.sh
#   BACKUP_RETENTION_DAYS=14 ./scripts/auto-backup.sh
#
set -euo pipefail
OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
set -a && source "$ENV_FILE" && set +a

PG_BACKUP_DIR="${BACKUP_DIR:-$OPT_BASE/backups/postgres}"
MYSQL_BACKUP_DIR="${BACKUP_DIR_MYSQL:-$OPT_BASE/backups/mysql}"
LOCAL_BACKUP_ROOT="${BACKUP_UPLOAD_DIR:-$OPT_BASE/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
POSTGRES_MODE="${BACKUP_POSTGRES_MODE:-all}"   # all | default
INCLUDE_MYSQL="${BACKUP_INCLUDE_MYSQL:-auto}" # auto | 1 | 0
LOG_FILE="${BACKUP_LOG:-$OPT_BASE/backups/auto-backup.log}"

# Off-site (rclone). Empty remote = skip.
# Example: BACKUP_RCLONE_REMOTE=gdrive:vps-backups/my-server
RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:-}"
RCLONE_MODE="${BACKUP_RCLONE_MODE:-copy}"     # copy | sync
RCLONE_BIN="${BACKUP_RCLONE_BIN:-rclone}"
RCLONE_CONFIG_FILE="${BACKUP_RCLONE_CONFIG:-}"
# Extra flags, space-separated (quoted tokens not supported — keep simple)
# Example: BACKUP_RCLONE_ARGS=--transfers=4 --checkers=8
RCLONE_ARGS="${BACKUP_RCLONE_ARGS:---transfers=4 --checkers=8}"

mkdir -p "$PG_BACKUP_DIR" "$MYSQL_BACKUP_DIR" "$(dirname "$LOG_FILE")"

log() {
  local line
  line="$(date -Iseconds) $*"
  echo "$line" | tee -a "$LOG_FILE"
}

prune_dir() {
  local dir="$1"
  local days="$2"
  [[ -d "$dir" ]] || return 0
  [[ "$days" =~ ^[0-9]+$ ]] || {
    log "WARN invalid BACKUP_RETENTION_DAYS='$days' — skip prune in $dir"
    return 0
  }
  [[ "$days" -eq 0 ]] && {
    log "Retention disabled (BACKUP_RETENTION_DAYS=0) for $dir"
    return 0
  }
  local removed
  removed="$(find "$dir" -type f \( -name 'pg_*.sql.gz' -o -name 'mysql_*.sql.gz' \) -mtime "+${days}" -print -delete 2>/dev/null | wc -l | tr -d ' ')"
  log "Pruned $removed file(s) older than ${days}d in $dir"
}

is_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fx "$1" >/dev/null
}

rclone_upload() {
  [[ -n "$RCLONE_REMOTE" ]] || {
    log "SKIP rclone (BACKUP_RCLONE_REMOTE unset)"
    return 0
  }

  if ! command -v "$RCLONE_BIN" >/dev/null 2>&1; then
    log "ERROR rclone not found (install rclone, or set BACKUP_RCLONE_BIN). Remote was: $RCLONE_REMOTE"
    return 1
  fi

  local conf_args=()
  if [[ -n "$RCLONE_CONFIG_FILE" ]]; then
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
      log "ERROR BACKUP_RCLONE_CONFIG not found: $RCLONE_CONFIG_FILE"
      return 1
    fi
    conf_args=(--config "$RCLONE_CONFIG_FILE")
  fi

  case "$RCLONE_MODE" in
    copy|sync) ;;
    *)
      log "ERROR invalid BACKUP_RCLONE_MODE='$RCLONE_MODE' (use copy or sync)"
      return 1
      ;;
  esac

  # shellcheck disable=SC2206
  local extra=( $RCLONE_ARGS )
  log "rclone ${RCLONE_MODE}: $LOCAL_BACKUP_ROOT -> $RCLONE_REMOTE"
  # Prefer dumps + log; skip nothing critical under backups root
  if ! "$RCLONE_BIN" "$RCLONE_MODE" \
    "${conf_args[@]}" \
    "${extra[@]}" \
    --log-level INFO \
    "$LOCAL_BACKUP_ROOT" \
    "$RCLONE_REMOTE"; then
    log "ERROR rclone ${RCLONE_MODE} failed"
    return 1
  fi
  log "rclone ${RCLONE_MODE} OK"
  return 0
}

log "==== auto-backup start ===="
rc=0

# ---------- Postgres ----------
if is_running postgres; then
  case "$POSTGRES_MODE" in
    default)
      log "Postgres: backing up default DB (${POSTGRES_DB:-postgres})"
      if ! "$ROOT/scripts/backup-postgres.sh"; then
        log "ERROR postgres default backup failed"
        rc=1
      fi
      ;;
    all|*)
      log "Postgres: backing up all databases"
      if ! "$ROOT/scripts/backup-postgres-all-dbs.sh"; then
        log "ERROR postgres all-dbs backup failed"
        rc=1
      fi
      ;;
  esac
else
  log "SKIP postgres (container not running)"
fi

# ---------- MySQL ----------
should_mysql=0
case "$INCLUDE_MYSQL" in
  1|true|yes|on) should_mysql=1 ;;
  0|false|no|off) should_mysql=0 ;;
  auto|*)
    if is_running mysql && [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
      should_mysql=1
    fi
    ;;
esac

if [[ "$should_mysql" -eq 1 ]]; then
  if is_running mysql; then
    log "MySQL: backing up all databases"
    if ! BACKUP_DIR_MYSQL="$MYSQL_BACKUP_DIR" "$ROOT/scripts/backup-mysql-all-dbs.sh"; then
      log "ERROR mysql backup failed"
      rc=1
    fi
  else
    log "SKIP mysql (BACKUP_INCLUDE_MYSQL requested but container not running)"
  fi
else
  log "SKIP mysql (disabled or not configured)"
fi

# ---------- Retention (local) ----------
prune_dir "$PG_BACKUP_DIR" "$RETENTION_DAYS"
prune_dir "$MYSQL_BACKUP_DIR" "$RETENTION_DAYS"

# ---------- Off-site (rclone → Google Drive / S3 / …) ----------
# Run after prune so `sync` mirrors local retention; `copy` keeps remote extras.
if ! rclone_upload; then
  rc=1
fi

if [[ "$rc" -eq 0 ]]; then
  log "==== auto-backup OK ===="
else
  log "==== auto-backup FINISHED WITH ERRORS ===="
fi
exit "$rc"
