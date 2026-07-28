#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

profile="${1:-dev}"
load_profile "$profile"

if ! container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  printf 'Container not created yet. Run: just open %s\n' "$profile" >&2
  exit 1
fi
if ! container_running "$CONTAINER_NAME"; then
  container start "$CONTAINER_NAME" >/dev/null
fi

backups_dir="$(profile_dir "$profile")/backups"
mkdir -p "$backups_dir"
backup="$backups_dir/work-$(date +%Y%m%d-%H%M%S).tar.gz"
if ! container exec "$CONTAINER_NAME" tar -C "/home/$APP_USER" -czf - work > "$backup"; then
  rm -f "$backup"
  exit 1
fi
printf 'Backed up %s (%s)\n' "$backup" "$(du -h "$backup" | cut -f1)"
