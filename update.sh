#!/usr/bin/env bash
set -e
git pull
docker compose pull
docker compose \
  --env-file .env \
  --env-file cloudflare.env \
  --env-file auth.env \
  up -d
