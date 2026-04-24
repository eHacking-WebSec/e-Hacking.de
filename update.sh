#!/usr/bin/env bash
set -e
# Make every `docker compose ...` invocation in this script see the
# split secret files. Requires Docker Compose v2.24+ (Jan 2024).
export COMPOSE_ENV_FILES=.env,cloudflare.env,auth.env,bot.env
git pull
docker compose pull
docker compose up -d
