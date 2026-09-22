#!/usr/bin/env bash
# Prepare a bare server to run the e-hacking.de stack with rootless
# Podman, then hand off to backup-restore or first-time init.
#
# Idempotent: every step probes current state and only changes the delta,
# so re-running is safe. Root-free by default — the handful of system-level
# steps (package install, subuid/subgid, linger) abort with the command to
# hand the host admin unless ALLOW_SUDO=1 is set. Interactive where a human
# has to decide (e.g. restore a backup or not).
#
# Run as the unprivileged user that will OWN the stack — not as root.
# Rootless Podman keeps every container in that user's namespace.
#
# Steps:
#   1. Packages: podman + rootless deps + a compose-go provider.
#   2. Rootless plumbing: subuid/subgid, the user podman.socket.
#   3. Host: low-port sysctl (only if publishing on 80/443), linger,
#      restart-on-boot.
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

# Root-free by default. Every privileged step aborts and names the one-time
# command to hand the host admin, instead of silently prompting for sudo —
# on a prepared host none of them is reached anyway. Set ALLOW_SUDO=1 to let
# this script do the host preparation itself (bare-server bootstrap).
# See README → "Deploying without root".
ALLOW_SUDO="${ALLOW_SUDO:-}"

need_sudo() {  # need_sudo "<one-time step for the host admin>"
    if [ -z "$ALLOW_SUDO" ]; then
        warn "This step needs root. Running root-free (ALLOW_SUDO is not set)."
        [ -n "${1:-}" ] && warn "Have the host admin run once:  ${1}"
        warn "Or re-run this script with ALLOW_SUDO=1 to do it here."
        exit 1
    fi
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; return; fi
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; return; fi
    echo "This step needs root and 'sudo' is not installed. Re-run as root or install sudo." >&2
    exit 1
}

# `just --list` renders this recipe as `init-podman ARCHIVE=''`, which reads
# like you pass it as ARCHIVE=<path>. just takes recipe parameters
# positionally, so that form arrives here as the literal string
# "ARCHIVE=<path>". No real archive is ever named that, so accept it and say
# what the plain form is.
case "$BACKUP_ARG" in
    ARCHIVE=*)
        BACKUP_ARG="${BACKUP_ARG#ARCHIVE=}"
        warn "Read that as a path. just takes recipe arguments positionally:"
        warn "  just init-podman ${BACKUP_ARG}"
        ;;
esac

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
    need_sudo "install podman + rootless deps (uidmap, slirp4netns/passt, fuse-overlayfs)"
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
    need_sudo "install a compose-go provider so 'podman compose' resolves"
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
# Disk space at podman's image store. Shared with `just up` / `just
# update` via bin/disk.sh; here it stays advisory, because a bare-server
# bootstrap may legitimately run before the volume is sized.
# ----------------------------------------------------------------------

say "Image store free space"
./bin/disk.sh check || confirm "Continue anyway?" || { info "Aborted."; exit 1; }

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
        need_sudo "usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${user}"
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
# 3. Host: unprivileged low ports, linger, restart-on-boot.
# ----------------------------------------------------------------------

say "Unprivileged low ports"
# Only the HOST-side publish ports need root. Traefik's 80/443 bind
# happens inside its own netns and is handled by compose.podman.yml.
# Publishing on HOST_PORT_* (>=1024) skips the sysctl entirely, which
# also avoids lowering the bind threshold host-wide.
# Check every file bin/compose feeds Compose; take the lowest, which errs
# towards asking for the sysctl rather than skipping a bind that needs it.
# `[ -f ] && sed` as the loop's last command makes the loop exit 1 when the
# file is absent; with pipefail + set -e that aborts the whole script.
lowest=$(for f in .env modules.env; do
    [ -f "$f" ] || continue
    sed -n 's/\r$//; s/^HOST_PORT_HTTPS\?=\([0-9]\+\)$/\1/p' "$f"
done | sort -n | head -n1 || true)
[ -n "$lowest" ] || lowest=80
if [ "$lowest" -ge 1024 ]; then
    info "Published ports start at ${lowest} (>= 1024) — no sysctl needed."
    info "Make sure the host firewall preroutes 80/443 to them."
else
    cur=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)
    if [ "$cur" -le "$lowest" ]; then
        info "ip_unprivileged_port_start=${cur} already allows binding ${lowest}."
    else
        info "Lowering ip_unprivileged_port_start to ${lowest} (currently ${cur})…"
        need_sudo "sysctl net.ipv4.ip_unprivileged_port_start=${lowest} — or keep HOST_PORT_* >= 1024 and drop this step"
        echo "net.ipv4.ip_unprivileged_port_start=${lowest}" | $SUDO tee /etc/sysctl.d/podman-lowports.conf >/dev/null
        $SUDO sysctl --quiet -w "net.ipv4.ip_unprivileged_port_start=${lowest}"
    fi
fi

say "Linger (keep the stack alive past logout)"
if [ "$(id -u)" -eq 0 ]; then
    info "(root) linger not applicable."
elif loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    info "Linger already enabled for $(id -un)."
else
    info "Enabling linger for $(id -un)…"
    need_sudo "loginctl enable-linger $(id -un)"
    $SUDO loginctl enable-linger "$(id -un)"
fi

# Linger alone only keeps the user manager alive; it does not start any
# container. podman-restart.service is what re-starts the `restart: always`
# containers after a reboot.
say "Restart-on-boot"
if systemctl --user is-enabled --quiet podman-restart.service 2>/dev/null; then
    info "podman-restart.service already enabled."
elif systemctl --user enable podman-restart.service 2>/dev/null; then
    info "Enabled podman-restart.service — the stack comes back after a reboot."
else
    warn "Could not enable podman-restart.service from here (no user D-Bus?)."
    warn "Run this once after logging in again, or the stack stays down"
    warn "after the next reboot:"
    warn "  systemctl --user enable podman-restart.service"
fi

# ----------------------------------------------------------------------
# 4. Hand-off: restore a backup, or list what's still missing.
# ----------------------------------------------------------------------

say "Deployment state"

# Find a backup: explicit arg wins, else newest in backups/.
backup=""
backup_named=0
if [ -n "$BACKUP_ARG" ]; then
    [ -f "$BACKUP_ARG" ] || { echo "Backup not found: $BACKUP_ARG" >&2; exit 1; }
    backup="$BACKUP_ARG"
    backup_named=1
else
    shopt -s nullglob
    found=(backups/*.tar.gz)
    shopt -u nullglob
    if [ "${#found[@]}" -gt 0 ]; then
        backup=$(ls -t "${found[@]}" | head -n1 || true)
    fi
fi

if [ -n "$backup" ]; then
    # Naming an archive on the command line IS the decision — only ask when
    # we picked one by ourselves.
    restore=1
    if [ "$backup_named" -eq 1 ]; then
        info "Restoring the archive you named: $backup"
    else
        info "Found backup: $backup"
        confirm "Restore it now?" || restore=0
    fi
    if [ "$restore" -eq 1 ]; then
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
