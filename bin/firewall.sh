#!/usr/bin/env bash
# Host firewall helpers for the 80->10080 / 443->10443 port split.
#
# The redirect itself (nat/PREROUTING) and the INPUT accepts for the
# published ports are managed by the host admin. What this script adds is
# the piece their tooling cannot cover: nat/OUTPUT.
#
# Why OUTPUT is needed. Several containers resolve a PUBLIC hostname and
# connect to it — most importantly the OIDC SP, which server-side fetches
# `<salt>.<CATCHER_HOST>/.well-known/openid-configuration` for the mIdP
# challenges (ids-1..ids-4). Wildcard subdomains cannot be compose network
# aliases, so those lookups go through public DNS to this machine's own
# address. That is locally-originated traffic: it traverses nat/OUTPUT, not
# nat/PREROUTING, so the admin's redirect does not apply. Before the port
# split it worked by accident, because podman itself bound 0.0.0.0:443.
#
# Subcommands:
#   check    read-only diagnosis; exits non-zero if something is missing
#   hairpin  add the nat/OUTPUT redirects (idempotent, needs sudo)
#   persist  install a systemd unit that re-applies `hairpin` on boot
#
# Override the detected addresses with PUBLIC_IPS="1.2.3.4 5.6.7.8".
set -euo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*" >&2; }
bad()  { printf '    \033[31m✗ %s\033[0m\n' "$*" >&2; }
good() { printf '    \033[32m✓ %s\033[0m\n' "$*"; }

need_sudo() {
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; return; fi
    command -v sudo >/dev/null 2>&1 || { echo "needs root and sudo is missing" >&2; exit 1; }
    SUDO="sudo"
}

require_iptables() {
    command -v iptables >/dev/null 2>&1 \
        || { echo "iptables not found" >&2; exit 1; }
}

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

# The addresses a container actually reaches when it resolves one of our
# public hostnames — intersected with the addresses this host actually
# holds. Both halves are needed:
#
#   * DNS alone is wrong. A hostname behind a CDN (e-hacking.de is
#     Cloudflare-proxied) resolves to the CDN's anycast addresses, and
#     redirecting those would hijack the host's own outbound HTTPS to
#     every site on that range.
#   * `ip addr` alone is wrong too: it yields the podman/docker bridge
#     gateways (10.88.0.1, 172.17.0.1, …) that nothing resolves to.
#
# Their intersection is exactly "our own address, reachable under a public
# name" — which is what hairpins back to us.
detect_ips() {
    local hosts h resolved="" local_addrs ip
    hosts=$(for f in .env modules.env; do
        [ -f "$f" ] || continue
        sed -n 's/\r$//; s/^\(HOST1\|HOST2\|CATCHER_HOST\|IDP_HOST\|SP_HOST\|SPA_HOST\|RS_HOST\)=\(.*\)$/\2/p' "$f"
    done | sort -u || true)
    for h in $hosts; do
        resolved="$resolved $(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    done
    local_addrs=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{split($4,a,"/"); print a[1]}' | sort -u || true)
    for ip in $(printf '%s\n' $resolved | sort -u); do
        printf '%s\n' $local_addrs | grep -qxF "$ip" && printf '%s\n' "$ip"
    done
    return 0
}
IPS=${PUBLIC_IPS:-$(detect_ips)}

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

    # Behavioural probe, no root required. A request from this host to a
    # public hostname is locally-originated, so it takes nat/OUTPUT — the
    # same path a container takes (rootless podman egress is a host-side
    # socket). If this works, the hairpin works.
    say "Hairpin probe (no root needed)"
    local host1
    host1=$(for f in .env modules.env; do
        [ -f "$f" ] || continue
        sed -n 's/\r$//; s/^HOST1=\(.*\)$/\1/p' "$f"
    done | tail -n1 || true)
    if [ -z "$host1" ]; then
        warn "HOST1 not set in .env — skipping."
    elif ! command -v curl >/dev/null 2>&1; then
        warn "curl not installed — skipping."
    else
        local code
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
                 "https://${host1}/" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            good "https://${host1}/ from this host -> HTTP ${code}"
        else
            bad "https://${host1}/ from this host is unreachable"
            info "That is the hairpin: containers resolving a public hostname"
            info "fail the same way. Fix with 'just firewall-hairpin' or have"
            info "the admin add the nat/OUTPUT rules."
            rc=1
        fi
    fi
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

    say "nat/OUTPUT — hairpin (ours)"
    if [ -z "$IPS" ]; then
        bad "No configured hostname resolves to an address this host holds."
        info "Either this is not the deploy host, or it sits behind 1:1 NAT"
        info "and does not carry its public address. In the latter case set"
        info "PUBLIC_IPS=\"<addr>\" explicitly."
        return 1
    fi
    for ip in $IPS; do
        for pair in "${PUB_HTTP}:${HOST_HTTP}" "${PUB_HTTPS}:${HOST_HTTPS}"; do
            local from=${pair%%:*} to=${pair##*:}
            if $SUDO_RO iptables -t nat -C OUTPUT -d "$ip" -p tcp --dport "$from" \
                 -j REDIRECT --to-ports "$to" 2>/dev/null; then
                good "${ip}:${from} -> ${to}"
            else
                bad "missing: ${ip}:${from} -> ${to}   (just firewall-hairpin)"
                rc=1
            fi
        done
    done

    say "Direct exposure of the published ports"
    info "A client reaching ${HOST_HTTPS} directly puts that port in its Host"
    info "header, which lands in the OIDC discovery issuer and breaks"
    info "ids-1/ids-3/ids-4 for that client. Recommended INPUT rule:"
    info "  -p tcp --dport ${HOST_HTTPS} -m conntrack --ctstate DNAT -j ACCEPT"
    info "(Never applied automatically: a wrong match locks the site out.)"

    return $rc
}

