# Server hardening & ops (optional)

All of this is **host / Docker / Traefik** only.

---

## Docker daemon – log rotation

`/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

Restart Docker after editing.

---

## Compose

- **Resource limits** – `deploy.resources.limits` so one container cannot exhaust the host.
- **Healthchecks** – optional; Traefik can use them with extra labels if you add them.

---

## Traefik

- **Rate limiting** – middleware on sensitive routes.
- **Basic auth** – in front of Portainer/Grafana (see compose comment blocks + htpasswd).
- **IP allowlist** – middleware to restrict admin UIs to known IPs/VPN.

---

## Host

- **fail2ban / swap / backup cron** – already applied by `setup.sh`.
- **unattended-upgrades** – security patches (Debian/Ubuntu).
- **ufw** – see `DEPLOY.md`.
- **Second SSH key** – break-glass access.

---

## Backups

- **Google Drive first:** `stackctl auto-backup gdrive-setup` → set `BACKUP_RCLONE_REMOTE` (job fails without it by default).
- Local `/opt/backups` is staging only; VPS loss without Drive = data loss.
- Run `scripts/restore-drill.sh` periodically; optionally download a dump from Drive and restore.

---

## Updates

- Prefer **manual** `docker compose pull && up -d`.
- **Watchtower** – optional; pin tags/digests in production.

---

## Hygiene

- `docker system prune -a` – only when you accept removing unused images.
- **Cloudflare** (optional) – in front of Traefik for WAF/DDoS.
