# Integrating a new application with this stack

This guide explains how to attach **new Docker Compose projects** (e.g. Laravel, Node, a custom API) to the shared VPS stack: **Traefik (TLS)**, **Postgres**, **Redis**, **MinIO**, and optional **MySQL**.

Assumptions: stack is installed under `/opt/stack` per `README.md` / `setup.sh`, and core services are running (`stackctl start core`).

---

## 1. Two Docker networks

| Network   | Purpose | Who joins |
|-----------|---------|-----------|
| **`proxy`** | HTTP/HTTPS from the internet via Traefik | Any container that needs a **public hostname** (TLS). |
| **`backend`** | Private service-to-service traffic | Apps that use **Postgres, Redis, MySQL** without exposing those ports publicly. |

Traefik’s static config sets `providers.docker.network: proxy`, so the **container Traefik forwards to** must be reachable on **`proxy`**.

Platform databases and caches live on **`backend`** only (with optional **127.0.0.1** port publishes on the host for admin tools — see stack compose files).

---

## 2. DNS and stack `.env`

Before routing HTTPS:

1. Create **A (or AAAA)** records for your app hostname(s) → **this server’s public IP**.
2. In `/opt/stack/.env`, `BASE_DOMAIN` and host variables (`*_HOST`) are used by existing services; **your new app** will use **its own** hostname in Traefik labels (can be a subdomain of the same domain).

You do **not** need to add every app hostname to the stack `.env` unless you centralise hostnames there for templating. A common pattern is to keep app-specific vars in **the app’s** `.env` next to its `docker-compose.yml`.

---

## 3. Pattern A — Web app behind Traefik (HTTPS)

**Requirements:**

- Container listens on an **internal port** (e.g. `80`, `3000`, `8000`).
- Service is attached to **`proxy`**.
- Labels enable Traefik and set **Host**, **TLS**, and **entrypoint** `websecure`.

**Minimal label set** (replace `app.example.com` and port):

```yaml
services:
  web:
    image: your-image:tag
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.example.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"

networks:
  proxy:
    external: true
```

**Notes:**

- First HTTPS request to that host triggers **Let’s Encrypt HTTP-01** (port **80** must reach Traefik — already mapped in this stack).
- See **`docs/TRAEFIK.md`** for multiple hosts, wildcards (DNS-01), and middlewares.

---

## 4. Pattern B — App uses Postgres / Redis / MySQL (no public route)

Attach the **application** containers (not the databases) to **`backend`** and use **Docker DNS names** matching **container names** from this stack:

| Service    | Container name | Typical env vars |
|------------|----------------|------------------|
| PostgreSQL | `postgres`     | `DB_HOST=postgres`, `DB_PORT=5432`, user/password/db from stack or `stackctl provision-postgres` |
| Redis      | `redis`        | `REDIS_HOST=redis`, `REDIS_PORT=6379`, `REDIS_PASSWORD` = value of `REDIS_PASSWORD` in `/opt/stack/.env` |
| MySQL      | `mysql`        | `DB_HOST=mysql`, port `3306`, credentials from provision or root (see operational policy) |

**Example `networks` block for your app:**

```yaml
services:
  app:
    networks:
      - backend

networks:
  backend:
    external: true
```

**Important:** If the app only defines its **own** default network, the hostname `redis` / `postgres` **will not resolve** — you must add **`backend`** as above to every service that connects to those databases.

---

## 5. Pattern C — HTTPS + databases (typical production app)

Combine **Pattern A** and **Pattern B**: attach the same service to **both** networks.

```yaml
services:
  app:
    networks:
      - proxy
      - backend

networks:
  proxy:
    external: true
  backend:
    external: true
```

Workers and schedulers that only talk to Redis/DB need **`backend`** only (unless they also expose HTTP).

---

## 6. Databases per project

Use **`stackctl`** from `/opt/stack` to create an isolated database and user (credentials appended to `.project-db-credentials.txt`):

```bash
cd /opt/stack
./scripts/stack-manage.sh provision-db postgres my_project
./scripts/stack-manage.sh provision-db mysql my_project
```

Then point your app’s `.env` at **`postgres`** or **`mysql`**, with the generated **database name, user, and password**.

See **`docs/POSTGRES.md`** for backups and restores.

---

## 7. MinIO (S3-compatible)

Stack MinIO is already exposed via Traefik (`MINIO_API_HOST`, `MINIO_CONSOLE_HOST`). From **another container on `backend`**, the S3 endpoint is usually:

- **`http://minio:9000`** (internal), with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` from `/opt/stack/.env`, **or** a dedicated bucket user you create in MinIO.

For **public** SDKs or browsers, use the **HTTPS hostnames** configured in stack `.env`, not `minio:9000`.

---

## 8. Where to put the new project on disk

Common layouts (pick one and stay consistent):

- **`/opt/apps/<project>/`** — `docker-compose.yml` + `.env`
- **`/opt/stack/projects/<project>/`** — if you want everything under the stack repo tree (often **gitignored** for app code)

Run Compose from that directory:

```bash
cd /opt/apps/myapp
docker compose --env-file .env up -d
```

Ensure **`proxy`** / **`backend`** exist:

```bash
docker network ls | grep -E 'proxy|backend'
```

If missing, start the stack: `stackctl start core` (creates external networks via compose).

---

## 9. Operational pitfalls (avoid re-configuring every deploy)

1. **Commit** `docker-compose.yml` (and `.env.example`) for your app — including **`external` networks** — so every `git pull` + `up -d` restores wiring.
2. **Do not** rely on `docker network connect` alone for production; it is easy to lose after recreate.
3. **Traefik:** use **`stackctl restart traefik`** (or the same **two-file** compose as `setup.sh`) so the **dashboard** overlay is not dropped — see `DEPLOY.md` / `infra/traefik/docker-compose.dashboard.yml`.
4. **Stale Traefik warnings** after heavy `docker compose up --force-recreate`: **`docker restart traefik`** clears old container ID references.

---

## 10. Security checklist

- Prefer **backend-only** DB access; use **SSH tunnels** or **127.0.0.1** publishes for ad-hoc admin (this stack binds Redis/Postgres/MinIO API to loopback on the host where configured).
- **MySQL** may be published on **0.0.0.0:3306** in this stack for restore/tools — **restrict with firewall** to your IP.
- Put **Portainer**, **Traefik dashboard**, and UIs behind **strong passwords** and optional **Traefik basic auth** (`docs/SUGGESTIONS.md`).

---

## 11. Related documentation

| Doc | Topic |
|-----|--------|
| `docs/TRAEFIK.md` | Labels, TLS, wildcards |
| `docs/POSTGRES.md` | Backups, multiple DBs |
| `docs/TOOLS.md` | `stackctl`, scripts |
| `DEPLOY.md` | SSH, firewall, recovery |
| `.env.example` | Stack variable names |
