#!/usr/bin/env bash
# Check the in-network resolver: can a container reach the platform under
# the hostnames students use?
#
# This is the question the deployment actually turns on. Traefik can only
# be addressed by the hostname its routers match on, and the catcher hands
# every student their own salt subdomain — an unbounded set no alias list
# can cover. Without the resolver those names go out to public DNS, land on
# this machine's own public address, and are refused, because rootless
# podman's egress traverses none of the host's nat rules.
#
# The visible symptom is the OIDC SP's server-side discovery fetch failing
# with `ConnectException: Connection refused`, taking ids-1..ids-4 with it,
# plus out-of-band XXE/SSRF exfiltration from xml-sec, soap-sec, json-sec
# and rest-api-sec silently never leaving the container.
#
# Read-only. Needs no root.
set -euo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*" >&2; }
bad()  { printf '    \033[31m✗ %s\033[0m\n' "$*" >&2; }
good() { printf '    \033[32m✓ %s\033[0m\n' "$*"; }

RUNTIME=""
if runtime_env=$(./bin/runtime-env.sh 2>/dev/null); then eval "$runtime_env"; fi
[ -n "$RUNTIME" ] || { echo "No usable container runtime." >&2; exit 1; }

from_env() {  # from_env VAR DEFAULT
    local v
    v=$(for f in .env modules.env; do
        [ -f "$f" ] || continue
        sed -n "s/\r$//; s/^$1=\(.*\)$/\1/p" "$f"
    done | tail -n1 || true)
    printf '%s\n' "${v:-$2}"
}

CATCHER_HOST=$(from_env CATCHER_HOST "")
HOST1=$(from_env HOST1 "")
RESOLVER=$(from_env DNS_RESOLVER_IP 10.53.0.53)
PROJECT=$(./bin/compose config --format json 2>/dev/null \
    | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)
[ -n "$PROJECT" ] || PROJECT=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
NET="${PROJECT}_ehacking"

rc=0

say "Resolver"
if "$RUNTIME" ps --format '{{.Names}}' 2>/dev/null | grep -q -- '-dns-'; then
    good "the dns service is running"
else
    bad "no dns container is running — 'just up' first"
    exit 1
fi

# A salt nobody has ever created. The whole point is that the resolver
# answers for names that are not on any list, so testing a known one would
# prove nothing.
SALT="zz$(date +%s)"

say "Names, from a container on ${NET}"
probe() {  # probe <name> <expect-traefik|expect-external>
    local name="$1" kind="$2" out
    out=$("$RUNTIME" run --rm --network "$NET" --dns "$RESOLVER" \
            docker.io/library/alpine getent ahostsv4 "$name" 2>/dev/null \
          | awk '{print $1; exit}' || true)
    if [ -z "$out" ]; then
        bad "${name} does not resolve"
        rc=1
        return
    fi
    case "$kind" in
        traefik)
            # Anything inside the compose network is right; a public address
            # means the query escaped to public DNS, which is the bug.
            if printf '%s' "$out" | grep -qE '^(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.'; then
                good "${name} -> ${out}"
            else
                bad "${name} -> ${out} (public address — the resolver was bypassed)"
                rc=1
            fi ;;
        external)
            good "${name} -> ${out}" ;;
    esac
}

[ -n "$CATCHER_HOST" ] && probe "${SALT}.${CATCHER_HOST}" traefik
[ -n "$CATCHER_HOST" ] && probe "$CATCHER_HOST" traefik
[ -n "$HOST1" ] && probe "$HOST1" traefik
probe traefik traefik          # service names must keep working
probe example.com external     # and so must the rest of the internet

say "Reachability"
if [ -n "$CATCHER_HOST" ]; then
    PUB_HTTPS=$(from_env PORT_HTTPS 443)
    if "$RUNTIME" run --rm --network "$NET" --dns "$RESOLVER" \
         docker.io/library/alpine \
         sh -c "echo | nc -w5 ${SALT}.${CATCHER_HOST} ${PUB_HTTPS}" >/dev/null 2>&1; then
        good "a container reaches ${SALT}.${CATCHER_HOST}:${PUB_HTTPS}"
    else
        bad "a container cannot reach ${SALT}.${CATCHER_HOST}:${PUB_HTTPS}"
        info "The name resolves but the port does not answer — check that"
        info "traefik listens on ${PUB_HTTPS} inside its own netns."
        rc=1
    fi
fi

if [ "$rc" -ne 0 ]; then
    say "If this fails"
    info "podman logs \$(${RUNTIME} ps --format '{{.Names}}' | grep -m1 -- '-dns-')"
    info "A crash loop on 'permission denied' reading the Corefile means the"
    info "bind mount lost its SELinux label or the container is not running"
    info "as root — see the dns service in docker-compose.yml."
fi

exit $rc
