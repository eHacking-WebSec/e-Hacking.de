#!/usr/bin/env bash
# Detect container runtime + emit eval-able assignments on stdout.
# Preference: rootless podman > rootful podman > docker.
#
# Usage:
#   runtime_env=$(./bin/runtime-env.sh) || exit 1
#   eval "$runtime_env"
#
# Honored overrides (set in shell or .env before invocation):
#   RUNTIME=podman|docker   force a runtime, skip detection
#   CONTAINER_SOCKET=path   bypass socket discovery (operator override)
set -e

err() { printf '%s\n' "$*" >&2; }

runtime_pref="${RUNTIME:-}"
socket_override="${CONTAINER_SOCKET:-}"

probe_podman() {
    command -v podman >/dev/null 2>&1 || return 1
    # Require `podman compose` (compose-go wrapper). The legacy
    # `podman-compose` (Python) groups every service into one pod,
    # which collapses our Traefik routing — refuse it.
    if ! podman compose version >/dev/null 2>&1; then
        if command -v podman-compose >/dev/null 2>&1; then
            err "podman is installed, but only the legacy 'podman-compose'"
            err "(Python) was found. We need 'podman compose' (the wrapper —"
            err "compose-go based). The legacy tool puts every service into"
            err "one pod, which breaks our service DNS / Traefik routing."
            err "Install Podman 4+ with the docker-compose plugin, or set"
            err "RUNTIME=docker to bypass."
            return 1
        fi
        err "podman is installed, but the 'podman compose' subcommand is not"
        err "available. Install the docker-compose plugin podman delegates to."
        return 1
    fi
    return 0
}

pick_podman_socket() {
    # Rootless first — preferred for security (no daemon, no root).
    local rootless="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [ -S "$rootless" ]; then
        printf '%s\n' "$rootless"
        return 0
    fi
    if [ -S "/run/podman/podman.sock" ]; then
        printf '%s\n' "/run/podman/podman.sock"
        return 0
    fi
    return 1
}

probe_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    if ! docker compose version >/dev/null 2>&1; then
        err "docker is installed, but 'docker compose' subcommand is missing."
        err "Install Compose v2 (docker-compose-plugin)."
        return 1
    fi
    return 0
}

case "$runtime_pref" in
    podman)
        probe_podman || exit 1
        runtime=podman
        ;;
    docker)
        probe_docker || exit 1
        runtime=docker
        ;;
    "")
        if probe_podman; then
            runtime=podman
        elif probe_docker; then
            runtime=docker
        else
            err "No usable container runtime found."
            err "Install Podman (preferred) or Docker, then re-run."
            exit 1
        fi
        ;;
    *)
        err "RUNTIME='$runtime_pref' is not valid (use 'podman' or 'docker')."
        exit 1
        ;;
esac

if [ "$runtime" = "podman" ]; then
    if [ -n "$socket_override" ]; then
        socket="$socket_override"
    elif ! socket="$(pick_podman_socket)"; then
        err "Podman is installed but no socket is reachable."
        err "Enable one with:"
        err "  systemctl --user enable --now podman.socket   # rootless (preferred)"
        err "  sudo systemctl enable --now podman.socket     # rootful (fallback)"
        exit 1
    fi
    compose_file="docker-compose.yml:compose.podman.yml"
    # Compose merges volume lists additively in overrides — we can't replace
    # a base file mount via override. So the full mount-string is plumbed
    # through ENV. :Z = private SELinux relabel (rootless podman needs this).
    traefik_sock_mount="${socket}:/var/run/docker.sock:Z"
    watchtower_sock_mount="${socket}:/var/run/docker.sock:Z"
else
    socket="${socket_override:-/var/run/docker.sock}"
    compose_file="docker-compose.yml"
    # Docker defaults: traefik ro, watchtower rw — preserved via the
    # ${VAR:-default} in docker-compose.yml when we leave these unset.
    traefik_sock_mount=""
    watchtower_sock_mount=""
fi

printf 'RUNTIME=%s\n' "$runtime"
printf 'CONTAINER_SOCKET=%s\n' "$socket"
printf 'COMPOSE_FILE=%s\n' "$compose_file"
if [ -n "$traefik_sock_mount" ]; then
    printf 'TRAEFIK_SOCK_MOUNT=%s\n' "$traefik_sock_mount"
fi
if [ -n "$watchtower_sock_mount" ]; then
    printf 'WATCHTOWER_SOCK_MOUNT=%s\n' "$watchtower_sock_mount"
fi
