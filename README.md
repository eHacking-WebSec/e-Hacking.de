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
│   ├── backup.sh                 # snapshot secrets + volumes → tarball
│   ├── restore.sh                # restore a snapshot (runtime-agnostic)
│   ├── init-podman.sh            # bare-server prep for rootless podman
│   └── update.sh
├── traefik/dynamic/basicauth.yml # gitignored — bcrypt hashes
├── cloudflare.env                # gitignored — DNS-01 token
├── bot.env                       # gitignored — recruiting bot secret
├── credentials.env               # gitignored — WildFly + catcher passwords
├── modules.env                   # gitignored, optional — COMPOSE_PROFILES override
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
sudo loginctl enable-linger "$USER"     # keep the user manager alive past logout

# Only if you publish directly on 80/443 (see "Ports" below):
# echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/podman-lowports.conf
# sudo sysctl --system

# Rootful podman (only if rootless is impractical):
sudo systemctl enable --now podman.socket

# Docker: nothing extra — used automatically if no podman socket is reachable.
```

Force a specific runtime/socket by exporting before `just`:

```bash
RUNTIME=docker just up
CONTAINER_SOCKET=/run/podman/podman.sock just up   # e.g. force rootful when both are running
```

## Ports

Two port pairs, and mixing them up breaks the CTF modules in subtle ways.

| Variable | Meaning |
|---|---|
| `PORT_HTTP` / `PORT_HTTPS` | The **public** ports. They bind the traefik entrypoints *and* are handed to every module as env vars. |
| `HOST_PORT_HTTP` / `HOST_PORT_HTTPS` | Where the host publishes those entrypoints. Invisible to the containers. |

`PORT_HTTPS` must equal **the port clients put in their URLs** — 443.

Module URLs come from two independent sources, later compared as raw
strings (`Verifier_IDS.discoveryIssuerSpoofed()`): env-derived
(`System.getenv("PORT_HTTPS")` — `ConfigBean`, the `{PORT_HTTPS}`
placeholders in the SAML configs, `CATCHER_PUBLIC_PORT`, the victim-bot
origins) and request-derived (`request.getServerPort()` — the OIDC
discovery document and every id_token's `iss`).

The request-derived half reads the port from the **`Host` header** and
falls back to the scheme default when there is none — Traefik's
`forwardedPort()` and Undertow's `getHostPort()` both hardcode 443 for
TLS/https. Students arrive portless, so that half is **always 443**,
whatever the entrypoint binds and whatever the host publishes. At
`PORT_HTTPS=10443` the halves disagree and the honest `ids-1`/`ids-3`/
`ids-4` flows throw `JWTVerificationException`. You can watch this on any
stack whose `PORT_HTTPS` is not 443: a portless request returns `issuer`
with `:443` next to a `resource_endpoint` carrying the configured port.

The entrypoint stays on 443 for a separate reason — container→container
calls use `https://host:443` built from `PORT_HTTPS`, resolved to the
traefik container by the network aliases, so traefik must listen there.

`:443` does appear inside generated URL values (`issuer`, `iss`,
`redirect_uri=`); what is portless is the address bar, not every string
the modules emit.

`HOST_PORT_*` is the safe knob. The default `10080` / `10443` assumes the
host firewall preroutes `80 -> 10080` and `443 -> 10443`. Both are
>= 1024, so rootless podman publishes them without host privileges and
`bin/init-podman.sh` skips the `ip_unprivileged_port_start` sysctl (which
needs real root and lowers the bind threshold for every unprivileged user
on the box). Traefik's own 80/443 bind happens inside its network
namespace and costs nothing on the host.

To publish directly on 80/443, set `HOST_PORT_HTTP=80` /
`HOST_PORT_HTTPS=443` and re-run `bin/init-podman.sh`; it will then ask
for the sysctl.

Keep `10080` / `10443` unreachable from the internet. A client that
addresses them directly puts the port in its `Host` header, which lands
in the discovery `issuer` and breaks the OIDC flows for that client.

**Check with the firewall admin** that the redirect also covers
locally-originated traffic (the `OUTPUT` chain, not just `PREROUTING`).
Container→container traffic to the public hostnames is resolved
in-network by the traefik aliases and never leaves the box, so this only
matters if something hairpins off the host's own public IP.

## Deploying without root

The stack itself never needs root: rootless podman publishes on
`HOST_PORT_*` (>= 1024) and `just up` only talks to the user's podman
socket. What does need root is one-time host preparation. Have the host
admin do these four once, then the deploy account never needs sudo again:

1. Install podman plus the rootless dependencies (`uidmap`,
   `slirp4netns`/`passt`, `fuse-overlayfs`) and a compose-go provider, so
   `podman compose version` works for the deploy user.
2. `usermod --add-subuids 100000-165535 --add-subgids 100000-165535 <user>`
3. `loginctl enable-linger <user>` — keeps the user manager, and with it
   the stack, alive past logout.
