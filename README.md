# e-hacking.de

This project provides an example configuration how we deploy our eHacking platform on [e-hacking.de](https://e-hacking.de).

# Deployment

Hostnames, ports and paths live in `.env` (committed). Three extra
files hold secrets and are gitignored:

| File | Purpose | How to create |
|---|---|---|
| `cloudflare.env` | Cloudflare API token used by Traefik for DNS-01 ACME. | `echo 'CF_DNS_API_TOKEN=<token with Zone:DNS:Edit on your zone>' > cloudflare.env` |
| `auth.env`       | Shared BasicAuth credentials. Used by the recruiting-instructor router; reusable for the Traefik dashboard or any other router that adds `middlewares=basicauth`. | `./make-auth.sh` (prompts for password) |
| `flags_*.env`    | Per-module challenge flags. | One file per module; see the services in `docker-compose.yml`. |

Then start the stack:

```bash
./update.sh
```

(which runs `git pull`, `docker compose pull`, and `docker compose up -d` with all three env files).
