#!/usr/bin/env bash
# Check the host firewall against the 80->10080 / 443->10443 port split.
#
# Read-only. The inbound redirect (nat/PREROUTING) and the INPUT accepts for
# the published ports are managed by the host admin; this reports whether
# they are in place and whether anything is listening behind them.
#
# It used to also add nat/OUTPUT rules so containers could reach
# the platform through the host's public address. That was the wrong layer:
# rootless podman's egress traverses neither nat/PREROUTING nor nat/OUTPUT,
# measured on this host (container -> <public-ip>:443 REFUSED while :10443
# was OPEN). Containers now resolve the platform's hostnames to traefik
# in-network instead — see dns/Corefile and `just dns-check`.
#
#   check    read-only diagnosis; exits non-zero if something is missing
#
set -euo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*" >&2; }
bad()  { printf '    \033[31m✗ %s\033[0m\n' "$*" >&2; }
good() { printf '    \033[32m✓ %s\033[0m\n' "$*"; }

# Host ports from .env (modules.env wins), matching bin/compose's file order.
port_from_env() {  # port_from_env VAR DEFAULT
    local v
    v=$(for f in .env modules.env; do
        [ -f "$f" ] || continue
        sed -n "s/\r$//; s/^$1=\([0-9]\+\)$/\1/p" "$f"
    done | tail -n1 || true)
    printf '%s\n' "${v:-$2}"
}

HOST_HTTP=$(port_from_env HOST_PORT_HTTP 80)
HOST_HTTPS=$(port_from_env HOST_PORT_HTTPS 443)
PUB_HTTP=$(port_from_env PORT_HTTP 80)
PUB_HTTPS=$(port_from_env PORT_HTTPS 443)

# ----------------------------------------------------------------------

do_check() {
    local rc=0

    say "Ports"
    info "public (in URLs, container-side):  ${PUB_HTTP} / ${PUB_HTTPS}"
    info "published on the host:             ${HOST_HTTP} / ${HOST_HTTPS}"
    if [ "$HOST_HTTP" = "$PUB_HTTP" ] && [ "$HOST_HTTPS" = "$PUB_HTTPS" ]; then
        info "Host == container: no redirect needed, nothing else to check."
        return 0
    fi

    say "Listeners"
    for p in "$HOST_HTTP" "$HOST_HTTPS"; do
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then
            good "something is listening on ${p}"
        else
            bad "nothing is listening on ${p} — is the stack up?"
            rc=1
        fi
    done

    info "Inbound (the internet -> ${PUB_HTTPS} -> ${HOST_HTTPS}) cannot be"
    info "probed from here — it needs a request from outside this host."

    if $SUDO_RO iptables -t nat -S PREROUTING >/dev/null 2>&1; then
        :
    else
        say "Rule inspection"
        info "Skipped: reading iptables needs root, and none is available."
        info "The probe above already covers the behaviour that matters here."
        return $rc
    fi

    say "nat/PREROUTING — inbound redirect (admin-managed)"
    for pair in "${PUB_HTTP}:${HOST_HTTP}" "${PUB_HTTPS}:${HOST_HTTPS}"; do
        local from=${pair%%:*} to=${pair##*:}
        if $SUDO_RO iptables -t nat -S PREROUTING 2>/dev/null \
             | grep -qE -- "--dport ${from}\b.*(--to-ports ${to}\b|--to-destination [^ ]*:${to}\b)"; then
            good "${from} -> ${to}"
        else
            bad "no redirect ${from} -> ${to} — ask the host admin"
            rc=1
        fi
    done

    say "filter/INPUT — accept on the published ports (admin-managed)"
    local rules
    rules=$($SUDO_RO iptables -S 2>/dev/null || true)
    for p in "$HOST_HTTP" "$HOST_HTTPS"; do
        local line
        line=$(printf '%s\n' "$rules" | grep -E -- "--dport ${p}\b.*-j ACCEPT" | head -n1 || true)
        if [ -z "$line" ]; then
            bad "nothing accepts ${p} — inbound traffic dies after the redirect"
            rc=1
        elif printf '%s' "$line" | grep -q -- "--ctstate DNAT"; then
            good "${p} accepted, scoped to redirected traffic"
        else
            warn "${p} accepted from anywhere — direct access is possible"
        fi
    done

    say "Direct exposure of the published ports"
    info "A client reaching ${HOST_HTTPS} directly puts that port in its Host"
    info "header, which lands in the OIDC discovery issuer and breaks"
    info "ids-1/ids-3/ids-4 for that client. Recommended INPUT rule:"
    info "  -p tcp --dport ${HOST_HTTPS} -m conntrack --ctstate DNAT -j ACCEPT"
    info "(Never applied automatically: a wrong match locks the site out.)"

    return $rc
}

# -n: never prompt. This is a read-only check and advertises itself as
# working without root, so it degrades instead of stopping at a password
# prompt the caller did not ask for.
SUDO_RO=""
[ "$(id -u)" -eq 0 ] || SUDO_RO="sudo -n"

case "${1:-check}" in
    check) do_check ;;
    *) echo "usage: $0 check" >&2; exit 1 ;;
esac
