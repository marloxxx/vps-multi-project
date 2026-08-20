#!/usr/bin/env bash
#
# Scheduled / on-demand stack backup (Drive-first safety model):
#   1. dump Postgres (+ MySQL if running) to local /opt/backups
#   2. prune local dumps older than BACKUP_RETENTION_DAYS
#   3. upload to Google Drive / off-site via rclone (BACKUP_RCLONE_REMOTE)
#
# Local dumps alone are not considered safe if the VPS dies — off-site is required
# unless BACKUP_REQUIRE_RCLONE=0.
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

# Off-site (rclone) — primary safety. Example: gdrive:vps-backups/my-server
RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:-}"
RCLONE_MODE="${BACKUP_RCLONE_MODE:-copy}"     # copy | sync
RCLONE_BIN="${BACKUP_RCLONE_BIN:-rclone}"
RCLONE_CONFIG_FILE="${BACKUP_RCLONE_CONFIG:-}"
RCLONE_ARGS="${BACKUP_RCLONE_ARGS:---transfers=4 --checkers=8}"
# Fail the job if off-site upload did not run successfully (default: on)
REQUIRE_RCLONE="${BACKUP_REQUIRE_RCLONE:-1}"

mkdir -p "$PG_BACKUP_DIR" "$MYSQL_BACKUP_DIR" "$(dirname "$LOG_FILE")"

log() {
  local line
  line="$(date -Iseconds) $*"
  echo "$line" | tee -a "$LOG_FILE"
}

require_rclone_on() {
  case "$REQUIRE_RCLONE" in
    1|true|yes|on|TRUE|YES|ON) return 0 ;;
    *) return 1 ;;
  esac
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
  if [[ -z "$RCLONE_REMOTE" ]]; then
    if require_rclone_on; then
      log "ERROR off-site backup required but BACKUP_RCLONE_REMOTE is unset"
      log "ERROR local dumps alone are not safe if this VPS is lost — set Drive remote:"
      log "ERROR   stackctl auto-backup gdrive-setup"
      log "ERROR   then BACKUP_RCLONE_REMOTE=gdrive:vps-backups/<hostname> in .env"
      log "ERROR (or set BACKUP_REQUIRE_RCLONE=0 to allow local-only)"
      return 1
    fi
    log "WARN SKIP rclone — BACKUP_RCLONE_REMOTE unset (local-only; not VPS-failure safe)"
    return 0
  fi

  if ! command -v "$RCLONE_BIN" >/dev/null 2>&1; then
    log "ERROR rclone not found (install: stackctl auto-backup gdrive-setup). Remote was: $RCLONE_REMOTE"
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
  log "Off-site (rclone ${RCLONE_MODE}): $LOCAL_BACKUP_ROOT -> $RCLONE_REMOTE"
  if ! "$RCLONE_BIN" "$RCLONE_MODE" \
    "${conf_args[@]}" \
    "${extra[@]}" \
    --log-level INFO \
    "$LOCAL_BACKUP_ROOT" \
    "$RCLONE_REMOTE"; then
    log "ERROR rclone ${RCLONE_MODE} to Drive/remote FAILED — dumps may exist only on this VPS"
    return 1
  fi
  log "Off-site upload OK → $RCLONE_REMOTE"
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

# ---------- Retention (local staging) ----------
prune_dir "$PG_BACKUP_DIR" "$RETENTION_DAYS"
prune_dir "$MYSQL_BACKUP_DIR" "$RETENTION_DAYS"

# ---------- Off-site (required for safety) ----------
if ! rclone_upload; then
  rc=1
fi

if [[ "$rc" -eq 0 ]]; then
  log "==== auto-backup OK (local + off-site) ===="
else
  log "==== auto-backup FINISHED WITH ERRORS ===="
fi
exit "$rc"
