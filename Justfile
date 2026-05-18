# eHacking deployment recipes for e-hacking.de.
#
# All recipes inherit COMPOSE_ENV_FILES so docker-compose interpolation
# sees every secret file. Requires Docker Compose v2.24+ (Jan 2024).
# auth.env is gone — basicauth lives in traefik/dynamic/basicauth.yml
# and is loaded by Traefik's file provider, not Compose interpolation.

export COMPOSE_ENV_FILES := ".env,cloudflare.env,bot.env,credentials.env"

default:
    @just --list

# Bring the stack up in the background. Refuses to start if basicauth
# isn't configured — without it the dashboard router would attach no
# middleware and the API would be open. Run `just init` first.
up:
    @test -e traefik/dynamic/basicauth.yml || { echo "Missing traefik/dynamic/basicauth.yml — run 'just init' or 'just add-basicauth-user <name>' first."; exit 1; }
    docker compose up -d

# Tear the stack down (containers only; named volumes are kept).
down:
    docker compose down

# Pull-rebuild-restart cycle. Equivalent to `./bin/update.sh`.
update:
    git pull
    docker compose pull
    @just up

# Pull all images without restarting anything.
pull:
    docker compose pull

# First-time setup: bootstrap every secret + flag file the stack needs.
# Each helper refuses to overwrite an existing file, so re-running is
# safe — it only fills in what's missing. cloudflare.env is
# operator-supplied (LE DNS-01 token).
init:
    @test -e cloudflare.env || { echo "Missing cloudflare.env. Create it first:"; echo "  echo CF_DNS_API_TOKEN=<zone-dns-edit-token> > cloudflare.env"; exit 1; }
    @test -e traefik/dynamic/basicauth.yml || ./bin/make-auth.sh
    @test -e bot.env || ./bin/make-bot-env.sh
    @test -e credentials.env || ./bin/make-credentials.sh
    ./bin/make-flags.sh
    @echo
    @echo "Ready. Run 'just up' to start the stack."

# Rotate every flag + credential. Wipes basicauth / bot / credentials
# and the managed flag files, then re-runs init. cloudflare.env,
# letsencrypt state, and any third-party flag file
# (e.g. flags_crawling-maze.env) are preserved.
reset:
    rm -f auth.env bot.env credentials.env \
        traefik/dynamic/basicauth.yml \
        flags_axis2-flag.env flags_json-sec.env flags_oidc.env \
        flags_rest-api-sec.env flags_saml.env flags_soap-sec.env \
        flags_xml-sec.env \
        flag_xslt1.xml flag_xxe1.txt flag_xxe2.txt
    @just init

# Append a new user to the shared Traefik basicauth middleware. First
# call creates traefik/dynamic/basicauth.yml; subsequent calls append.
# Traefik watches the file and hot-reloads, so no restart is needed.
add-basicauth-user USER='':
    ./bin/make-auth.sh {{USER}}

# Tail logs. Pass a service name to scope: `just logs catcher`.
logs SERVICE='':
    docker compose logs -f {{SERVICE}}

# Show service status.
ps:
    docker compose ps

# Restart a single service. Useful after editing its flag file.
restart SERVICE:
    docker compose up -d --force-recreate {{SERVICE}}
