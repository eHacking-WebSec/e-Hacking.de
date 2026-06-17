#!/usr/bin/env bash
# Prepare a bare server to run the e-hacking.de stack with rootless
# Podman, then hand off to backup-restore or first-time init.
#
# Idempotent: every step probes current state and only changes the delta,
# so re-running is safe. It may call sudo for the handful of system-level
# steps (package install, the unprivileged-port sysctl, linger) and is
# interactive where a human has to decide (e.g. restore a backup or not).
#
# Run as the unprivileged user that will OWN the stack — not as root.
# Rootless Podman keeps every container in that user's namespace.
#
# Steps:
#   1. Packages: podman + rootless deps + a compose-go provider.
#   2. Rootless plumbing: subuid/subgid, the user podman.socket.
#   3. Host: unprivileged low ports (sysctl) + linger.
#   4. Hand-off: restore a backup if present, else list what's still
#      needed (cloudflare.env etc.) before `just init && just up`.
#
# Usage:
#   ./bin/init-podman.sh                 # auto-detect a backup in backups/
#   ./bin/init-podman.sh path/to/backup.tar.gz
set -euo pipefail

cd "$(dirname "$0")/.."

# Pin a Compose v2 fallback only if the distro ships none. Override with
# COMPOSE_VERSION=vX.Y.Z to skip the GitHub "latest" lookup entirely.
COMPOSE_VERSION="${COMPOSE_VERSION:-}"

BACKUP_ARG="${1:-}"

# ----------------------------------------------------------------------
# Helpers.
# ----------------------------------------------------------------------

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*" >&2; }

confirm() {  # confirm "question" -> 0 if yes (default No)
    local reply
    read -r -p "    $1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

need_sudo() {
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; return; fi
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; return; fi
    echo "This step needs root and 'sudo' is not installed. Re-run as root or install sudo." >&2
    exit 1
}

if [ "$(id -u)" -eq 0 ]; then
    warn "Running as root. Rootless Podman wants a regular user — the stack"
    warn "will be owned by root. Press Ctrl-C to abort, or continue anyway."
    sleep 3
fi

# ----------------------------------------------------------------------
# Package manager detection.
# ----------------------------------------------------------------------

if   command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf      >/dev/null 2>&1; then PKG=dnf
else
    echo "Unsupported distro: need apt-get (Ubuntu/Debian) or dnf (Fedora/RHEL)." >&2
    echo "Install podman + a 'podman compose' provider manually, then run 'just init'." >&2
    exit 1
fi

pkg_install() {  # pkg_install pkg...
    need_sudo
    case "$PKG" in
        apt) $SUDO apt-get update -qq && $SUDO apt-get install -y "$@" ;;
        dnf) $SUDO dnf install -y "$@" ;;
    esac
}

# ----------------------------------------------------------------------
# 1. Packages.
# ----------------------------------------------------------------------

say "Packages"
if command -v podman >/dev/null 2>&1; then
    info "podman present: $(podman --version)"
else
    info "Installing podman + rootless dependencies…"
    case "$PKG" in
        # uidmap = newuidmap/newgidmap (rootless), slirp4netns/passt =
        # rootless networking, fuse-overlayfs = rootless storage driver.
        apt) pkg_install podman uidmap slirp4netns fuse-overlayfs curl ca-certificates ;;
        dnf) pkg_install podman slirp4netns fuse-overlayfs curl ca-certificates ;;
    esac
fi

# `podman compose` must resolve to a compose-go provider (docker compose
# v2). The legacy python podman-compose is rejected by runtime-env.sh.
say "Compose provider"
if podman compose version >/dev/null 2>&1; then
    info "'podman compose' works: $(podman compose version 2>/dev/null | head -n1)"
else
    info "No compose-go provider found — installing the Docker Compose v2 binary."
    command -v curl >/dev/null 2>&1 || pkg_install curl
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  asset=x86_64 ;;
        aarch64|arm64) asset=aarch64 ;;
        armv7l)        asset=armv7 ;;
        *) echo "Unknown CPU arch '$arch' — install 'docker compose' v2 by hand." >&2; exit 1 ;;
    esac
    if [ -z "$COMPOSE_VERSION" ]; then
        # Resolve the latest tag from the release redirect (no jq needed).
        COMPOSE_VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            https://github.com/docker/compose/releases/latest | sed 's#.*/tag/##')
    fi
    [ -n "$COMPOSE_VERSION" ] || { echo "Could not resolve a Compose version; set COMPOSE_VERSION." >&2; exit 1; }
    info "Compose ${COMPOSE_VERSION} (${asset}) -> /usr/local/bin/docker-compose"
    need_sudo
    $SUDO curl -fsSL \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${asset}" \
        -o /usr/local/bin/docker-compose
    $SUDO chmod +x /usr/local/bin/docker-compose
    if ! podman compose version >/dev/null 2>&1; then
        warn "Installed /usr/local/bin/docker-compose but 'podman compose' still"
        warn "can't see it. Point podman at it explicitly:"
        warn "  mkdir -p ~/.config/containers"
        warn "  printf '[engine]\\ncompose_providers=[\"/usr/local/bin/docker-compose\"]\\n' >> ~/.config/containers/containers.conf"
        exit 1
    fi
    info "'podman compose' works now."
