#!/usr/bin/env bash
# Pull the latest stack revision and restart. Equivalent to `just update`.
# Kept around for operators who don't have `just` installed.
set -e

# Operate from the deployment root regardless of where this is invoked from.
cd "$(dirname "$0")/.."

# Make every `docker compose ...` invocation in this script see the
# split secret files. Requires Docker Compose v2.24+ (Jan 2024).
# auth.env is gone — basicauth lives in traefik/dynamic/basicauth.yml,
# which Traefik's file provider picks up directly (no Compose interpolation).
export COMPOSE_ENV_FILES=.env,cloudflare.env,bot.env,credentials.env

git pull
docker compose pull
docker compose up -d
