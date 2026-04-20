# Traefik – multi-host routing (server config)

Docker provider: routing via **labels** on containers. One Traefik gateway can serve many hostnames and many compose projects.

---

## Multiple hostnames → one service

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myapp.rule=Host(`app.example.com`) || Host(`www.example.com`)"
  - "traefik.http.routers.myapp.entrypoints=websecure"
  - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
  - "traefik.http.services.myapp.loadbalancer.server.port=3000"
```

Let’s Encrypt **HTTP-01**: one cert per hostname when first requested. Each hostname must **resolve to this server** (A/AAAA).

**Several projects** = several compose files, each with its own `Host(...)`.

---

## TLS in this stack (Let’s Encrypt)

1. **`/opt/stack/.env`:** `ACME_EMAIL` set (used by Traefik’s ACME resolver in `infra/traefik/traefik.yml`).
2. **Traefik:** `docker-compose.yml` + `docker-compose.dashboard.yml` (same as `setup.sh` / `stackctl`).
3. **App container:** **`proxy`** network; labels with `entrypoints=websecure` and **`tls.certresolver=letsencrypt`** (see block at top of this page).
4. **DNS:** hostname → this server; **port 80** must reach Traefik for HTTP-01.

First HTTPS request to that host triggers issuance (or reuse from `acme.json`).

### Custom PEM certificates (advanced, not wired in repo)

To terminate TLS with your own PEM files, extend **`infra/traefik/docker-compose.yml`** and **`traefik.yml`**: add bind mounts for certificates and a dynamic directory, enable Traefik’s **`providers.file`**, and supply `tls.certificates` YAML (shape: `infra/traefik/dynamic/tls-certificates.example.yml`). Routers using that cert must **not** set `tls.certresolver=letsencrypt` for the same host.

#### Commercial CA (e.g. Sectigo)

Sectigo (and similar vendors) give you **normal PEM** material: a **server certificate**, one or more **intermediate** certificates, and a **private key** (often `yourdomain.crt`, `CA_bundle.crt`, `yourdomain.key` — names vary).

1. **Build a full chain** Traefik can send to clients: concatenate **leaf first**, then intermediates (same idea as “fullchain” for Let’s Encrypt), e.g.  
   `cat yourdomain.crt Sectigo_intermediate.crt > fullchain.pem`  
   (use whatever filenames Sectigo supplied; order is **leaf → intermediates**.)
2. **Private key** only in a separate file, e.g. `key.pem` (permissions **600** on the host).
3. Mount that directory into the Traefik container (e.g. read-only **`/certs`**) and point **`tls.certificates`** at **`/certs/fullchain.pem`** and **`/certs/key.pem`** (see `tls-certificates.example.yml` — adjust paths if you mount elsewhere).
4. On the **service** behind Traefik, use **`websecure`** and the correct **`Host(...)`**, and **omit** **`tls.certresolver=letsencrypt`** for hostnames that must use the Sectigo cert.

Browsers trust the site when the **chain** includes all intermediates up to a **public root** already in the trust store (Sectigo’s docs list which intermediate to use). Wrong or missing intermediates cause “certificate not trusted” even with a valid Sectigo leaf.

#### Example: host layout `/opt/ssl/ptsi/` and bind mounts

Keep **PEM files** and **YAML** in separate host folders so Traefik’s file provider only reads config files (not `.pem` blobs).

**On the server:**

```text
/opt/ssl/ptsi/certs/fullchain.pem
/opt/ssl/ptsi/certs/key.pem
/opt/ssl/ptsi/dynamic/tls-certificates.yml
```

`tls-certificates.yml` should reference **container** paths (after mounts), e.g.:

```yaml
tls:
  certificates:
    - certFile: /certs/fullchain.pem
      keyFile: /certs/key.pem
```

**1. `infra/traefik/docker-compose.yml`** — under `traefik.volumes`, add (keep existing lines):

```yaml
      - /opt/ssl/ptsi/certs:/certs:ro
      - /opt/ssl/ptsi/dynamic:/etc/traefik/dynamic-ssl:ro
```

**2. `infra/traefik/traefik.yml`** — under `providers:`, add a **`file`** provider beside **`docker`** (pick a directory name that matches the mount above):

```yaml
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy
  file:
    directory: /etc/traefik/dynamic-ssl
    watch: true
```

**3.** Recreate Traefik, e.g. from `/opt/stack/infra/traefik`:

```bash
docker compose -f docker-compose.yml -f docker-compose.dashboard.yml \
  --env-file /opt/stack/.env up -d --force-recreate traefik
```

**4.** Routers that must use this cert: **`websecure`** + correct **`Host(...)`**, and **no** **`tls.certresolver=letsencrypt`** for those hosts.

---

## Wildcard subdomain (`*.example.com`)

**HTTP-01 cannot issue wildcard certs.** Options:

1. **Per-host certs** – first request to `sub1.example.com` gets a cert; no wildcard needed.
2. **Wildcard cert** – **DNS-01** only. Add a second ACME resolver in `traefik.yml` (e.g. Cloudflare API token), then on the service:

```yaml
labels:
  - "traefik.http.routers.myapp.rule=HostRegexp(`^[a-z0-9-]+\\.example\\.com$`)"
  - "traefik.http.routers.myapp.tls.certresolver=letsencrypt-dns"
  - "traefik.http.routers.myapp.tls.domains[0].main=example.com"
  - "traefik.http.routers.myapp.tls.domains[0].sans=*.example.com"
```

[Traefik ACME DNS challenge](https://doc.traefik.io/traefik/https/acme/#dnschallenge) – provider list.

---

## Extra domains without redeploying compose

**File provider** – mount a directory into Traefik and drop YAML files; `watch: true` reloads on change.

**traefik.yml:**

```yaml
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

Mount `infra/traefik/dynamic/` into the container at `/etc/traefik/dynamic`. Example router pointing at a container on the `proxy` network:

```yaml
http:
  routers:
    extra-host:
      rule: Host(`other.example.com`)
      entryPoints: [websecure]
      service: my-service
      tls:
        certResolver: letsencrypt
  services:
    my-service:
      loadBalancer:
        servers:
          - url: "http://container_name:3000"
```

Replace `container_name` with the Docker DNS name of the target container.

---

## Summary

| Need | Config |
|------|--------|
| Several domains, one backend | `Host(a) \|\| Host(b)` in one router |
| Many subdomains, no wildcard TLS | `HostRegexp(...)` + HTTP-01 per host |
| `*.domain.com` one cert | DNS-01 resolver + `tls.domains` sans |
| Dynamic host list | File provider + generated YAML |

Static config: `infra/traefik/traefik.yml`. Compose: `infra/traefik/docker-compose.yml`.
