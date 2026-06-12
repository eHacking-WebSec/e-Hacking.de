# e-hacking.de

This project provides an example configuration how we deploy our eHacking platform on [e-hacking.de](https://e-hacking.de).

# Layout

```
.
├── .env                          # committed (hostnames, ports, base paths)
├── docker-compose.yml            # committed (base — works on docker & podman)
├── compose.podman.yml            # committed (podman overlay: cap_add, DOCKER_HOST)
├── Justfile                      # committed (operator recipes)
├── bin/                          # committed (helper scripts)
│   ├── compose                   # runtime-agnostic compose wrapper
│   ├── runtime-env.sh            # detects podman/docker, emits ENV
│   ├── make-auth.sh
│   ├── make-bot-env.sh
│   ├── make-credentials.sh
│   ├── make-flags.sh
│   └── update.sh
├── traefik/dynamic/basicauth.yml # gitignored — bcrypt hashes
├── cloudflare.env                # gitignored — DNS-01 token
├── bot.env                       # gitignored — recruiting bot secret
├── credentials.env               # gitignored — WildFly + catcher passwords
├── flags_<module>.env            # gitignored — per-module CTF flags
├── flag_xxe1.txt / xxe2.txt / xslt1.xml  # gitignored — bind-mounted into xml-sec
└── (letsencrypt is a named docker volume, not a host directory)
```

# Secret + config files

Hostnames, ports and paths live in `.env` (committed). Everything else
is gitignored; here's how to create each:

| File | Purpose | How to create |
|---|---|---|
| `cloudflare.env` | Cloudflare API token used by Traefik for DNS-01 ACME. | `echo 'CF_DNS_API_TOKEN=<token with Zone:DNS:Edit on your zone>' > cloudflare.env` |
| `traefik/dynamic/basicauth.yml` | Shared `basicauth` middleware (recruiting-instructor + the dashboard router). Hot-reloaded by Traefik's file provider — rotate without restarting. | `just add-basicauth-user <name>` (`just init` calls this for the first user) |
| `bot.env` | Internal secret for recruiting-bot ↔ recruiting-challenge auth. | `./bin/make-bot-env.sh` |
| `credentials.env` | WildFly application principals (`attacker`, `victim`, `admin`, `oemmes`) and catcher access gates (`/__catcher` signup + `/__instructor`). | `./bin/make-credentials.sh` |
| `flags_*.env` | Per-module challenge flags. Format: `FLAG_<KEY>=<value>` matching the `ENV FLAG_*` lines in each module's `Dockerfile`. Modules in scope: `json-sec`, `oidc`, `rest-api-sec`, `saml`, `soap-sec`, `xml-sec`, `axis2-flag`. `crawling-maze` is a separate project — its `flags_crawling-maze.env` is hand-managed. | `./bin/make-flags.sh` (reads each published image's `FLAG_*` defaults, swaps each `_dummy` marker for a random token; same script also writes `flag_xslt1.xml`, `flag_xxe1.txt`, `flag_xxe2.txt` which xml-sec reads as bind-mounted files) |

## Container runtime

The stack runs on either Podman or Docker. `just` and the helper
scripts auto-detect via `bin/runtime-env.sh`, in this preference order:

1. **Rootless Podman** (best — no daemon, no root)
2. **Rootful Podman** (acceptable fallback)
3. **Docker** (last resort)

The detection probes for `podman compose` (the compose-go-based
wrapper). The legacy Python `podman-compose` is rejected because it
groups every service into a single pod, which collapses Traefik's
hostname-based routing.

Setup once per host:

```bash
# Rootless podman (recommended):
systemctl --user enable --now podman.socket
# Let traefik bind 80/443 without root:
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/podman-lowports.conf
sudo sysctl --system
sudo loginctl enable-linger "$USER"     # keep the user manager alive past logout

# Rootful podman (only if rootless is impractical):
sudo systemctl enable --now podman.socket

# Docker: nothing extra — used automatically if no podman socket is reachable.
```

Force a specific runtime/socket by exporting before `just`:

```bash
RUNTIME=docker just up
CONTAINER_SOCKET=/run/podman/podman.sock just up   # e.g. force rootful when both are running
```

## Quickstart

```bash
# One-off: drop in cloudflare.env, then bootstrap the rest.
echo 'CF_DNS_API_TOKEN=<token>' > cloudflare.env
just init
just up
```

Rotate every flag + credential (new semester etc.):

```bash
just reset      # wipes managed secret + flag files, re-runs init
just up
```

`cloudflare.env`, the `letsencrypt` docker volume, and
`flags_crawling-maze.env` are preserved by `reset`.

Day-to-day:

```bash
just update                # git pull + compose pull + up -d
just add-basicauth-user X  # append a user to traefik/dynamic/basicauth.yml
just logs                  # tail logs for all services
just logs catcher
just ps
just restart oidc
```

If `just` is not installed, the equivalent flat script works:
`./bin/update.sh` is the legacy one-shot of `just update`.

## Catcher-specific notes

The catcher service is mapped onto **`e-attacker.de`** — both the bare
host and any `*.e-attacker.de` subdomain. DNS-01 issues a wildcard cert
in one go, so no per-subdomain configuration is required. The wildcard
A-record (`*.e-attacker.de` → server IP) must exist in Cloudflare for
the wildcard cert to issue.

The legacy `mendhak/http-https-echo:31` attacker container has been
replaced by the catcher; the bare `e-attacker.de` host still serves a
mendhak-compatible echo response so old `attacker_url`-style consumers
keep working.

## Operator passwords

`bin/make-credentials.sh` writes random passwords for `oemmes`, the
WildFly management user, and the catcher's three access gates
(`CATCHER_SIGNUP_PASSWORD`, `CATCHER_SUPERUSER_PASSWORD`,
`CATCHER_INSTRUCTOR_PASSWORD`). Look them up in `credentials.env` when
you need to log into `/__instructor`.

Student-facing CTF accounts (`attacker`, `victim`) keep intentional
weak defaults so the same login forms work as in the local-dev stack.
`admin` gets a random password (only used internally).

## Migrating from a pre-catcher deployment

```bash
cd ~/e-Hacking.de
git pull                  # picks up bin/, Justfile, new compose

# (Once) migrate the old ./letsencrypt host directory into the named volume.
# Use whichever runtime your stack uses (docker or podman):
docker run --rm -v letsencrypt:/dst -v "$PWD/letsencrypt":/src \
  alpine cp -a /src/. /dst/
# podman equivalent:
# podman run --rm -v letsencrypt:/dst -v "$PWD/letsencrypt":/src \
#   alpine cp -a /src/. /dst/

# Old auth.env is unused; create the new basicauth file:
just add-basicauth-user admin

# Add a flags_oidc.env (OIDC has flag ENVs since feat-catcher-midp):
./bin/make-flags.sh

# Optional: rotate everything in one go
# just reset

just update               # pulls catcher + victim-bot, recreates stack
```
