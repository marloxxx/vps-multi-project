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

- `stackctl auto-backup enable` / `run` / `status` — daily dumps + retention (see `docs/POSTGRES.md`).
- Google Drive: `stackctl auto-backup gdrive-setup` then set `BACKUP_RCLONE_REMOTE` in `.env`.
- Run `scripts/restore-drill.sh` periodically to verify dumps.
- **rclone** / **restic** – off-site copy of `/opt/backups` (rclone is integrated when `BACKUP_RCLONE_REMOTE` is set).

---

## Updates

- Prefer **manual** `docker compose pull && up -d`.
- **Watchtower** – optional; pin tags/digests in production.

---

## Hygiene

- `docker system prune -a` – only when you accept removing unused images.
- **Cloudflare** (optional) – in front of Traefik for WAF/DDoS.
