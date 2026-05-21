#!/usr/bin/env bash
# Generates per-service flags_<svc>.env files from the FLAG_* ENV defaults
# baked into each module's published Docker image. The trailing `_dummy`
# marker in every default is replaced with a fresh 16-char random token,
# so re-runs (with --force) produce a new value set.
#
# Source of truth is the image itself — this script reads `docker run env`
# rather than parsing module Dockerfiles, so it works on a deployment
# server without an eHacking source checkout.
#
# crawling-maze and any other third-party module is NOT in scope here;
# flags_crawling-maze.env stays hand-managed.
#
# Usage:
#   ./bin/make-flags.sh           # top up: keep existing values, only add new keys
#   ./bin/make-flags.sh --force   # rotate every flag value (destroys old wins)
#
# The top-up mode matters when a new challenge ships a new FLAG_ env var on
# top of an already-deployed stack: re-running without --force adds just the
# new key (with a fresh `_RANDOM` token) and leaves every existing flag's
# value untouched, so student submissions against the old values stay valid.
set -euo pipefail

# Resolve to the deployment root so flags_*.env land beside docker-compose.yml.
cd "$(dirname "$0")/.."

FORCE=0
case "${1:-}" in
  -f|--force) FORCE=1 ;;
  '') ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

REGISTRY="${DOCKER_REGISTRY:-ghcr.io/ehacking-websec/ehacking}"

# Modules whose Dockerfiles carry FLAG_ ENV defaults.
SERVICES=(json-sec oidc rest-api-sec saml soap-sec xml-sec axis2-flag)

rnd() {
  # 16 alphanumeric chars. tr stops once head closes the pipe.
  ( set +o pipefail; tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16 )
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH." >&2
  exit 1
fi

for svc in "${SERVICES[@]}"; do
  out="flags_${svc}.env"

  image="${REGISTRY}/${svc}:latest"
  if ! docker pull -q "$image" >/dev/null 2>&1; then
    echo "warn: cannot pull $image — skipping $svc" >&2
    continue
  fi

  # `env` is a stock util in every base image; --entrypoint bypasses the
  # module's standalone.sh / Node entrypoint.
  flags=$(docker run --rm --entrypoint env "$image" 2>/dev/null | grep '^FLAG_' || true)
  if [ -z "$flags" ]; then
    echo "warn: no FLAG_ entries in $image — skipping $svc" >&2
    continue
  fi

  # Slurp the existing file (if any) into a key→value map so top-up
  # mode preserves real flag values while picking up any new keys the
  # image has gained.
  declare -A existing=()
  if [ -e "$out" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      [[ -z "$l" || "$l" =~ ^[[:space:]]*# ]] && continue
      [[ "$l" == *=* ]] || continue
      n="${l%%=*}"; v="${l#*=}"
      existing["$n"]="$v"
    done < "$out"
  fi

  umask 077
  {
    printf '# CTF Flags for %s — generated %s\n' "$svc" "$(date)"
    printf '# Top up with: ./make-flags.sh    (keeps existing values)\n'
    printf '# Rotate with: ./make-flags.sh --force\n\n'
  } > "$out"

  added=0; kept=0; rotated=0
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    if [ "$FORCE" -eq 1 ]; then
      # Replace `_dummy}` at the end of FLAG{...} with `_<random>}`.
      new=$(printf '%s' "$val" | sed "s/_dummy}$/_$(rnd)}/")
      rotated=$((rotated+1))
    elif [ -n "${existing[$key]:-}" ]; then
      # Top-up mode: known key → keep its current value verbatim.
      new="${existing[$key]}"
      kept=$((kept+1))
    else
      # Top-up mode: new key from the image → mint a fresh random value.
      new=$(printf '%s' "$val" | sed "s/_dummy}$/_$(rnd)}/")
      added=$((added+1))
    fi
    printf '%s=%s\n' "$key" "$new" >> "$out"
  done <<< "$flags"
  echo "wrote $out (added=$added kept=$kept rotated=$rotated)" >&2
  unset existing
done

# xml-sec also reads three flag values from BIND-MOUNTED files (not env)
# so the operator can rotate them without rebuilding the image.
gen_file() {
  local path="$1" content="$2"
  if [ -e "$path" ] && [ "$FORCE" -ne 1 ]; then
    echo "skip $path (exists; pass --force to rotate)" >&2
    return
  fi
  umask 077
  printf '%b' "$content" > "$path"
  echo "wrote $path" >&2
}

gen_file flag_xslt1.xml "<flag>FLAG{xslt_1_$(rnd)}</flag>"
gen_file flag_xxe1.txt  "FLAG{xxe_1_$(rnd)}"
# xxe2 line 1 carries `<` `"` `'` — XML metacharacters the XXE challenge
# must survive (naive reconstruction would corrupt them).
gen_file flag_xxe2.txt  "< \" '\nFLAG{xxe_2_$(rnd)}"

echo "Done." >&2
