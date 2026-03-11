# VPS multi-project stack (Traefik + Docker)

Layout: **`/opt/stack`**, **`/opt/volumes`**, **`/opt/backups`**.

## First-time setup

```bash
sudo mkdir -p /opt && sudo chown "$USER":"$USER" /opt
git clone <repo-url> /opt/stack
cd /opt/stack
chmod +x setup.sh && ./setup.sh
```

**Interactive:** prompts for **base domain** and **ACME email** if `.env` is missing.

**Automatic:** random passwords for Postgres, Redis, MinIO (and Grafana if monitoring is on), written to **`.env`** and **`.setup-credentials.txt`**. A **banner at the end** prints the same – **copy to a password manager, then delete** `.setup-credentials.txt`.

**SSH** moves to a **random port (20000–40000)**; `ufw` allows that port plus 80/443 (and 22 until you migrate). Port is in **`.ssh-port`** and in the credentials output.

**Non-interactive:** `BASE_DOMAIN=... ACME_EMAIL=... ./setup.sh` when `.env` does not exist yet.

**Skip monitoring:** `START_MONITORING=0 ./setup.sh`  
**Re-run secrets only:** `REGENERATE_SECRETS=1 ./setup.sh` (overwrites password lines in `.env`).

## Layout & docs

| Path / doc | Purpose |
|------------|--------|
| `docs/TRAEFIK.md` | Multi-host, TLS |
| `docs/POSTGRES.md` | Backups, multi-DB |
| `docs/TOOLS.md` | Portainer, Grafana |
| `docs/SUGGESTIONS.md` | Hardening |
| `DEPLOY.md` | SSH keys, firewall, console recovery |

## Backups

```bash
/opt/stack/scripts/backup-postgres.sh
/opt/stack/scripts/backup-postgres-all-dbs.sh
/opt/stack/scripts/restore-drill.sh
```

## Security checklist

- [ ] Copy then **delete** `.setup-credentials.txt`
- [ ] After logging in with `ssh -p <port>`, optionally `sudo ufw deny 22/tcp`
- [ ] `chmod 600 .env`

## Licence

Use freely for your own infrastructure.
