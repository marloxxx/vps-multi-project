# Optional services (server) – free / OSS

Self-hosted only; no paid licence required for the editions below.

| Component in repo | Licence |
|-------------------|--------|
| Portainer CE | Free |
| Prometheus / Grafana OSS / cAdvisor | Free |
| Traefik | MIT |
| PostgreSQL / Redis / MinIO | OSS |

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
- **Backups:** `scripts/backup-postgres.sh` + rclone/restic off-site
