#!/usr/bin/env bash
# Make the stack survive logging out and rebooting.
#
# Rootless podman runs every container under the operator's own user, which
# means they live and die with that user's systemd instance. By default
# systemd tears that instance down the moment the last session ends — so
# closing the SSH connection stops the platform. "Linger" tells systemd to
# keep the user's instance running with nobody logged in.
#
# Linger alone is not enough. It keeps the user manager alive; it starts no
# container. Two more pieces:
#
#   * `restart: always` on every service in docker-compose.yml, so podman
#     records them as boot-start candidates.
#   * podman-restart.service, the user unit that actually starts them again
#     after a reboot. `always` rather than `unless-stopped` because older
#     podman filters that unit on `restart-policy=always` and would skip
#     `unless-stopped` entirely.
#
#   check    report all three, read-only, no root
#   enable   turn on what is missing (linger needs root once)
set -euo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*" >&2; }
bad()  { printf '    \033[31m✗ %s\033[0m\n' "$*" >&2; }
good() { printf '    \033[32m✓ %s\033[0m\n' "$*"; }

USER_NAME=$(id -un)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

loginctl_ok() {
    command -v loginctl >/dev/null 2>&1 \
        && loginctl show-user "$USER_NAME" -p Linger 2>/dev/null | grep -q '^Linger='
}

has_linger() {
    loginctl_ok || return 1
    loginctl show-user "$USER_NAME" -p Linger 2>/dev/null | grep -q 'Linger=yes'
}

# `systemctl --user` can exit 0 while telling you systemd is not running at
# all (containers, stub implementations). Require a usable manager first,
# then require the literal word — `is-enabled --quiet` alone reports a unit
# as enabled on a host that has no systemd.
systemd_ok() {
    systemctl --user show --property=Version 2>/dev/null | grep -q '^Version='
}

has_restart_unit() {
    systemd_ok || return 1
    [ "$(systemctl --user is-enabled podman-restart.service 2>/dev/null)" = "enabled" ]
}

restart_always_count() {
    grep -c '^ *restart: always' docker-compose.yml 2>/dev/null || echo 0
}

do_check() {
    local rc=0

    say "Linger for ${USER_NAME}"
    if ! loginctl_ok; then
        warn "loginctl cannot report here — cannot tell. Run this on the host."
        rc=1
    elif has_linger; then
        good "enabled — the stack keeps running after you log out"
    else
        bad "disabled — the stack stops when your last session ends"
        info "Fix: just linger-enable   (asks for sudo once)"
        rc=1
    fi

    say "Start after reboot"
    if ! systemd_ok; then
        warn "No usable user systemd here — cannot tell. Run this on the host."
        rc=1
    elif has_restart_unit; then
        good "podman-restart.service is enabled"
    else
        bad "podman-restart.service is not enabled — nothing restarts the"
        bad "containers after a reboot"
        info "Fix: just linger-enable   (no root needed for this part)"
        rc=1
    fi

    say "Restart policy in docker-compose.yml"
    local n
    n=$(restart_always_count)
    if [ "$n" -gt 0 ] && ! grep -q '^ *restart: on-failure' docker-compose.yml; then
        good "${n} services on 'restart: always'"
    else
        bad "some services are not on 'restart: always' — podman-restart.service"
        bad "only starts containers with that policy"
        rc=1
    fi

    [ "$rc" -eq 0 ] && say "All three in place — the stack survives logout and reboot."
    return $rc
}

do_enable() {
    say "Start after reboot"
    if has_restart_unit; then
        info "podman-restart.service already enabled."
    elif systemctl --user enable podman-restart.service 2>/dev/null; then
        good "enabled podman-restart.service"
    else
        warn "Could not enable it from here (no user D-Bus in this session?)."
        warn "Run once after logging in again:"
        warn "  systemctl --user enable podman-restart.service"
    fi

    say "Linger for ${USER_NAME}"
    if has_linger; then
        info "Already enabled."
    else
        info "This is the one step that needs root, once."
        local SUDO=""
        [ "$(id -u)" -eq 0 ] || SUDO="sudo"
        $SUDO loginctl enable-linger "$USER_NAME"
        has_linger && good "enabled" || bad "still reported as disabled — check loginctl"
    fi

    echo
    do_check
}

case "${1:-check}" in
    check)  do_check ;;
    enable) do_enable ;;
    *) echo "usage: $0 [check|enable]" >&2; exit 1 ;;
esac
