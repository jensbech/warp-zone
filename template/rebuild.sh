#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$script_dir/profile.env"

container_name="$CONTAINER_NAME"

"$script_dir/build.sh"

if container inspect "$container_name" >/dev/null 2>&1; then
  if [ "${BACKUP_ON_REBUILD:-prompt}" = "always" ]; then
    "$script_dir/lib/backup.sh" "$PROFILE_NAME"
  elif [ "${BACKUP_ON_REBUILD:-prompt}" != "never" ]; then
    printf 'Rebuild replaces this container and deletes its writable state. Back up ~/work first? [y/N/a] '
    read -r answer
    case "$answer" in
      y|Y) "$script_dir/lib/backup.sh" "$PROFILE_NAME" ;;
      a|A)
        "$script_dir/lib/backup.sh" "$PROFILE_NAME"
        printf 'BACKUP_ON_REBUILD="always"\n' >> "$script_dir/profile.env"
        ;;
    esac
  fi
  if container list -q | grep -Fxq "$container_name"; then
    container stop "$container_name"
  fi

  container delete "$container_name"
fi

"$script_dir/open.sh"
