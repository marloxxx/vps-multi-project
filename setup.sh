#!/usr/bin/env bash
#
# First-time server setup: .env + secrets, Docker stacks, monitoring, host (swap, SSH port, ufw, fail2ban, cron).
# Run from /opt/stack after clone.
#
set -euo pipefail

# ---------- styling ----------
if [[ -t 1 ]]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  BOLD='' DIM='' GREEN='' YELLOW='' CYAN='' NC=''
fi

step() { echo -e "${GREEN}==>${NC} ${BOLD}$*${NC}"; }
info() { echo -e "    ${DIM}$*${NC}"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }

# ---------- paths ----------
OPT_BASE="${OPT_BASE:-/opt}"
STACK_ROOT="${STACK_ROOT:-$OPT_BASE/stack}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT/.env"
EXAMPLE="$ROOT/.env.example"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"
CREDENTIALS_FILE="$ROOT/.setup-credentials.txt"
SSH_PORT_FILE="$ROOT/.ssh-port"
STACKCTL_BIN_NAME="${STACKCTL_BIN_NAME:-stackctl}"
AUTO_INSTALL_STACKCTL="${AUTO_INSTALL_STACKCTL:-1}"
AUTO_INSTALL_DOCKER="${AUTO_INSTALL_DOCKER:-0}"

# ---------- portable sed in-place ----------
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# ---------- ensure .env ----------
ensure_env() {
  if [[ -f "$ENV_FILE" ]]; then
    step "Using existing $ENV_FILE"
    return 0
  fi
  if [[ ! -f "$EXAMPLE" ]]; then
    echo "Missing $EXAMPLE – cannot create .env"
    exit 1
  fi
  echo -e "\n${BOLD}First-time configuration${NC}"
  echo "Base domain (Traefik/Let's Encrypt) and ACME email."
  echo ""
  local base_domain email
  if [[ -n "${BASE_DOMAIN:-}" && -n "${ACME_EMAIL:-}" ]]; then
    base_domain="$BASE_DOMAIN"
    email="$ACME_EMAIL"
    info "Using BASE_DOMAIN and ACME_EMAIL from environment"
  else
    read -r -p "Base domain (e.g. mycompany.com): " base_domain
    read -r -p "ACME / Let's Encrypt email: " email
    base_domain="${base_domain// /}"
    email="${email// /}"
  fi
  if [[ -z "$base_domain" || -z "$email" ]]; then
    echo "Base domain and email are required."
    exit 1
  fi
  cp "$EXAMPLE" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  sed_inplace "s|^BASE_DOMAIN=.*|BASE_DOMAIN=${base_domain}|" "$ENV_FILE"
  sed_inplace "s|^ACME_EMAIL=.*|ACME_EMAIL=${email}|" "$ENV_FILE"
  if grep -q 'example.com' "$ENV_FILE"; then
    read -r -p "Replace example.com with ${base_domain} in .env? [Y/n] " ans
    if [[ "${ans:-Y}" =~ ^[Yy]|^$ ]]; then
      sed_inplace "s|example.com|${base_domain}|g" "$ENV_FILE"
      info "Host placeholders updated to ${base_domain}"
    fi
  fi
  step "Created $ENV_FILE"
  echo ""
}

# ---------- generate secrets into .env + stash for final print ----------
generate_secrets() {
  local need_gen=0
  if [[ "${REGENERATE_SECRETS:-0}" == "1" ]]; then
    need_gen=1
  elif grep -qE 'change_me|POSTGRES_PASSWORD=change_me|REDIS_PASSWORD=change_me|MINIO_ROOT_PASSWORD=change_me|POSTGRES_PASSWORD=change_me_strong' "$ENV_FILE" 2>/dev/null; then
    need_gen=1
  fi
  [[ "$need_gen" -eq 1 ]] || return 0

  step "Generating random passwords for .env"
  local pg redis minio grafana
  pg="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  redis="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  minio="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  sed_inplace "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg}|" "$ENV_FILE"
  sed_inplace "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${redis}|" "$ENV_FILE"
  sed_inplace "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${minio}|" "$ENV_FILE"
  if grep -q '^GRAFANA_HOST=' "$ENV_FILE"; then
    grafana="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    if grep -q '^GRAFANA_ADMIN_PASSWORD=' "$ENV_FILE"; then
      sed_inplace "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${grafana}|" "$ENV_FILE"
    else
      echo "GRAFANA_ADMIN_PASSWORD=${grafana}" >> "$ENV_FILE"
    fi
  fi
  # Stash for credentials file (no SSH port yet)
  {
    echo "# Generated $(date -Iseconds) – delete after copying to a password manager"
    echo "POSTGRES_PASSWORD=${pg}"
    echo "REDIS_PASSWORD=${redis}"
    echo "MINIO_ROOT_PASSWORD=${minio}"
    [[ -n "${grafana:-}" ]] && echo "GRAFANA_ADMIN_PASSWORD=${grafana}"
  } > "$CREDENTIALS_FILE"
  chmod 600 "$CREDENTIALS_FILE"
  info "Secrets written to .env and $CREDENTIALS_FILE"
}

