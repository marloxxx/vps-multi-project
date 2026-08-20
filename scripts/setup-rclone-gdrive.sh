#!/usr/bin/env bash
#
# One-time helper: install rclone (if missing) and guide Google Drive remote setup.
# OAuth still requires a browser / interactive rclone config.
#
# Usage:
#   ./scripts/setup-rclone-gdrive.sh
#   ./scripts/setup-rclone-gdrive.sh check
#
set -euo pipefail
OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

REMOTE_NAME="${BACKUP_RCLONE_REMOTE_NAME:-gdrive}"
# Path on Drive after remote name (folder will be created on first upload)
REMOTE_PATH="${BACKUP_RCLONE_PATH:-vps-backups/$(hostname -s 2>/dev/null || hostname)}"
SUGGESTED_REMOTE="${REMOTE_NAME}:${REMOTE_PATH}"

action="${1:-guide}"

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    echo "rclone already installed: $(command -v rclone) ($(rclone version 2>/dev/null | head -1))"
    return 0
  fi
  echo "Installing rclone (official script)…"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    curl -fsSL https://rclone.org/install.sh | bash
  else
    curl -fsSL https://rclone.org/install.sh | sudo bash
  fi
  command -v rclone >/dev/null 2>&1 || {
    echo "rclone install failed. Install manually: https://rclone.org/install/"
    exit 1
  }
}

print_guide() {
  cat <<EOF

=== rclone → Google Drive (stack auto-backup) ===

1) Install rclone (skipped if already present):
   curl https://rclone.org/install.sh | sudo bash

2) Configure a remote as the same user that runs cron (usually root):
   sudo rclone config
   - n) New remote
   - name: ${REMOTE_NAME}
   - Storage: Google Drive (drive)
   - client_id / client_secret: leave blank (or use your own OAuth client)
   - scope: 1 (Full access) or 2 (drive.file)
   - Complete browser auth (use rclone authorize on a machine with a browser
     if this VPS has no GUI, then paste the token)

3) Test:
   sudo rclone lsd ${REMOTE_NAME}:
   sudo rclone mkdir ${SUGGESTED_REMOTE}
   sudo rclone copy /opt/backups ${SUGGESTED_REMOTE} -P

4) Enable in /opt/stack/.env:
   BACKUP_RCLONE_REMOTE=${SUGGESTED_REMOTE}
   # BACKUP_RCLONE_MODE=copy    # copy = keep remote extras; sync = mirror local
   # BACKUP_RCLONE_CONFIG=/root/.config/rclone/rclone.conf

5) Re-run cron install + test:
   stackctl auto-backup enable
   stackctl auto-backup run

Security: rclone token lives in ~/.config/rclone/rclone.conf (chmod 600).
Do not commit it to git.

EOF
}

check_remote() {
  local remote="${BACKUP_RCLONE_REMOTE:-$SUGGESTED_REMOTE}"
  if ! command -v rclone >/dev/null 2>&1; then
    echo "FAIL rclone binary not found"
    exit 1
  fi
  echo "Checking remote: $remote"
  if [[ -n "${BACKUP_RCLONE_CONFIG:-}" ]]; then
    rclone --config "$BACKUP_RCLONE_CONFIG" lsd "$(echo "$remote" | cut -d: -f1):" >/dev/null
  else
    rclone lsd "$(echo "$remote" | cut -d: -f1):" >/dev/null
  fi
  echo "OK remote reachable"
  echo "Suggested .env line:"
  echo "  BACKUP_RCLONE_REMOTE=$remote"
}

case "$action" in
  guide|"")
    install_rclone
    print_guide
    ;;
  check)
    check_remote
    ;;
  install)
    install_rclone
    ;;
  *)
    echo "Usage: $0 {guide|check|install}"
    exit 1
    ;;
esac
