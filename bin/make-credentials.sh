#!/usr/bin/env bash
# Writes credentials.env with passwords for the WildFly principals and
# the catcher access gates.
#
# Two groups, two policies:
#
#   * Student-facing CTF accounts (attacker / victim / admin) → intentional
#     weak defaults that match what the local-dev stack uses, so the same
#     login forms work on the deployed instance.
#   * Internal accounts + catcher gates (oemmes, WildFly mgmt, catcher
#     signup/superuser/instructor) → randomly generated 16-byte hex.
#
# Re-running without --force never overwrites an existing credentials.env.
# To rotate a single entry, delete its line and re-run.
set -euo pipefail

# Resolve to the deployment root so credentials.env always lands beside
# .env regardless of cwd.
cd "$(dirname "$0")/.."

FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
  FORCE=1
fi

if [ -e credentials.env ] && [ "$FORCE" -ne 1 ]; then
  echo "credentials.env already exists. Re-run with --force to overwrite." >&2
  exit 1
fi

gen() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  elif [ -r /dev/urandom ]; then
    head -c 16 /dev/urandom | od -An -vtx1 | tr -d ' \n'
  else
    echo "Need either 'openssl' or /dev/urandom to generate a secret." >&2
    exit 1
  fi
}

umask 077
cat > credentials.env <<EOF
# WildFly application users — read by add-runtime-users.sh in the
# oidc / saml containers on every startup.
#
# attacker / victim / admin: intentional weak CTF accounts students log
# in as. Keep these defaults unless your deployment hides the login form.
ATTACKER_PASSWORD=123456
VICTIM_PASSWORD=123456
ADMIN_PASSWORD=$(gen)

# oemmes: the bot's victim identity. Random — only the bot itself
# needs this password (it logs in headlessly via Playwright).
OEMMES_PASSWORD=$(gen)

# WildFly management. Random — should never be needed at runtime.
WILDFLY_MGMT_PASSWORD=$(gen)

# Catcher access gates. Random — protect /__catcher (signup) and
# /__instructor from random internet visitors. Look these up in this
# file when you need them.
CATCHER_SIGNUP_PASSWORD=$(gen)
CATCHER_SUPERUSER_PASSWORD=$(gen)
CATCHER_INSTRUCTOR_PASSWORD=$(gen)
EOF

echo "credentials.env written. Reload the stack to apply."
