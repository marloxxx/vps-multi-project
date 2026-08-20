#!/usr/bin/env bash
#
# Install / update / remove the stack auto-backup cron (/etc/cron.d/stack-backup).
#
# Usage:
#   ./scripts/install-auto-backup.sh enable
#   ./scripts/install-auto-backup.sh disable
#   ./scripts/install-auto-backup.sh status
#
set -euo pipefail
OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
set -a && source "$ENV_FILE" && set +a

CRON_FILE="/etc/cron.d/stack-backup"
BACKUP_SCRIPT="$ROOT/scripts/auto-backup.sh"
# Standard cron: minute hour day month weekday
BACKUP_SCHEDULE="${BACKUP_CRON:-0 3 * * *}"
LOG_FILE="${BACKUP_LOG:-$OPT_BASE/backups/auto-backup.log}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

action="${1:-status}"

write_cron() {
  local schedule="$1"
  mkdir -p "$OPT_BASE/backups/postgres" "$OPT_BASE/backups/mysql" "$(dirname "$LOG_FILE")"
  chmod +x "$ROOT/scripts/auto-backup.sh" \
    "$ROOT/scripts/backup-postgres.sh" \
    "$ROOT/scripts/backup-postgres-all-dbs.sh" \
    "$ROOT/scripts/backup-mysql-all-dbs.sh" 2>/dev/null || true

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by stack install-auto-backup.sh / stackctl auto-backup
# Do not edit by hand — re-run: stackctl auto-backup enable
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${schedule} root STACK_ROOT=${ROOT} OPT_BASE=${OPT_BASE} ENV_FILE=${ENV_FILE} ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1
EOF
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    install -m 644 "$tmp" "$CRON_FILE"
  else
    sudo install -m 644 "$tmp" "$CRON_FILE"
  fi
  rm -f "$tmp"
  echo "Installed $CRON_FILE"
  echo "  schedule : $schedule"
  echo "  script   : $BACKUP_SCRIPT"
  echo "  log      : $LOG_FILE"
  echo "  retention: ${RETENTION_DAYS} day(s) (BACKUP_RETENTION_DAYS)"
  warn_drive_required
}

warn_drive_required() {
  case "${BACKUP_REQUIRE_RCLONE:-1}" in
    0|false|no|off) return 0 ;;
  esac
  if [[ -z "${BACKUP_RCLONE_REMOTE:-}" ]]; then
    echo ""
    echo "WARNING: BACKUP_RCLONE_REMOTE is not set."
    echo "  Local dumps on this VPS are not enough if the server is lost."
    echo "  Next steps:"
    echo "    stackctl auto-backup gdrive-setup"
    echo "    # add to .env: BACKUP_RCLONE_REMOTE=gdrive:vps-backups/\$(hostname)"
    echo "    stackctl auto-backup gdrive-check && stackctl auto-backup run"
    echo "  (Or set BACKUP_REQUIRE_RCLONE=0 for local-only — not recommended.)"
  fi
}

remove_cron() {
  if [[ ! -f "$CRON_FILE" ]]; then
    echo "Auto-backup cron not installed ($CRON_FILE missing)."
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    rm -f "$CRON_FILE"
  else
    sudo rm -f "$CRON_FILE"
  fi
  echo "Removed $CRON_FILE"
}

show_status() {
  echo "Auto-backup status (off-site Drive = primary safety)"
  echo "  cron file : $CRON_FILE"
  if [[ -f "$CRON_FILE" ]]; then
    echo "  installed : yes"
    echo "  contents:"
    sed 's/^/    /' "$CRON_FILE"
  else
    echo "  installed : no"
  fi
  echo "  schedule  : ${BACKUP_SCHEDULE} (BACKUP_CRON)"
  echo "  retention : ${RETENTION_DAYS} day(s) local staging"
  echo "  pg mode   : ${BACKUP_POSTGRES_MODE:-all}"
  echo "  mysql     : ${BACKUP_INCLUDE_MYSQL:-auto}"
  echo "  require off-site: ${BACKUP_REQUIRE_RCLONE:-1}"
  if [[ -n "${BACKUP_RCLONE_REMOTE:-}" ]]; then
    echo "  rclone    : ${BACKUP_RCLONE_REMOTE} (mode=${BACKUP_RCLONE_MODE:-copy})"
    if command -v rclone >/dev/null 2>&1; then
      echo "  rclone bin: $(command -v rclone)"
    else
      echo "  rclone bin: MISSING — stackctl auto-backup gdrive-setup"
    fi
  else
    echo "  rclone    : NOT CONFIGURED — backups are not VPS-failure safe"
    echo "              → stackctl auto-backup gdrive-setup"
  fi
  echo "  log       : $LOG_FILE"
  if [[ -f "$LOG_FILE" ]]; then
    echo "  last log lines:"
    tail -n 8 "$LOG_FILE" | sed 's/^/    /'
  fi
}

case "$action" in
  enable|install)
    write_cron "$BACKUP_SCHEDULE"
    ;;
  disable|remove|uninstall)
    remove_cron
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}"
    exit 1
    ;;
esac
