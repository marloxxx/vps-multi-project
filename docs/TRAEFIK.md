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