# ---------- preflight ----------
run_priv() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$AUTO_INSTALL_DOCKER" != "1" ]]; then
    echo "Docker not available. Install and start Docker then re-run."
    echo "Tip: run with AUTO_INSTALL_DOCKER=1 to auto-install Docker."
    exit 1
  fi

  step "Docker not found – installing (AUTO_INSTALL_DOCKER=1)"

  if command -v apt-get >/dev/null 2>&1; then
    local os_id codename arch
    os_id="$(. /etc/os-release && echo "${ID:-ubuntu}")"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    arch="$(dpkg --print-architecture)"
    if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
      codename="$(lsb_release -cs)"
    fi
    [[ -n "$codename" ]] || { echo "Cannot detect distro codename for Docker repo."; exit 1; }

    run_priv apt-get update -qq
    run_priv apt-get install -y ca-certificates curl gnupg lsb-release
    run_priv install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | run_priv gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    run_priv chmod a+r /etc/apt/keyrings/docker.gpg
    printf '%s\n' "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${codename} stable" | run_priv tee /etc/apt/sources.list.d/docker.list >/dev/null
    run_priv apt-get update -qq
    run_priv apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    run_priv systemctl enable --now docker || run_priv service docker start || true
  elif command -v dnf >/dev/null 2>&1; then
    run_priv dnf install -y docker docker-compose-plugin
    run_priv systemctl enable --now docker || true
  elif command -v yum >/dev/null 2>&1; then
    run_priv yum install -y docker docker-compose-plugin
    run_priv systemctl enable --now docker || run_priv service docker start || true
  else
    echo "Unsupported distro for auto-install. Install Docker manually and re-run."
    exit 1
  fi

  docker info >/dev/null 2>&1 || { echo "Docker install completed but daemon is not ready."; exit 1; }
  step "Docker is installed and running"
}

preflight() {
  if [[ "$ROOT" != "$STACK_ROOT" && "${SKIP_OPT_CHECK:-0}" != "1" ]]; then
    echo "Run from $STACK_ROOT (clone repo there first)."
    exit 1
  fi
  install_docker_if_missing
}

