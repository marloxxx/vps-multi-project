# Deploy – `/opt/stack`

## First run

```bash
sudo mkdir -p /opt && sudo chown "$USER":"$USER" /opt
git clone <repo> /opt/stack
cd /opt/stack
chmod +x setup.sh && ./setup.sh
```

`setup.sh` creates `.env` (domain + ACME email), generates random passwords, starts stacks + monitoring by default, then configures **SSH on a random high port**, **ufw** (new port + 80 + 443 + 22 until you migrate), fail2ban, cron.

**Credentials** are printed at the end and saved to `.setup-credentials.txt` (mode 600). **Copy then delete** that file. SSH port is also in `.ssh-port` and appended to `.env` as `SSH_PORT=`.

## SSH key – how to get it

| Scenario | What to do |
|----------|------------|
| **Cloud VPS (DigitalOcean, Hetzner, AWS, …)** | At instance create, provider often lets you **download a .pem / private key once**. Store it safely; that is your login key. |
| **Key on your laptop** | `ssh-copy-id -i ~/.ssh/id_ed25519.pub -p PORT user@server` then use `ssh -p PORT user@server`. |
| **Key generated on server (fallback)** | On server: `ssh-keygen -t ed25519`; copy `~/.ssh/id_ed25519` to your machine once with `scp -P 22 user@host:.ssh/id_ed25519 .` then **remove the private key from the server** if you do not need it there. |

If **sshd fails to restart** on the new port, use the **provider web console** to get a shell and fix `/etc/ssh/sshd_config.d/`.

## Firewall after setup

Setup enables **ufw** with:

- Random **SSH_PORT** (see banner / `.ssh-port`)
- **22** temporarily (migrate then run `sudo ufw deny 22/tcp`)
- **80 / 443** for Traefik

Manual allow if you disabled ufw:

```bash
sudo ufw allow PORT/tcp   # PORT from .ssh-port
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
sudo ufw enable
```

## Updates

```bash
cd /opt/stack && git pull
docker compose -f apps/<app>/docker-compose.yml --env-file .env up -d
```

## Traefik dashboard

```bash
cd /opt/stack
docker compose -f infra/traefik/docker-compose.yml \
  -f infra/traefik/docker-compose.dashboard.yml --env-file .env up -d
```
