# Optional services (server) – free / OSS

Self-hosted only; no paid licence required for the editions below.

| Component in repo | Licence |
|-------------------|--------|
| Portainer CE | Free |
| Prometheus / Grafana OSS / cAdvisor | Free |
| Traefik | MIT |
| PostgreSQL / Redis / SeaweedFS | OSS |
| 9Router (optional) | MIT |

---

## Portainer CE (Docker UI)

```bash
mkdir -p /opt/volumes/portainer
# .env: PORTAINER_HOST=portainer.example.com
docker compose -f services/portainer/docker-compose.yml --env-file .env up -d
```

Use **portainer/portainer-ce** only (not Business). Optional Traefik basic auth in compose.

---

## Monitoring (Prometheus + Grafana + cAdvisor)

```bash
mkdir -p /opt/volumes/prometheus /opt/volumes/grafana
# .env: GRAFANA_HOST, GRAFANA_ADMIN_PASSWORD, *_DATA_DIR
docker compose -f services/monitoring/docker-compose.yml --env-file .env up -d
```

Grafana -> Prometheus data source `http://prometheus:9090`. Dashboard IDs **193** / **14282**.

---

## 9Router (optional AI gateway)

Not started by default. Full guide: **`docs/9ROUTER.md`**.

```bash
# First-time: answer yes at setup, or:
START_9ROUTER=1 ./setup.sh

# Existing stack:
# set START_9ROUTER=1, NINEROUTER_HOST, NINEROUTER_* secrets in .env
mkdir -p /opt/volumes/9router
stackctl start 9router
```

`.env`: `NINEROUTER_HOST=9router.example.com`. Dashboard at `https://$NINEROUTER_HOST`; API at `https://$NINEROUTER_HOST/v1`.

## Other (not in compose)

| Tool | Use |
|------|-----|
| Uptime Kuma | Uptime checks |
| Dozzle / Loki | Logs |
| restic / rclone | Off-site backups |
| fail2ban | On host – already in `setup.sh` |

---

## Summary

- **UI:** `services/portainer/`
- **Metrics:** `services/monitoring/`
- **9Router (opt-in):** `services/9router/`
- **Backups:** `stackctl auto-backup` → dumps + optional Google Drive via rclone (`BACKUP_RCLONE_REMOTE`)
