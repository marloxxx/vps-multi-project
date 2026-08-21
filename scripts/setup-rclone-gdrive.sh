#!/usr/bin/env bash
#
# One-time helper: install rclone (if missing) and guide Google Drive remote setup.
# OAuth still requires a browser / interactive rclone config.
#
# Usage:
#   ./scripts/setup-rclone-gdrive.sh
#   ./scripts/setup-rclone-gdrive.sh check
#   ./scripts/setup-rclone-gdrive.sh install
#
set -euo pipefail
OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$STACK_ROOT"
[[ -f "$ROOT/.env" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

REMOTE_NAME="${BACKUP_RCLONE_REMOTE_NAME:-gdrive}"
REMOTE_PATH="${BACKUP_RCLONE_PATH:-vps-backups/$(hostname -s 2>/dev/null || hostname)}"
SUGGESTED_REMOTE="${REMOTE_NAME}:${REMOTE_PATH}"

action="${1:-guide}"

run_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "arm-v7" ;;
    *)
      echo "unsupported arch: $(uname -m)" >&2
      return 1
      ;;
  esac
}

# BusyBox unzip lacks -a; official install.sh breaks on some Ubuntu images.
ensure_gnu_unzip() {
  if command -v unzip >/dev/null 2>&1; then
    if unzip -h 2>&1 | grep -q -- '-a'; then
      return 0
    fi
    echo "Replacing BusyBox unzip with GNU unzip…"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update -qq
    run_root apt-get install -y unzip
  elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y unzip
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y unzip
  else
    echo "WARN: could not install GNU unzip via package manager"
  fi
}

install_rclone_deb() {
  local arch tmp deb
  arch="$(detect_arch)"
  [[ "$arch" == "amd64" || "$arch" == "arm64" ]] || return 1
  tmp="$(mktemp -d)"
  deb="$tmp/rclone-current-linux-${arch}.deb"
  echo "Downloading rclone .deb (linux-${arch})…"
  curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${arch}.deb" -o "$deb"
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get install -y "$deb" || run_root dpkg -i "$deb"
  else
    run_root dpkg -i "$deb"
  fi
  rm -rf "$tmp"
}

install_rclone_zip() {
  local arch tmp zipdir ver
  arch="$(detect_arch)"
  ensure_gnu_unzip
  tmp="$(mktemp -d)"
  echo "Downloading rclone zip (linux-${arch})…"
  curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${arch}.zip" -o "$tmp/rclone.zip"
  unzip -q "$tmp/rclone.zip" -d "$tmp"
  zipdir="$(find "$tmp" -maxdepth 1 -type d -name 'rclone-v*' | head -1)"
  [[ -n "$zipdir" && -x "$zipdir/rclone" ]] || {
    echo "Failed to extract rclone binary"
    rm -rf "$tmp"
    return 1
  }
  run_root cp "$zipdir/rclone" /usr/bin/rclone
  run_root chmod 755 /usr/bin/rclone
  run_root mkdir -p /usr/share/man/man1
  [[ -f "$zipdir/rclone.1" ]] && run_root cp "$zipdir/rclone.1" /usr/share/man/man1/rclone.1 || true
  rm -rf "$tmp"
  ver="$(rclone version 2>/dev/null | head -1 || true)"
  echo "Installed /usr/bin/rclone ($ver)"
}

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    echo "rclone already installed: $(command -v rclone) ($(rclone version 2>/dev/null | head -1))"
    return 0
  fi

  # 1) Distro package (simple, may be older)
  if command -v apt-get >/dev/null 2>&1; then
    echo "Trying apt install rclone…"
    run_root apt-get update -qq
    if run_root apt-get install -y rclone; then
      command -v rclone >/dev/null 2>&1 && {
        echo "rclone installed via apt: $(rclone version 2>/dev/null | head -1)"
        return 0
      }
    fi
  fi

  # 2) Official .deb (avoids BusyBox unzip -a bug in install.sh)
  if install_rclone_deb 2>/dev/null && command -v rclone >/dev/null 2>&1; then
    echo "rclone installed via .deb: $(rclone version 2>/dev/null | head -1)"
    return 0
  fi

  # 3) Zip + GNU unzip → /usr/bin/rclone
  if install_rclone_zip && command -v rclone >/dev/null 2>&1; then
    return 0
  fi

  # 4) Official script (needs GNU unzip)
  echo "Falling back to official install.sh (needs GNU unzip)…"
  ensure_gnu_unzip
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    curl -fsSL https://rclone.org/install.sh | bash
  else
    curl -fsSL https://rclone.org/install.sh | sudo bash
  fi

  command -v rclone >/dev/null 2>&1 || {
    echo "rclone install failed."
    echo "Manual (Ubuntu):"
    echo "  apt-get update && apt-get install -y unzip"
    echo "  curl -O https://downloads.rclone.org/rclone-current-linux-amd64.deb"
    echo "  dpkg -i rclone-current-linux-amd64.deb"
    exit 1
  }
}

print_guide() {
  cat <<EOF

=== rclone → Google Drive (stack auto-backup) ===

1) Install rclone (this script already tried):
   stackctl auto-backup gdrive-setup
   # or: apt-get install -y rclone
   # or: dpkg -i rclone-current-linux-amd64.deb

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
   # BACKUP_RCLONE_MODE=copy
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
    echo "FAIL rclone binary not found — run: stackctl auto-backup gdrive-setup"
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
