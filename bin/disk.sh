#!/usr/bin/env bash
# Free-space guard and cleanup for the container image store.
#
# `just up` and `just update` pull images. A disk that fills up mid-pull
# fails in confusing ways — half-extracted layers, containers that won't
# start, a compose run that half-succeeds — so both check first and say
# what can be reclaimed instead of letting the runtime fail.
#
# Subcommands:
#   check       report free space; exit 1 below the hard floor
#   prune       reclaim the safe things: dangling images, stopped
#               containers, build cache
#   prune-all   also drop images no RUNNING container uses. Asks first,
#               because a module disabled via COMPOSE_PROFILES has no
#               running container and would have to be pulled again.
#
# Thresholds in GiB (override via env):
#   DISK_MIN_GIB   default 3   — below this, `check` fails
#   DISK_WARN_GIB  default 10  — below this, `check` warns
# SKIP_DISK_CHECK=1 bypasses `check` entirely.
set -euo pipefail

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*" >&2; }
bad()  { printf '    \033[31m✗ %s\033[0m\n' "$*" >&2; }
good() { printf '    \033[32m✓ %s\033[0m\n' "$*"; }

MIN_GIB="${DISK_MIN_GIB:-3}"
WARN_GIB="${DISK_WARN_GIB:-10}"

# Runtime detection is best-effort: bin/init-podman.sh calls `check` during
# a bare-server bootstrap, before the podman socket is enabled. Without a
# runtime we can still df the default store path — only prune needs one.
RUNTIME=""
if runtime_env=$(./bin/runtime-env.sh 2>/dev/null); then
    eval "$runtime_env"
fi

require_runtime() {
    [ -n "$RUNTIME" ] && return 0
    bad "No usable container runtime — cannot prune."
    info "Enable the podman socket first:  systemctl --user enable --now podman.socket"
    exit 1
}

# Where the images actually live. Falls back to podman's rootless default
# when the runtime cannot be queried (daemon down, socket not up yet).
graphroot=""
if [ -n "$RUNTIME" ]; then
    graphroot=$("$RUNTIME" info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    [ -n "$graphroot" ] || graphroot=$("$RUNTIME" info --format '{{.DockerRootDir}}' 2>/dev/null || true)
fi
[ -n "$graphroot" ] || graphroot="${HOME}/.local/share/containers/storage"
# On a fresh host the directory may not exist yet — walk up to the nearest
# existing ancestor so df has a real target.
probe="$graphroot"
while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do probe=$(dirname "$probe"); done

free_gib() {
    local kb
    kb=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$kb" =~ ^[0-9]+$ ]] || { printf '%s\n' ""; return; }
    printf '%s\n' $(( kb / 1024 / 1024 ))
}

show_reclaimable() {
    info ""
    if [ -n "$RUNTIME" ]; then
        info "What the runtime thinks it can reclaim:"
        "$RUNTIME" system df 2>/dev/null | sed 's/^/      /' || info "      (unavailable)"
        info ""
    fi
    info "Reclaim it with:  just prune        (safe: dangling + stopped)"
    info "                  just prune-all    (also unused images)"
}

do_check() {
    if [ -n "${SKIP_DISK_CHECK:-}" ]; then
        info "Disk check skipped (SKIP_DISK_CHECK is set)."
        return 0
    fi
    local avail
    avail=$(free_gib)
    if [ -z "$avail" ]; then
        warn "Could not determine free space at ${graphroot} — continuing."
        return 0
    fi
    if [ "$avail" -lt "$MIN_GIB" ]; then
        say "Disk space"
        bad "Only ${avail} GiB free at ${graphroot} (floor: ${MIN_GIB} GiB)."
        bad "Refusing to pull — a disk that fills mid-pull leaves the stack"
        bad "in a half-updated state that is worse than not starting."
        show_reclaimable
        info ""
        info "To override once:  SKIP_DISK_CHECK=1 just up"
        return 1
    fi
    if [ "$avail" -lt "$WARN_GIB" ]; then
        say "Disk space"
        warn "${avail} GiB free at ${graphroot} — below the ${WARN_GIB} GiB"
        warn "the CTF images want. Continuing, but clean up soon."
        show_reclaimable
        return 0
    fi
    good "${avail} GiB free at ${graphroot}"
    return 0
}

do_prune() {
    require_runtime
    local before after
    before=$(free_gib)
    say "Pruning (dangling images, stopped containers, build cache)"
    # Watchtower already runs with WATCHTOWER_CLEANUP=true, so tagged
    # predecessors are usually gone. What accumulates is untagged layers
    # from `compose pull` and from watchtower's own failed/partial runs.
    "$RUNTIME" image prune -f 2>&1 | sed 's/^/    /' || true
    "$RUNTIME" container prune -f 2>&1 | sed 's/^/    /' || true
    "$RUNTIME" builder prune -f 2>&1 | sed 's/^/    /' || true
    after=$(free_gib)
    [ -n "$before" ] && [ -n "$after" ] \
        && good "free space: ${before} GiB -> ${after} GiB" \
        || true
}

do_prune_all() {
    require_runtime
    say "Aggressive prune"
    warn "This also removes images no RUNNING container uses. Any module"
    warn "currently disabled via COMPOSE_PROFILES loses its image and will"
    warn "be pulled again on the next 'just up'."
    local reply
    read -r -p "    Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }
    local before after
    before=$(free_gib)
    "$RUNTIME" image prune -a -f 2>&1 | sed 's/^/    /' || true
    "$RUNTIME" container prune -f 2>&1 | sed 's/^/    /' || true
    "$RUNTIME" builder prune -f 2>&1 | sed 's/^/    /' || true
    after=$(free_gib)
    [ -n "$before" ] && [ -n "$after" ] \
        && good "free space: ${before} GiB -> ${after} GiB" \
        || true
}

case "${1:-check}" in
    check)     do_check ;;
    prune)     do_prune ;;
    prune-all) do_prune_all ;;
    *) echo "usage: $0 [check|prune|prune-all]" >&2; exit 1 ;;
esac