4. The firewall rules below.

`podman-restart.service` is a *user* unit, so `bin/init-podman.sh` enables
it without root.

Then the deploy itself:

```bash
just init-podman
just init
just up
```

`bin/init-podman.sh` is root-free by default: any step that would need sudo
aborts and prints the one-time command to hand the admin, instead of
silently prompting. On a prepared host no such step is reached. To let it
do the host preparation itself — a bare server you do own root on — run
`ALLOW_SUDO=1 just init-podman`.

### Firewall rules for the host admin

Public 80/443 must reach the ports the stack publishes, and the host must
be able to reach itself on the public hostnames.

```
# 1. Inbound redirect — already in place on e-hacking.de
iptables -t nat -A PREROUTING -p tcp --dport 80  -j REDIRECT --to-ports 10080
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 10443

# 2. Accept the published ports (INPUT sees the rewritten dport)
iptables -A <input-chain> -p tcp --dport 10080 -m conntrack --ctstate DNAT -j ACCEPT
iptables -A <input-chain> -p tcp --dport 10443 -m conntrack --ctstate DNAT -j ACCEPT

# 3. Hairpin — REQUIRED, and the one a PREROUTING-only setup misses
iptables -t nat -A OUTPUT -d <public-ip> -p tcp --dport 443 -j REDIRECT --to-ports 10443
iptables -t nat -A OUTPUT -d <public-ip> -p tcp --dport 80  -j REDIRECT --to-ports 10080
```

Rule 3 exists because several containers resolve a *public* hostname and
connect to it — above all the OIDC SP, which server-side fetches
`<salt>.${CATCHER_HOST}/.well-known/openid-configuration` for the mIdP
challenges. Wildcard subdomains cannot be compose network aliases, so that
lookup goes through public DNS to this machine's own address. Such traffic
is locally-originated: it takes `nat/OUTPUT`, never `nat/PREROUTING`.
Before the port split it worked only because podman itself bound
`0.0.0.0:443`.

The `--ctstate DNAT` match in rule 2 keeps the published ports reachable
only through the redirect. Without it `https://host:10443/` answers
directly, and a client that uses it puts `:10443` in its `Host` header,
which ends up in the OIDC discovery `issuer` and breaks ids-1/ids-3/ids-4
for that client. Verify before relying on it — a wrong match takes the
site down.

`just firewall-check` reports on all three groups plus whether anything is
listening, and runs a behavioural hairpin probe that needs no root. If the
admin cannot add rule 3, `just firewall-hairpin` adds it locally and
`just firewall-persist` makes it survive a reboot — both need sudo.

## In-network name resolution

Containers reach the platform through Traefik, and Traefik can only be
addressed by the hostname its routers match on. The `aliases:` on the
traefik service cover a finite list of names — but the catcher hands every
student their own salt subdomain `<salt>.${CATCHER_HOST}`, an unbounded
set, so that list can never be complete.

Without help those names resolve through public DNS to this machine's own
address, and that does not work from a container:

```
container -> getent hosts my.e-attacker.de   132.195.101.17   (correct)
container -> 132.195.101.17:443              REFUSED
container -> 132.195.101.17:10443            OPEN
```

Rootless podman's egress traverses neither the host's `nat/PREROUTING` nor
its `nat/OUTPUT`, so the firewall's 443→10443 redirect never applies. No
host firewall rule fixes this — the name has to resolve *inside* the
compose network.

The `dns` service (CoreDNS, config in `dns/Corefile`) serves one block per
zone — `${HOST1}` and `${CATCHER_HOST}`, handed in from `.env` so they are
not written down twice — rewrites every name in them onto the service
name `traefik`, and forwards everything else to the runtime's own
resolver. The services that need it carry `dns: *dns`.

Adding a hostname under an existing zone needs no change. Adding a whole
new zone means a new block in the Corefile plus a matching
`environment:` entry on the `dns` service.

First start after this change: the `ehacking` network has to be recreated
so the pinned subnet applies — `just down && just up`. Otherwise podman
refuses with `requested static ip ... not in any subnet on network`.

What breaks without it: the OIDC SP's server-side discovery fetch for the
mIdP challenges (ids-1…ids-4) fails with `ConnectException: Connection
refused`, and out-of-band XXE/SSRF exfiltration from xml-sec, soap-sec,
json-sec and rest-api-sec cannot leave the container.

`EHACKING_SUBNET` is pinned only so the resolver can hold a fixed address —
a client can name its resolver by IP alone. Check the range does not
collide with an existing network on the host (`podman network ls`).

## Selecting modules

`just up` brings up every CTF module by default. To run only a subset,
create a gitignored `modules.env` listing the profiles you want:

```bash
# modules.env — skip soap, maze, passkeys
COMPOSE_PROFILES=json,oidc,rest,saml,web,xml,rookies,recruiting,catcher
```

