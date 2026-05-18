#!/usr/bin/env bash
# Adds a user to traefik/dynamic/basicauth.yml — Traefik's dynamic-config
# file for the shared `basicauth` middleware (recruiting-instructor +
# optional dashboard router).
#
# Stupid-simple file management:
#   - First call (file missing) → writes the YAML scaffold + first user.
#   - Subsequent calls → appends another `- "user:hash"` line.
#
# Traefik watches the file (--providers.file.watch=true), so a fresh
# user is picked up on the next request — no compose restart needed.
#
# Usage:
#   ./make-auth.sh                  # interactive (prompts user + password)
#   ./make-auth.sh alice            # prompts for password
#   ./bin/make-auth.sh alice 's3cret'   # non-interactive (shell history!)
set -euo pipefail

# Always operate from the deployment root so paths like
# traefik/dynamic/basicauth.yml resolve correctly regardless of cwd.
cd "$(dirname "$0")/.."

USER="${1:-}"
PASS="${2:-}"

if ! command -v htpasswd >/dev/null 2>&1; then
  echo "htpasswd not found. Install apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL/Fedora)." >&2
  exit 1
fi

if [ -z "$USER" ]; then
  read -rp "Username: " USER
fi
if [ -z "$PASS" ]; then
  read -rsp "Password for '$USER': " PASS
  echo
fi

HASH=$(htpasswd -nbB "$USER" "$PASS")

OUT="traefik/dynamic/basicauth.yml"
mkdir -p "$(dirname "$OUT")"
umask 077

if [ ! -e "$OUT" ]; then
  # Traefik's file provider parses this directly — no Compose
  # interpolation pass, so `$` chars in the bcrypt hash need no escaping.
  cat > "$OUT" <<EOF
# Shared basicauth middleware. Referenced by Traefik routers via
#   traefik.http.routers.<name>.middlewares=basicauth
#
# Hot-reloaded by the file provider. Add more users with:
#   just add-basicauth-user <name>
http:
  middlewares:
    basicauth:
      basicAuth:
        users:
          - "$HASH"
EOF
  echo "$OUT created (first user: $USER, bcrypt cost 10)."
else
  # Append. Indentation matches the existing `users:` block — 10 spaces
  # under `        users:`. Dumb but works as long as the file isn't
  # restructured manually.
  printf '          - "%s"\n' "$HASH" >> "$OUT"
  echo "Appended $USER to $OUT (bcrypt cost 10)."
fi
