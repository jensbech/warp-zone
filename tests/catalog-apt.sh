#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$(cd "$here/../template" && pwd)"
ids="$(jq -r '.tools[].id' "$template/catalog.json" | tr '\n' ' ')"

rc=0
for image in ubuntu:24.04 ubuntu:22.04 debian:12; do
  printf '\n== %s ==\n' "$image"
  docker run --rm --pull missing -e PLAN_ONLY=1 -e "TOOLS=$ids" -v "$template:/t:ro" "$image" bash -c '
    set -euo pipefail
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg jq unzip xz-utils >/dev/null
    CATALOG=/t/catalog.json bash /t/install-tools.sh
  ' || rc=1
done
exit "$rc"
