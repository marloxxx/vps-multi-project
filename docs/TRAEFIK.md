# Traefik – multi-host routing (server config)

Docker provider: routing via **labels** on containers. One Traefik gateway can serve many hostnames and many compose projects.

---

## Multiple hostnames → one service

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myapp.rule=Host(`app.example.com`) || Host(`www.example.com`)"
  - "traefik.http.routers.myapp.entrypoints=websecure"
  - "traefik.http.routers.myapp.tls=true"
  - "traefik.http.services.myapp.loadbalancer.server.port=3000"
```

TLS is terminated by Traefik from **file-loaded PEM** (wildcard/SAN). The hostname must appear on that certificate.

**Several projects** = several compose files, each with its own `Host(...)`.

---

## TLS in this stack (file PEM)

Default for **all** public routers: `websecure` + `tls=true`, **no** `tls.certresolver`. Traefik then uses the PEM from the file provider. Adding `certresolver=letsencrypt` makes Traefik request a Let’s Encrypt cert for that Host — that fails with NXDOMAIN if the name has no public DNS.

1. Mount certs + dynamic YAML into Traefik (server layout below).
2. App container on **`proxy`**, labels as in the block above.
3. DNS A/AAAA is still required for browsers; it is **not** required for ACME if you are not using Let’s Encrypt.

### PEM layout (e.g. Sectigo / wildcard)

1. Full chain: **leaf first**, then intermediates → `fullchain.pem`.
2. Private key → `key.pem` (host mode **600**).
3. YAML for Traefik file provider (`infra/traefik/dynamic/tls-certificates.example.yml`).

**On the server:**

```text
/opt/ssl/ptsi/certs/fullchain.pem
/opt/ssl/ptsi/certs/key.pem
/opt/ssl/ptsi/dynamic/tls-certificates.yml
```

```yaml
tls:
  certificates:
    - certFile: /certs/fullchain.pem
      keyFile: /certs/key.pem
```

**`infra/traefik/docker-compose.yml`** volumes:

```yaml
      - /opt/ssl/ptsi/certs:/certs:ro
      - /opt/ssl/ptsi/dynamic:/etc/traefik/dynamic-ssl:ro
```

**`infra/traefik/traefik.yml`** providers:

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

Recreate Traefik after changing static config:

```bash
docker compose -f docker-compose.yml -f docker-compose.dashboard.yml \
  --env-file /opt/stack/.env up -d --force-recreate traefik
```

### Optional: Let’s Encrypt on a specific host

The ACME resolver remains in Traefik. **Only** on that router add:

```yaml
  - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
```

That host must have public DNS (A/AAAA) and port **80** must reach Traefik (HTTP-01). Do not set `certresolver` on routers that should use the file PEM.

---

## Wildcard subdomain (`*.example.com`)

File PEM already covers `*.example.com` if that SAN is on the certificate. HTTP-01 cannot issue wildcards.

Optional ACME wildcard (DNS-01):

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

```yaml
http:
  routers:
    extra-host:
      rule: Host(`other.example.com`)
      entryPoints: [websecure]
      service: my-service
      tls: {}
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
| TLS for stack + apps | `websecure` + `tls=true`, file PEM, **no** certresolver |
| One host on Let’s Encrypt | add `tls.certresolver=letsencrypt` on that router only |
| Dynamic host list | File provider + generated YAML |

Static config: `infra/traefik/traefik.yml`. Compose: `infra/traefik/docker-compose.yml`.