do_hairpin() {
    require_iptables
    need_sudo
    if [ -z "$IPS" ]; then
        bad "No configured hostname resolves to an address this host holds —"
        bad "refusing to guess which address to redirect."
        info "Set PUBLIC_IPS=\"<addr>\" if this host is behind 1:1 NAT."
        exit 1
    fi
    if [ "$HOST_HTTP" = "$PUB_HTTP" ] && [ "$HOST_HTTPS" = "$PUB_HTTPS" ]; then
        info "Host ports equal the public ports — no hairpin rule needed."
        return 0
    fi
    say "nat/OUTPUT redirects"
    for ip in $IPS; do
        for pair in "${PUB_HTTP}:${HOST_HTTP}" "${PUB_HTTPS}:${HOST_HTTPS}"; do
            local from=${pair%%:*} to=${pair##*:}
            if $SUDO iptables -t nat -C OUTPUT -d "$ip" -p tcp --dport "$from" \
                 -j REDIRECT --to-ports "$to" 2>/dev/null; then
                info "already present: ${ip}:${from} -> ${to}"
            else
                info "adding: ${ip}:${from} -> ${to}"
                $SUDO iptables -t nat -A OUTPUT -d "$ip" -p tcp --dport "$from" \
                    -j REDIRECT --to-ports "$to" \
                    -m comment --comment "eHacking hairpin"
            fi
        done
    done
    info "Not persistent yet — run 'just firewall-persist' to survive a reboot."
}

do_persist() {
    require_iptables
    need_sudo
    local unit=/etc/systemd/system/ehacking-firewall.service
    say "systemd unit"
    # A unit that re-runs this script is deliberately chosen over
    # iptables-save: the admin's HARDENING_*/SERVICE_*/DEFAULT_* chains are
    # generated by their own tooling, and dumping the live ruleset would
    # freeze a copy of it that then drifts from their config.
    $SUDO tee "$unit" >/dev/null <<EOF
[Unit]
Description=eHacking: nat/OUTPUT hairpin redirects for the published ports
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/bin/firewall.sh hairpin

[Install]
WantedBy=multi-user.target
EOF
    info "wrote ${unit}"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now ehacking-firewall.service
    good "enabled — rules are re-applied on boot"
    warn "If the admin's firewall tooling flushes the nat table at runtime,"
    warn "the rules go with it. Then ask them to adopt the two OUTPUT rules"
    warn "into their own config instead."
}

SUDO_RO=""
[ "$(id -u)" -eq 0 ] || SUDO_RO="sudo"

case "${1:-check}" in
    check)   do_check ;;
    hairpin) do_hairpin ;;
    persist) do_persist ;;
    *) echo "usage: $0 [check|hairpin|persist]" >&2; exit 1 ;;
esac
