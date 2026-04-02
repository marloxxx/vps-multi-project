# VPS multi-project stack (Traefik + Docker)

Layout: **`/opt/stack`**, **`/opt/volumes`**, **`/opt/backups`**.

## First-time setup

```bash
sudo mkdir -p /opt && sudo chown "$USER":"$USER" /opt
git clone https://github.com/marloxxx/vps-multi-project.git /opt/stack
cd /opt/stack
chmod +x setup.sh && ./setup.sh
```

**Interactive:** prompts for **base domain** and **ACME email** if `.env` is missing.

**Automatic:** random passwords for Postgres, MySQL, Redis, MinIO (and Grafana if monitoring is on), plus a detailed service credential summary, written to **`.env`** and **`.setup-credentials.txt`**. A **banner at the end** prints the same – **copy to a password manager, then delete** `.setup-credentials.txt`.
Setup also generates Traefik dashboard basic-auth credentials if needed.

**SSH** moves to a **random port (20000–40000)**; `ufw` allows that port plus 80/443 (and 22 until you migrate). Port is in **`.ssh-port`** and in the credentials output.

**CLI install:** `setup.sh` auto-installs `/usr/bin/stackctl` (disable with `AUTO_INSTALL_STACKCTL=0`).
**Docker auto-install:** enabled by default (`AUTO_INSTALL_DOCKER=1`).  
**Portainer + Traefik dashboard:** required and started during setup.
**Host alignment:** setup normalises hosts to `BASE_DOMAIN` (e.g. `traefik.<base>`, `portainer.<base>`, `grafana.<base>`, `storage.<base>`, `s3.<base>`).

**Non-interactive:** `BASE_DOMAIN=... ACME_EMAIL=... ./setup.sh` when `.env` does not exist yet.

**Skip monitoring:** `START_MONITORING=0 ./setup.sh`  
**Custom CLI name:** `STACKCTL_BIN_NAME=vpsctl ./setup.sh`  
**Disable host sync (advanced):** `SYNC_HOSTS_WITH_BASE_DOMAIN=0 ./setup.sh`
**Re-run secrets only:** `REGENERATE_SECRETS=1 ./setup.sh` (overwrites password lines in `.env`).

## Layout & docs

| Path / doc | Purpose |
|------------|--------|
| `docs/APP-INTEGRATION.md` | New apps: `proxy` / `backend`, Traefik, DBs |
| `docs/TRAEFIK.md` | Multi-host, TLS |
| `docs/POSTGRES.md` | Backups, multi-DB |
| `docs/TOOLS.md` | Operational tools |
| `docs/SUGGESTIONS.md` | Hardening |
| `DEPLOY.md` | SSH keys, firewall, console recovery |

## Backups

```bash
/opt/stack/scripts/backup-postgres.sh
/opt/stack/scripts/backup-postgres-all-dbs.sh
/opt/stack/scripts/restore-drill.sh
```

## Management CLI (menu + `/usr/bin`)

```bash
cd /opt/stack
chmod +x scripts/stack-manage.sh
./scripts/stack-manage.sh menu
```

Install global command:

```bash
cd /opt/stack
./scripts/stack-manage.sh install-bin stackctl
stackctl menu
```

`install-bin` is still available for manual reinstall or custom command names, but `setup.sh` now installs `stackctl` automatically by default.

Service groups:

- `core`: `traefik postgres redis minio mysql`
- `all`: `traefik postgres redis minio monitoring mysql portainer`

Common commands:

```bash
stackctl status
stackctl start core
stackctl start portainer
stackctl health all
stackctl logs postgres
stackctl backup
stackctl mysql
stackctl credentials all
stackctl provision-db mysql billing
stackctl provision-db postgres clay_erp
```

Project DB provisioning (auto-create db/user/password):

```bash
stackctl provision-mysql my_project
stackctl provision-postgres my_project
# or generic:
stackctl provision-db mysql my_project
stackctl provision-db postgres my_project
```

Generated project credentials are appended to:

```bash
/opt/stack/.project-db-credentials.txt
```

Credentials targets:

```bash
stackctl credentials postgres
stackctl credentials redis
stackctl credentials minio
stackctl credentials monitoring
stackctl credentials mysql
stackctl credentials portainer
```

Audit log:

```bash
tail -f /opt/stack/logs/stackctl.log
```

Temporary DB firewall access (prefer restricted source IP):

```bash
stackctl open-db-port postgres <your-client-public-ip>
# ... do your remote DB session ...
stackctl close-db-port postgres <your-client-public-ip>
```

## Security checklist

- [ ] Copy then **delete** `.setup-credentials.txt`
- [ ] After logging in with `ssh -p <port>`, optionally `sudo ufw deny 22/tcp`
- [ ] `chmod 600 .env`

## Licence

Use freely for your own infrastructure.
