#!/usr/bin/env bash
# Writes auth.env with a bcrypt-hashed BasicAuth credential for the
# shared `basicauth` Traefik middleware (used by recruiting-instructor
# and the optional Traefik dashboard).
#
# Usage:
#   ./make-auth.sh                   # prompts for both
#   ./make-auth.sh admin             # prompts for password
#   ./make-auth.sh admin 's3cret'    # non-interactive (shell history!)
set -euo pipefail

USER="${1:-admin}"
PASS="${2:-}"

if ! command -v htpasswd >/dev/null 2>&1; then
  echo "htpasswd not found. Install apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL/Fedora)." >&2
  exit 1
fi

if [ -z "$PASS" ]; then
  read -rsp "Password for '$USER': " PASS
  echo
fi

HASH=$(htpasswd -nbB "$USER" "$PASS")
# Double every $ so docker compose does not interpolate the bcrypt
# hash on its way into the Traefik label.
ESCAPED=${HASH//\$/\$\$}

umask 077
printf 'BASICAUTH_USERS=%s\n' "$ESCAPED" > auth.env

echo "auth.env written (user=$USER, bcrypt cost 10). Reload the stack to apply."