Available profiles (omit to skip):

| Profile | Services |
|---|---|
| `json` | `json-sec` |
| `oidc` | `oidc`, `victim-bot` |
| `rest` | `rest-api-sec`, `couchdb` |
| `saml` | `saml` |
| `soap` | `soap-sec`, `axis2-flag`, `axis2-fake` |
| `web` | `web-sec` |
| `xml` | `xml-sec` |
| `passkeys` | `passkeys-app`, `passkeys-mongo` |
| `maze` | `crawling-maze` |
| `rookies` | `rookies` |
| `recruiting` | `recruiting-challenge`, `recruiting-bot`, `recruiting-instructor` |
| `catcher` | `catcher` (also auto-starts when `oidc` or `saml` is enabled) |

Infrastructure (`traefik`, `root`, `watchtower`) is untagged and always
runs.

Preview which services would start without doing it:

```bash
./bin/compose config --services
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

## Disk space

The CTF images add up to several GiB and every `pull` adds more. A disk
that fills up mid-pull is the nastiest failure mode here — half-extracted
layers, containers that won't start, a compose run that half-succeeded —
so `just up` and `just update` check first:

* below **10 GiB** free: warn, print what can be reclaimed, continue
* below **3 GiB** free: refuse, before anything is pulled

Both thresholds come from `bin/disk.sh` (`DISK_WARN_GIB` / `DISK_MIN_GIB`).
`SKIP_DISK_CHECK=1 just up` overrides once.

Two locations matter, and on a host with split LVs they are different
filesystems: the **image store** (`~/.local/share/containers/storage` under
rootless podman) and the **pull staging dir**, where blobs are written
before they land in the store. podman stages in `/var/tmp` by default —
a 5 GiB `/var` will fail a multi-GiB pull with `no space left on device`
while the image store still has 90 GiB free. Move staging next to the
images:

```bash
mkdir -p ~/.config/containers
# under [engine] in ~/.config/containers/containers.conf:
image_copy_tmp_dir = "storage"
```

`just disk-check` reports both and points this out when staging is on the
smaller filesystem.

```bash
just disk-check   # free space + what the runtime can reclaim
just prune        # dangling images, stopped containers, build cache
just prune-all    # also images no running container uses — asks first
```

`just prune` is safe: it touches nothing a configured module needs.
`just prune-all` is not, in one specific way — a module disabled via
`COMPOSE_PROFILES` has no running container, so its image is dropped and
has to be pulled again on the next `just up`.

Watchtower already runs with `WATCHTOWER_CLEANUP=true`, so the tagged
predecessor of each auto-updated image is removed for you. What still
accumulates is untagged layers from `compose pull`.

## Backup & migration

Everything that makes a deployment unique lives *outside* git: the
gitignored secret/flag files and the stateful named volumes. Two recipes
bundle and restore all of it, so moving e-hacking.de to a new server is
copy-one-file-and-go.

```bash
just backup     # → backups/ehacking-backup-<UTC>.tar.gz
```

The archive contains:

| Group | Contents |
|---|---|
| Files | `cloudflare.env`, `bot.env`, `credentials.env`, `flags_*.env`, `flag_*.{txt,xml}`, `traefik/dynamic/basicauth.yml`, optional `modules.env` / `auth.env` / `.envrc` |
| Volumes | `catcher-data`, `recruiting-data`, `letsencrypt` (certs — kept to dodge ACME rate limits), `passkeys-instance-data`, `passkeys-mongo-data` |

`crawling-maze-sessions` is deliberately excluded — ephemeral per-visitor
crawl state, regenerated on demand. Adjust the lists at the top of
`bin/backup.sh` if the deployment grows new stateful volumes.

Restore on the target host (idempotent; prompts before clobbering). It
lists the archives in `backups/` and asks which one to use — and if the
host already holds deployment data, it offers to snapshot that first
before overwriting:

```bash
just restore
```

Volume data is streamed through a throwaway container on both ends, so a
backup taken under **Docker restores cleanly under rootless Podman** and
vice-versa — the in-container uids are reapplied via the user namespace
on the target, not copied raw off the host.

### Bare-server bootstrap

On a fresh server with neither podman nor docker, `init-podman` can do the
whole "Container runtime" setup below (rootless podman, the compose
provider, subuid/linger) and then restore a backup if one is sitting in
`backups/`. That is host preparation, so it needs root — opt in with
`ALLOW_SUDO=1`. Without it the script stays root-free and prints each step
for the host admin instead (see "Deploying without root").

```bash
git clone <repo> e-Hacking.de && cd e-Hacking.de
# drop your backup in: scp ehacking-backup-*.tar.gz server:e-Hacking.de/backups/
ALLOW_SUDO=1 just init-podman   # interactive; asks for sudo
just up
```

With no backup present it stops short and tells you what a first-time
bring-up still needs (chiefly `cloudflare.env`, then `just init`).

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
