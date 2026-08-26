# 9Router – optional AI gateway

[9Router](https://9router.com) is an OpenAI-compatible proxy that sits in front of Claude, Codex, Cursor, and other tools. It is **opt-in** in this stack: setup does **not** install it unless you say yes (or set `START_9ROUTER=1`).

- Dashboard: `https://9router.<BASE_DOMAIN>`
- API: `https://9router.<BASE_DOMAIN>/v1`
- On the VPS loopback: `http://127.0.0.1:20128/v1`
- From other containers on `backend`: `http://9router:20128/v1`

Compose: `services/9router/docker-compose.yml`. Image: [`decolua/9router`](https://hub.docker.com/r/decolua/9router).

---

## Enable at first setup

Interactive prompt defaults to **No**:

```text
Install 9Router (optional AI gateway for Claude/Codex/Cursor)? [y/N]
```

Non-interactive:

```bash
START_9ROUTER=1 BASE_DOMAIN=example.com ACME_EMAIL=you@example.com ./setup.sh
```

Leave it off (default):

```bash
START_9ROUTER=0 ./setup.sh
# or just ./setup.sh and press Enter at the prompt
```

Setup then writes `NINEROUTER_HOST=9router.<BASE_DOMAIN>`, generates dashboard/HMAC secrets, and starts the container.

DNS: create an **A/AAAA** for `9router.<BASE_DOMAIN>` pointing at this VPS. The hostname must match the Traefik file-loaded certificate (wildcard/SAN). Do not set `tls.certresolver=letsencrypt` unless that name should use ACME.

---

## Enable later (existing stack)

1. In `/opt/stack/.env`:

```bash
START_9ROUTER=1
NINEROUTER_HOST=9router.example.com
NINEROUTER_DATA_DIR=/opt/volumes/9router
NINEROUTER_INITIAL_PASSWORD=<strong-password>
NINEROUTER_JWT_SECRET=<random>
NINEROUTER_API_KEY_SECRET=<random>
NINEROUTER_MACHINE_ID_SALT=<random>
```

2. Start:

```bash
stackctl start 9router
stackctl health 9router
```

Do **not** re-run the full `setup.sh` just to add 9Router — that re-applies SSH/ufw/cron. Prefer the steps above.

`stackctl start all` includes 9Router only when `START_9ROUTER=1` (or `true` / `yes` / `on`). It is never part of `core`. Explicit `stackctl start 9router` always works if compose + `NINEROUTER_HOST` are set.

---

## First login and API keys

1. Open `https://9router.<BASE_DOMAIN>`.
2. Log in with `NINEROUTER_INITIAL_PASSWORD` (printed in `.setup-credentials.txt` on first enable). After the dashboard stores a password hash, changing this env var does **not** reset the UI password.
3. Create an API key in the dashboard. Compose sets `REQUIRE_API_KEY=true` because the service is on the public internet.
4. Point the client at `/v1`:

```text
Endpoint: https://9router.example.com/v1
API key:  <from dashboard>
```

Credentials:

```bash
stackctl credentials 9router
```

---

## Apps on the same VPS

Attach the app to the **`backend`** network and call Docker DNS (no TLS hop):

```yaml
services:
  app:
    environment:
      OPENAI_BASE_URL: http://9router:20128/v1
      OPENAI_API_KEY: ${APP_NINEROUTER_API_KEY}
    networks:
      - backend

networks:
  backend:
    external: true
```

Use a dashboard-issued Bearer key, not the stack HMAC secret (`NINEROUTER_API_KEY_SECRET` is for 9Router’s own key generation).

---

## Security

- Public HTTPS only via Traefik; port **20128** is bound to **127.0.0.1** on the host.
- `AUTH_COOKIE_SECURE=true` and `REQUIRE_API_KEY=true` are set in compose.
- Optional extra Traefik basic auth: set `NINEROUTER_TRAEFIK_AUTH` and uncomment the middleware labels in compose (same pattern as Grafana/Portainer).
- Prefer an IP allowlist or VPN for the dashboard if you do not need the API from the public internet (`docs/SUGGESTIONS.md`).
- Treat provider OAuth tokens stored in 9Router’s SQLite volume (`/opt/volumes/9router`) as secrets; include that path in off-site backups if you enable the service.

---

## Ops

```bash
stackctl start 9router
stackctl logs 9router
stackctl health 9router
stackctl stop 9router
```

Update image:

```bash
docker compose -f /opt/stack/services/9router/docker-compose.yml --env-file /opt/stack/.env pull
stackctl restart 9router
```

Pin `decolua/9router:<tag>` in compose for reproducible deploys; the stock file uses `latest`.