fi

# ----------------------------------------------------------------------
# Disk space at podman's image store. The CTF images add up to several
# GiB; warn (but let the operator override) below a 10 GiB floor.
# ----------------------------------------------------------------------

say "Image store free space"
MIN_GIB=10
graphroot=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
[ -n "$graphroot" ] || graphroot="${HOME}/.local/share/containers/storage"
# The store dir may not exist yet on a fresh install — walk up to the
# nearest existing ancestor so df has a real target.
probe="$graphroot"
while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do probe=$(dirname "$probe"); done
avail_kb=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2{print $4}')
if ! [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
    warn "Could not determine free space at ${graphroot}."
    confirm "Continue anyway?" || { info "Aborted."; exit 1; }
else
    avail_gib=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_kb" -lt $(( MIN_GIB * 1024 * 1024 )) ]; then
        warn "Only ${avail_gib} GiB free at ${graphroot} — below the ${MIN_GIB} GiB"
        warn "recommended for the container images."
        confirm "Continue anyway?" || { info "Aborted."; exit 1; }
    else
        info "${avail_gib} GiB free at ${graphroot} (>= ${MIN_GIB} GiB)."
    fi
fi

# ----------------------------------------------------------------------
# 2. Rootless plumbing: subuid/subgid + the user socket.
# ----------------------------------------------------------------------

say "Rootless namespace"
if [ "$(id -u)" -ne 0 ]; then
    user=$(id -un)
    if grep -q "^${user}:" /etc/subuid 2>/dev/null && grep -q "^${user}:" /etc/subgid 2>/dev/null; then
        info "subuid/subgid already allocated for ${user}."
    else
        info "Allocating a subuid/subgid range for ${user}…"
        need_sudo
        $SUDO usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$user"
        $SUDO podman system migrate 2>/dev/null || true
    fi
else
    info "(root) skipping subuid/subgid allocation."
fi

say "Rootless podman socket"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if systemctl --user is-active --quiet podman.socket 2>/dev/null; then
    info "podman.socket already active for this user."
elif systemctl --user enable --now podman.socket 2>/dev/null; then
    info "Enabled podman.socket."
else
    warn "Could not enable the user podman.socket from here (no user D-Bus?)."
    warn "After enabling linger below, log out and back in, then run:"
    warn "  systemctl --user enable --now podman.socket"
fi

# ----------------------------------------------------------------------
# 3. Host: unprivileged low ports + linger.
# ----------------------------------------------------------------------

say "Unprivileged low ports (80/443)"
cur=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)
if [ "$cur" -le 80 ]; then
    info "ip_unprivileged_port_start=${cur} already allows binding 80/443."
else
    info "Lowering ip_unprivileged_port_start to 80 (currently ${cur})…"
    need_sudo
    echo 'net.ipv4.ip_unprivileged_port_start=80' | $SUDO tee /etc/sysctl.d/podman-lowports.conf >/dev/null
    $SUDO sysctl --quiet -w net.ipv4.ip_unprivileged_port_start=80
fi

say "Linger (keep the stack alive past logout)"
if [ "$(id -u)" -eq 0 ]; then
    info "(root) linger not applicable."
elif loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    info "Linger already enabled for $(id -un)."
else
    info "Enabling linger for $(id -un)…"
    need_sudo
    $SUDO loginctl enable-linger "$(id -un)"
fi

# ----------------------------------------------------------------------
# 4. Hand-off: restore a backup, or list what's still missing.
# ----------------------------------------------------------------------

say "Deployment state"

# Find a backup: explicit arg wins, else newest in backups/.
backup=""
if [ -n "$BACKUP_ARG" ]; then
    [ -f "$BACKUP_ARG" ] || { echo "Backup not found: $BACKUP_ARG" >&2; exit 1; }
    backup="$BACKUP_ARG"
else
    shopt -s nullglob
    found=(backups/*.tar.gz)
    shopt -u nullglob
    [ "${#found[@]}" -gt 0 ] && backup=$(ls -t "${found[@]}" | head -n1)
fi

if [ -n "$backup" ]; then
    info "Found backup: $backup"
    if confirm "Restore it now?"; then
        ./bin/restore.sh -y "$backup"
        echo
        say "Done"
        info "Server prepared and snapshot restored. Start the stack with:"
        info "  just up"
        exit 0
    fi
    info "Skipped restore."
fi

# No backup (or declined): report what a first-time bring-up still needs.
say "Done — remaining manual steps"
missing=0
if [ ! -e cloudflare.env ]; then
    missing=1
    info "cloudflare.env is missing. Create it with a Cloudflare API token"
    info "scoped Zone:DNS:Edit on your zone (used for DNS-01 ACME):"
    info "  echo 'CF_DNS_API_TOKEN=<token>' > cloudflare.env"
fi
if [ "$missing" -eq 0 ]; then
    info "cloudflare.env present."
fi
info ""
info "Then bootstrap the remaining secret + flag files and start:"
info "  just init      # basicauth, bot.env, credentials.env, flags_*"
info "  just up"
