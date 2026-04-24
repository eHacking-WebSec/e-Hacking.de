#!/usr/bin/env bash
# Writes bot.env with a freshly generated BOT_INTERNAL_SECRET used by
# the recruiting-bot and recruiting-challenge services to authenticate
# internal bot requests.
#
# Usage:
#   ./make-bot-env.sh           # generate and write bot.env
#   ./make-bot-env.sh --force   # overwrite existing bot.env
set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
  FORCE=1
fi

if [ -e bot.env ] && [ "$FORCE" -ne 1 ]; then
  echo "bot.env already exists. Re-run with --force to overwrite." >&2
  exit 1
fi

if command -v openssl >/dev/null 2>&1; then
  SECRET=$(openssl rand -hex 32)
elif [ -r /dev/urandom ]; then
  SECRET=$(head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n')
else
  echo "Need either 'openssl' or /dev/urandom to generate a secret." >&2
  exit 1
fi

umask 077
printf 'BOT_INTERNAL_SECRET=%s\n' "$SECRET" > bot.env

echo "bot.env written (BOT_INTERNAL_SECRET, 32 random bytes hex). Reload the stack to apply."
