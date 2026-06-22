#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$script_dir/profile.env"

container_name="$CONTAINER_NAME"

"$script_dir/build.sh"

if container inspect "$container_name" >/dev/null 2>&1; then
  if container list -q | grep -Fxq "$container_name"; then
    container stop "$container_name"
  fi

  container delete "$container_name"
fi

"$script_dir/open.sh"
