#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
profile="${1:?usage: verify-tools.sh <profile>}"
catalog="$repo/template/catalog.json"
env_file="$HOME/warp/$profile/profile.env"
[ -f "$env_file" ] || { printf 'No such profile: %s\n' "$profile" >&2; exit 1; }

set -a
. "$env_file"
set +a

ids=" "
for id in ${TOOLS:-}; do ids="$ids$id "; done
for key in $(compgen -v INCLUDE_ || true); do
  [ "$key" = "INCLUDE_SSH" ] && continue
  [ "${!key}" = "true" ] || continue
  ids="$ids$(printf '%s' "${key#INCLUDE_}" | tr 'A-Z_' 'a-z-') "
done
for id in $ids; do
  for req in $(jq -r --arg id "$id" '.tools[] | select(.id == $id) | .requires // [] | .[]' "$catalog"); do
    case "$ids" in *" $req "*) ;; *) ids="$ids$req " ;; esac
  done
done

pass=0
failed=""
for id in $ids; do
  check="$(jq -r --arg id "$id" '.tools[] | select(.id == $id) | .check // empty' "$catalog")"
  [ -n "$check" ] || continue
  if out="$(docker exec "$CONTAINER_NAME" su - "$APP_USER" -c "$check" 2>&1)"; then
    pass=$((pass + 1))
    printf 'ok    %-20s %s\n' "$id" "$(printf '%s' "$out" | head -n1 | cut -c1-70)"
  else
    failed="$failed $id"
    printf 'FAIL  %-20s %s\n' "$id" "$(printf '%s' "$out" | head -n2 | tr '\n' ' ' | cut -c1-100)"
  fi
done
printf '\n%d passed, failed:%s\n' "$pass" "${failed:- none}"
[ -z "$failed" ]
