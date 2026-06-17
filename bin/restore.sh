#!/usr/bin/env bash
# Inverse of bin/backup.sh: unpack a deployment snapshot onto this host.
#
# Restores the gitignored operator/flag files to their original paths and
# refills every named volume from the archive — recreating each volume
# under *this* host's compose project name, with the proper compose
# labels so `just up` adopts them instead of making empty ones.
#
# Volume data is extracted *through* a helper container, so a snapshot
# taken under Docker lands correctly under rootless Podman and back: the
# archived (in-container) uids are rewritten into the volume inside a
# container, and the user-namespace mapping is reapplied on next run.
#
# Usage:
#   ./bin/restore.sh                       # pick interactively from backups/
#   ./bin/restore.sh path/to/backup.tar.gz # restore a specific archive
#   ./bin/restore.sh -y [path]             # non-interactive (assume yes;
#                                          #   picks newest if no path)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

HELPER_IMAGE="docker.io/library/alpine:latest"

ASSUME_YES=0
ARCHIVE=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        *)        ARCHIVE="$arg" ;;
    esac
done

confirm() {  # confirm "question" -> 0 if yes
    [ "$ASSUME_YES" -eq 1 ] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ----------------------------------------------------------------------
# Locate the archive.
# ----------------------------------------------------------------------

if [ -z "$ARCHIVE" ]; then
    # nullglob so an empty backups/ doesn't expand to a literal glob.
    shopt -s nullglob
    candidates=(backups/*.tar.gz)
    shopt -u nullglob
    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "backups/ has no archives. Run 'just backup' first, or pass a path." >&2
        exit 1
    fi
    # Newest first.
    mapfile -t candidates < <(ls -t "${candidates[@]}")
    if [ "$ASSUME_YES" -eq 1 ]; then
        # No prompting possible — take the newest.
        ARCHIVE="${candidates[0]}"
    else
        echo "Which backup do you want to restore?"
        PS3="Number (newest first), or Ctrl-C to abort: "
        select choice in "${candidates[@]}"; do
            if [ -n "$choice" ]; then
                ARCHIVE="$choice"
                break
            fi
            echo "Invalid selection."
        done
    fi
fi
if [ ! -f "$ARCHIVE" ]; then
    echo "Archive not found: $ARCHIVE" >&2
    exit 1
fi
ARCHIVE=$(realpath "$ARCHIVE")

# ----------------------------------------------------------------------
# Unpack to staging + show the manifest.
# ----------------------------------------------------------------------

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
tar xzf "$ARCHIVE" -C "$STAGE"

if [ ! -f "$STAGE/MANIFEST.txt" ]; then
    echo "This does not look like an eHacking backup (no MANIFEST.txt)." >&2
    exit 1
fi

echo "==> Archive: $ARCHIVE"
echo "----------------------------------------------------------------------"
cat "$STAGE/MANIFEST.txt"
echo "----------------------------------------------------------------------"
confirm "Restore this snapshot onto the current host?" || { echo "Aborted."; exit 0; }

# ----------------------------------------------------------------------
# Runtime + project resolution. Files are restored first so that the
# subsequent `compose config` has every env file it needs to interpolate.
# ----------------------------------------------------------------------

runtime_env=$(./bin/runtime-env.sh) || exit 1
eval "$runtime_env"
export RUNTIME CONTAINER_SOCKET COMPOSE_FILE TRAEFIK_SOCK_MOUNT WATCHTOWER_SOCK_MOUNT

# ----------------------------------------------------------------------
# Safety net: if this host already holds deployment data, the restore is
# about to overwrite it. Offer a backup of the current state first.
# ----------------------------------------------------------------------

shopt -s nullglob
existing=(cloudflare.env credentials.env bot.env flags_*.env flag_*.txt \
          flag_*.xml traefik/dynamic/basicauth.yml)
present=()
for f in "${existing[@]}"; do [ -e "$f" ] && present+=("$f"); done
shopt -u nullglob
if [ "${#present[@]}" -gt 0 ]; then
    echo
    echo "!! This host already has deployment data — ${#present[@]} file(s),"
    echo "   e.g. ${present[0]}. The restore will overwrite it."
    if confirm "Take a safety backup of the current state first?"; then
        # Don't let a failed safety backup silently abort the restore.
        ./bin/backup.sh || confirm "Safety backup failed — restore anyway?" || { echo "Aborted."; exit 1; }
    fi
fi

# ----------------------------------------------------------------------
# 1. Operator files.
# ----------------------------------------------------------------------

echo
echo "==> Files"
if [ -d "$STAGE/files" ] && [ -n "$(ls -A "$STAGE/files" 2>/dev/null)" ]; then
    # Preserve perms/owner (umask-077 secret files, 0600 acme bits).
    # -a keeps the directory layout captured by `cp --parents`.
    (cd "$STAGE/files" && cp -a . "$ROOT/")
    (cd "$STAGE/files" && find . -type f | sed 's|^\./|    |')
else
    echo "    (no files in archive)"
fi

# ----------------------------------------------------------------------
# 2. Volumes.
# ----------------------------------------------------------------------

PROJECT=$(./bin/compose config 2>/dev/null | sed -n 's/^name: //p' | head -n1)
if [ -z "${PROJECT:-}" ]; then
    echo "Could not determine the compose project name after restoring files." >&2
    echo "Restore the volumes manually, or fix the env files and re-run." >&2
    exit 1
fi

# Refuse to clobber volumes that running containers still hold open.
running=$("$RUNTIME" ps --filter "label=com.docker.compose.project=$PROJECT" -q 2>/dev/null || true)
if [ -n "$running" ]; then
    echo
    echo "!! The stack appears to be running (project '$PROJECT')."
    echo "   Restoring into live volumes can corrupt them."
    if confirm "Bring it down now (./bin/compose down)?"; then
        ./bin/compose down
    else
        echo "Aborted — stop the stack and re-run." ; exit 1
    fi
fi

echo
echo "==> Volumes"
shopt -s nullglob
vol_archives=("$STAGE"/volumes/*.tar.gz)
shopt -u nullglob
if [ "${#vol_archives[@]}" -eq 0 ]; then
    echo "    (no volume data in archive)"
fi
for va in "${vol_archives[@]}"; do
    key=$(basename "$va" .tar.gz)
    vol="${PROJECT}_${key}"

    if "$RUNTIME" volume inspect "$vol" >/dev/null 2>&1; then
        if ! confirm "    Volume '$vol' exists — overwrite its contents?"; then
            echo "    $key — skipped"
            continue
        fi
    else
        # Create with the labels compose stamps on its own volumes so it
        # adopts this one silently on the next `up`.
        "$RUNTIME" volume create \
            --label com.docker.compose.project="$PROJECT" \
            --label com.docker.compose.volume="$key" \
            "$vol" >/dev/null
    fi

    # Wipe then extract, both inside the container so ownership stays in
    # the container namespace (Docker<->Podman portable).
    "$RUNTIME" run --rm \
        -e KEY="$key" \
        -v "$vol":/data \
        -v "$STAGE/volumes":/backup:ro,Z \
        "$HELPER_IMAGE" \
        sh -c 'rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf "/backup/$KEY.tar.gz" -C /data'
    echo "    $key — restored into $vol"
done

echo
echo "Restore complete. Bring the stack up with:  just up"
