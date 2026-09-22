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

# Where blobs are STAGED during a pull — a different filesystem on a host
# with split LVs, and the one that actually runs out first. podman's
# containers/image writes here (containers.conf `image_copy_tmp_dir`,
# default /var/tmp, overridable with TMPDIR); docker stages inside its own
# data-root, which the graphroot check already covers.
stagedir=""
if [ "${RUNTIME:-}" = "podman" ]; then
    stagedir="${TMPDIR:-}"
    if [ -z "$stagedir" ]; then
        for cc in "${HOME}/.config/containers/containers.conf" /etc/containers/containers.conf; do
            [ -f "$cc" ] || continue
            stagedir=$(sed -n 's/^[[:space:]]*image_copy_tmp_dir[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$cc" | tail -n1 || true)
            [ -n "$stagedir" ] && break
        done
    fi
    [ -n "$stagedir" ] || stagedir="/var/tmp"
    # "storage" means "next to the images" — then it is not a separate risk.
    [ "$stagedir" = "storage" ] && stagedir=""
fi

# On a fresh host a directory may not exist yet — walk up to the nearest
# existing ancestor so df has a real target.
nearest() {
    local pr="$1"
    while [ ! -e "$pr" ] && [ "$pr" != "/" ]; do pr=$(dirname "$pr"); done
    printf '%s\n' "$pr"
}

free_gib_at() {
    local kb
    kb=$(df -Pk "$(nearest "$1")" 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$kb" =~ ^[0-9]+$ ]] || { printf '%s\n' ""; return; }
    printf '%s\n' $(( kb / 1024 / 1024 ))
}

fs_of() { df -P "$(nearest "$1")" 2>/dev/null | awk 'NR==2{print $1}'; }

probe="$graphroot"
free_gib() { free_gib_at "$graphroot"; }

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
    # Both locations matter, and they are often different filesystems:
    # the image store is where layers end up, the staging dir is where a
    # pull writes blobs first. Either running out kills the pull.
    local rc=0 shown=0 path avail label
    for pair in "images:${graphroot}" ${stagedir:+"pull staging:${stagedir}"}; do
        label=${pair%%:*}; path=${pair#*:}
        avail=$(free_gib_at "$path")
        if [ -z "$avail" ]; then
            warn "Could not determine free space at ${path} — continuing."
            continue
        fi
        if [ "$avail" -lt "$MIN_GIB" ]; then
            [ "$shown" -eq 0 ] && { say "Disk space"; shown=1; }
            bad "${label}: only ${avail} GiB free at ${path} (floor: ${MIN_GIB} GiB)."
            rc=1
        elif [ "$avail" -lt "$WARN_GIB" ]; then
            [ "$shown" -eq 0 ] && { say "Disk space"; shown=1; }
            warn "${label}: ${avail} GiB free at ${path} — below the ${WARN_GIB} GiB"
            warn "the CTF images want. Clean up soon."
        else
            good "${label}: ${avail} GiB free at ${path}"
        fi
    done

    # The classic trap: plenty of room for the images, but the staging dir
    # sits on a small /var and the pull dies there with "no space left on
    # device" while this check reported everything fine.
    if [ -n "$stagedir" ] && [ "$(fs_of "$stagedir")" != "$(fs_of "$graphroot")" ]; then
        local sa ga
        sa=$(free_gib_at "$stagedir"); ga=$(free_gib_at "$graphroot")
        if [ -n "$sa" ] && [ -n "$ga" ] && [ "$sa" -lt "$ga" ]; then
            [ "$shown" -eq 0 ] && { say "Disk space"; shown=1; }
            warn "Pull staging (${stagedir}) is on a smaller filesystem than the"
            warn "image store (${graphroot}). A multi-GiB pull will fail there"
            warn "first. Move staging next to the images:"
            info "  mkdir -p ~/.config/containers"
            info "  # add under [engine] in ~/.config/containers/containers.conf:"
            info "  image_copy_tmp_dir = \"storage\""
        fi
    fi

    if [ "$rc" -ne 0 ]; then
        bad "Refusing to pull — a disk that fills mid-pull leaves the stack"
        bad "in a half-updated state that is worse than not starting."
        show_reclaimable
        info ""
        info "To override once:  SKIP_DISK_CHECK=1 just up"
    elif [ "$shown" -ne 0 ]; then
        show_reclaimable
    fi
    return $rc
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