# ---------- docker phase ----------
docker_phase() {
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a

  export POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-$OPT_BASE/volumes/postgres}"
  export REDIS_DATA_DIR="${REDIS_DATA_DIR:-$OPT_BASE/volumes/redis}"
  export MINIO_DATA_DIR="${MINIO_DATA_DIR:-$OPT_BASE/volumes/minio}"
  export BACKUP_DIR="${BACKUP_DIR:-$OPT_BASE/backups/postgres}"
  export PROMETHEUS_DATA_DIR="${PROMETHEUS_DATA_DIR:-$OPT_BASE/volumes/prometheus}"
  export GRAFANA_DATA_DIR="${GRAFANA_DATA_DIR:-$OPT_BASE/volumes/grafana}"
  export PORTAINER_DATA_DIR="${PORTAINER_DATA_DIR:-$OPT_BASE/volumes/portainer}"

  step "Docker networks (proxy, backend)"
  for net in proxy backend; do
    docker network inspect "$net" >/dev/null 2>&1 && info "$net exists" || { docker network create "$net"; info "created $net"; }
  done

  local acme="$ROOT/infra/traefik/acme.json"
  if [[ ! -f "$acme" ]]; then
    install -m 600 /dev/null "$acme"
    step "Created acme.json (mode 600)"
  else
    chmod 600 "$acme" 2>/dev/null || true
  fi

  mkdir -p "$POSTGRES_DATA_DIR" "$REDIS_DATA_DIR" "$MINIO_DATA_DIR" "$BACKUP_DIR" \
    "$PROMETHEUS_DATA_DIR" "$GRAFANA_DATA_DIR" "$PORTAINER_DATA_DIR"

  step "Starting Traefik"
  docker compose -f "$ROOT/infra/traefik/docker-compose.yml" --env-file "$ENV_FILE" up -d
  step "Starting PostgreSQL"
  docker compose -f "$ROOT/services/postgres/docker-compose.yml" --env-file "$ENV_FILE" up -d
  step "Starting Redis"
  docker compose -f "$ROOT/services/redis/docker-compose.yml" --env-file "$ENV_FILE" up -d
  step "Starting MinIO"
  docker compose -f "$ROOT/services/minio/docker-compose.yml" --env-file "$ENV_FILE" up -d

  if [[ -f "$ROOT/services/monitoring/docker-compose.yml" && "${START_MONITORING:-1}" == "1" ]] && \
     grep -q '^GRAFANA_HOST=' "$ENV_FILE"; then
    step "Starting monitoring (Prometheus + Grafana + cAdvisor)"
    docker compose -f "$ROOT/services/monitoring/docker-compose.yml" --env-file "$ENV_FILE" up -d
  else
    info "Monitoring skipped (set GRAFANA_HOST in .env and START_MONITORING=1 to enable)"
  fi

  if [[ -f "$ROOT/services/portainer/docker-compose.yml" && "${START_PORTAINER:-1}" == "1" ]] && \
     grep -q '^PORTAINER_HOST=' "$ENV_FILE"; then
    step "Starting Portainer"
    docker compose -f "$ROOT/services/portainer/docker-compose.yml" --env-file "$ENV_FILE" up -d
  else
    info "Portainer skipped (set PORTAINER_HOST in .env and START_PORTAINER=1 to enable)"
  fi

  if [[ -f "$ROOT/apps/clay-erp/docker-compose.yml" && "${START_CLAY_ERP:-0}" == "1" ]]; then
    step "Starting clay-erp"
    docker compose -f "$ROOT/apps/clay-erp/docker-compose.yml" --env-file "$ENV_FILE" pull
    docker compose -f "$ROOT/apps/clay-erp/docker-compose.yml" --env-file "$ENV_FILE" up -d
  else
    info "App stack skipped (START_CLAY_ERP=1 if needed)"
  fi
}

