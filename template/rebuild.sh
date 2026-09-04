#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/helpers.sh"

. "$script_dir/profile.env"

require_docker

if [ "${1:-}" != "--skip-build" ]; then
  "$script_dir/build.sh"
fi

# Rebuild only replaces the container. ~/work and the profile's Docker state live
# on named volumes, so nothing you care about is in the container's writable
# layer — no backup dance needed.
if container_exists "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

"$script_dir/open.sh"
