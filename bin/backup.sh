#!/usr/bin/env bash
# Snapshot everything that makes *this* e-hacking.de deployment unique
# into a single portable tarball, so the whole instance can be moved to
# another server without losing state.
#
# Two kinds of state, neither of which lives in git:
#
#   1. Operator secret / flag files (gitignored): cloudflare.env, bot.env,
#      credentials.env, the flags_*.env / flag_* CTF files, the Traefik
#      basicauth middleware, an optional modules.env profile override.
#   2. Named-volume data: the stateful volumes whose contents would be
#      lost on a fresh `compose up` — catcher + recruiting registries,
#      the passkeys store, and the Let's Encrypt certs (kept so the new
#      host doesn't re-issue and hit ACME rate limits).
#
# Volume contents are always streamed *through* a throwaway container
# (tar inside `$RUNTIME run`), never read off the host. That keeps the
# archive runtime-agnostic: a backup taken on Docker restores cleanly on
# rootless Podman and vice-versa, because the in-archive uids are the
# in-container uids — the user-namespace mapping is reapplied on restore.
#
# Output: backups/ehacking-backup-<UTC-timestamp>.tar.gz
#
# Usage:
#   ./bin/backup.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# ----------------------------------------------------------------------
# What to back up. Edit these two lists when the deployment changes.
# ----------------------------------------------------------------------

# Stateful named volumes (compose volume keys, NOT the prefixed names).
# crawling-maze-sessions is intentionally omitted: those are ephemeral
# per-visitor crawl sessions, regenerated on demand — not worth carrying.
VOLUME_KEYS=(
    catcher-data            # catcher registry.db: salts + captured requests
    recruiting-data         # recruiting registry.db: registrations + progress
    letsencrypt             # ACME certs (acme.json) — avoid LE rate limits
    passkeys-instance-data  # user-created passkey challenge instances
    passkeys-mongo-data     # mongo store backing the passkeys app
)

# Gitignored operator files. Plain names plus globs; non-existent and
# unmatched entries are skipped silently. Paths are relative to the
# deployment root and restored to the exact same place.
FILE_PATHS=(
    cloudflare.env
    bot.env
    credentials.env
    auth.env                       # legacy, only if still around
    modules.env                    # optional COMPOSE_PROFILES override
    .envrc                         # optional operator direnv file
    traefik/dynamic/basicauth.yml
)
FILE_GLOBS=(
    'flags_*.env'
    'flag_*.txt'
    'flag_*.xml'
)

HELPER_IMAGE="docker.io/library/alpine:latest"

# ----------------------------------------------------------------------
# Runtime + compose project resolution.
# ----------------------------------------------------------------------

runtime_env=$(./bin/runtime-env.sh) || exit 1
eval "$runtime_env"
export RUNTIME CONTAINER_SOCKET COMPOSE_FILE TRAEFIK_SOCK_MOUNT WATCHTOWER_SOCK_MOUNT

# Compose names every volume "<project>_<key>". Read the project name
# straight from the normalized config so we honour COMPOSE_PROJECT_NAME /
# directory-name normalization exactly as the running stack does.
PROJECT=$(./bin/compose config 2>/dev/null | sed -n 's/^name: //p' | head -n1)
if [ -z "${PROJECT:-}" ]; then
    echo "Could not determine the compose project name." >&2
    echo "Is the stack configured? Try './bin/compose config'." >&2
    exit 1
fi

# ----------------------------------------------------------------------
# Staging area + output path.
# ----------------------------------------------------------------------

mkdir -p backups
OUT=$(realpath -m "backups/ehacking-backup-$(date -u +%Y%m%d-%H%M%S).tar.gz")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/files" "$STAGE/volumes"

MANIFEST="$STAGE/MANIFEST.txt"
{
    echo "eHacking deployment backup"
    echo "created   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host      : $(hostname)"
    echo "runtime   : $RUNTIME"
    echo "project   : $PROJECT"
    echo "git       : $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
    echo
} > "$MANIFEST"

# ----------------------------------------------------------------------
# 1. Operator files.
# ----------------------------------------------------------------------

echo "==> Files"
shopt -s nullglob
declare -a MATCHED_FILES=()
for f in "${FILE_PATHS[@]}"; do
    [ -e "$f" ] && MATCHED_FILES+=("$f")
done
for g in "${FILE_GLOBS[@]}"; do
    for f in $g; do
        [ -e "$f" ] && MATCHED_FILES+=("$f")
    done
done
shopt -u nullglob

echo "## files" >> "$MANIFEST"
if [ "${#MATCHED_FILES[@]}" -eq 0 ]; then
    echo "    (none found — nothing to back up?)"
    echo "  (none)" >> "$MANIFEST"
else
    for f in "${MATCHED_FILES[@]}"; do
        # --parents keeps traefik/dynamic/basicauth.yml's directory layout.
        cp -a --parents "$f" "$STAGE/files/"
        echo "    $f"
        echo "  $f" >> "$MANIFEST"
    done
fi
echo >> "$MANIFEST"

# ----------------------------------------------------------------------
# 2. Volume data — streamed through a helper container.
# ----------------------------------------------------------------------

echo "==> Volumes"
echo "## volumes" >> "$MANIFEST"
for key in "${VOLUME_KEYS[@]}"; do
    vol="${PROJECT}_${key}"
    if ! "$RUNTIME" volume inspect "$vol" >/dev/null 2>&1; then
        echo "    $key — skipped (volume '$vol' does not exist)"
        echo "  $key: SKIPPED (absent)" >> "$MANIFEST"
        continue
    fi
    # Read the volume read-only, write the archive into the staging dir
    # (mounted :Z so rootless-podman SELinux relabels it; harmless on
    # Docker / non-SELinux hosts).
    "$RUNTIME" run --rm \
        -v "$vol":/data:ro \
        -v "$STAGE/volumes":/backup:Z \
        "$HELPER_IMAGE" \
        tar czf "/backup/${key}.tar.gz" -C /data .
    size=$(du -h "$STAGE/volumes/${key}.tar.gz" | cut -f1)
    echo "    $key — $size"
    echo "  $key: $vol ($size)" >> "$MANIFEST"
done
echo >> "$MANIFEST"

# ----------------------------------------------------------------------
# 3. Seal the archive.
# ----------------------------------------------------------------------

tar czf "$OUT" -C "$STAGE" .
echo
echo "Backup written: $OUT"
echo "  $(du -h "$OUT" | cut -f1) total"
echo
echo "Restore on the target host with:  just restore"