# ---------- host phase: swap, SSH port, ufw, fail2ban, cron ----------
host_phase() {
  step "Host: swap, SSH port, firewall, fail2ban, cron (sudo once)"
  chmod +x "$ROOT/scripts/backup-postgres.sh" "$ROOT/scripts/backup-postgres-all-dbs.sh" 2>/dev/null || true

  # Random SSH port 20000–40000 (pick before sudo; pass into heredoc)
  local SSH_PORT
  if [[ -f "$SSH_PORT_FILE" ]] && [[ "${REGENERATE_SSH_PORT:-0}" != "1" ]]; then
    SSH_PORT="$(tr -d ' \n' < "$SSH_PORT_FILE")"
  else
    SSH_PORT=$(shuf -i 20000-40000 -n 1)
  fi

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || echo "Enter sudo password:"
  # Pass vars via env; single heredoc so entire block runs as root
  sudo env SSH_PORT="$SSH_PORT" OPT_BASE="$OPT_BASE" ROOT="$ROOT" SWAP_FILE="$SWAP_FILE" SWAP_SIZE_GB="$SWAP_SIZE_GB" bash <<'ROOTSCRIPT'
set -euo pipefail
echo "==> Swap (${SWAP_SIZE_GB}G at ${SWAP_FILE})"
if swapon --show 2>/dev/null | grep -qF "$SWAP_FILE"; then echo "  already active"
elif [[ -f "$SWAP_FILE" ]]; then swapon "$SWAP_FILE" 2>/dev/null || true
else
  fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_FILE" 2>/dev/null || \
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE"; swapon "$SWAP_FILE"
  grep -qF "$SWAP_FILE" /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  echo "  enabled"
fi
echo "==> SSH port ${SSH_PORT} (ufw first)"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${SSH_PORT}/tcp" comment 'ssh stack' || true
  ufw allow 80/tcp comment 'http' || true
  ufw allow 443/tcp comment 'https' || true
  ufw allow 22/tcp comment 'ssh legacy until migrate' || true
else echo "  ufw not installed"; fi
echo "==> sshd Port ${SSH_PORT}"
mkdir -p /etc/ssh/sshd_config.d
[[ -f /etc/ssh/sshd_config ]] && { sed -i.bak 's/^Port 22$/#Port 22/' /etc/ssh/sshd_config 2>/dev/null || sed -i '' 's/^Port 22$/#Port 22/' /etc/ssh/sshd_config 2>/dev/null || true; }
echo "Port ${SSH_PORT}" > /etc/ssh/sshd_config.d/99-stack-port.conf
chmod 644 /etc/ssh/sshd_config.d/99-stack-port.conf
if sshd -t 2>/dev/null; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
  echo "  sshd restarted – ssh -p ${SSH_PORT} user@host"
else echo "  sshd -t failed; reverted"; rm -f /etc/ssh/sshd_config.d/99-stack-port.conf; fi
echo "$SSH_PORT" > "$ROOT/.ssh-port"; chmod 600 "$ROOT/.ssh-port"
command -v ufw >/dev/null 2>&1 && ufw --force enable || true
echo "==> fail2ban sshd ports ${SSH_PORT},22"
if ! command -v fail2ban-client >/dev/null 2>&1; then
  command -v apt-get >/dev/null && apt-get update -qq && apt-get install -y fail2ban || \
  command -v dnf >/dev/null && dnf install -y fail2ban || \
  command -v yum >/dev/null && yum install -y fail2ban || true
fi
mkdir -p /etc/fail2ban/jail.d
printf '%s\n' '[sshd]' 'enabled = true' "port = ${SSH_PORT},22" 'logpath = %(sshd_log)s' 'backend = %(sshd_backend)s' 'maxretry = 5' 'findtime = 10m' 'bantime = 1h' > /etc/fail2ban/jail.d/stack-sshd.local
systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null || true
echo "==> Cron backup 03:00"
mkdir -p "$OPT_BASE/backups/postgres"
{ echo "SHELL=/bin/bash"; echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; echo "0 3 * * * root $ROOT/scripts/backup-postgres.sh >> $OPT_BASE/backups/postgres/cron.log 2>&1"; } > /etc/cron.d/stack-backup
chmod 644 /etc/cron.d/stack-backup
echo "  /etc/cron.d/stack-backup"
ROOTSCRIPT

  # Append SSH port to credentials file (create file if only SSH was configured)
  if [[ -f "$SSH_PORT_FILE" ]]; then
    [[ -f "$CREDENTIALS_FILE" ]] || echo "# Setup $(date -Iseconds)" > "$CREDENTIALS_FILE"
    echo "" >> "$CREDENTIALS_FILE"
    echo "SSH_PORT=$(cat "$SSH_PORT_FILE")" >> "$CREDENTIALS_FILE"
    echo "# ssh -p $(cat "$SSH_PORT_FILE") user@this-server" >> "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
  fi
  # Also store in .env for operators
  if [[ -f "$SSH_PORT_FILE" ]]; then
    if grep -q '^SSH_PORT=' "$ENV_FILE" 2>/dev/null; then
      sed_inplace "s|^SSH_PORT=.*|SSH_PORT=$(cat "$SSH_PORT_FILE")|" "$ENV_FILE"
    else
      echo "SSH_PORT=$(cat "$SSH_PORT_FILE")" >> "$ENV_FILE"
    fi
  fi
}

# ---------- install stack manage command ----------
install_stackctl_bin() {
  [[ "$AUTO_INSTALL_STACKCTL" == "1" ]] || {
    info "Skipping stackctl install (AUTO_INSTALL_STACKCTL=0)"
    return 0
  }

  local source_script="$ROOT/scripts/stack-manage.sh"
  local target="/usr/bin/$STACKCTL_BIN_NAME"

  if [[ ! -f "$source_script" ]]; then
    warn "Skipping stackctl install: missing $source_script"
    return 0
  fi

  chmod +x "$source_script"
  step "Installing /usr/bin/$STACKCTL_BIN_NAME"
  sudo ln -sf "$source_script" "$target"
  info "Use command: $STACKCTL_BIN_NAME menu"
}

# ---------- final banner ----------
print_credentials_banner() {
  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    return 0
  fi
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  SAVE THESE NOW – shown once. Copy to a password manager then delete:${NC}"
  echo -e "  ${DIM}$CREDENTIALS_FILE${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [[ -f "$CREDENTIALS_FILE" ]]; then
    cat "$CREDENTIALS_FILE"
  fi
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  warn "Delete $CREDENTIALS_FILE after copying. Optionally: sudo ufw deny 22/tcp once logged in on new SSH port."
  echo ""
}

# ---------- main ----------
echo -e "${BOLD}VPS stack setup${NC} (${ROOT})"
preflight
ensure_env
generate_secrets
docker_phase
host_phase
install_stackctl_bin
print_credentials_banner

step "Finished"
info "Data: $OPT_BASE/volumes  |  Backups: $OPT_BASE/backups/postgres"
info "Restore drill: $ROOT/scripts/restore-drill.sh"
