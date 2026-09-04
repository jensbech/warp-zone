#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

profile="${1:-dev}"
load_profile "$profile"

require_docker
require_container "$profile" "$CONTAINER_NAME"
started="$(ensure_running "$CONTAINER_NAME")"

stop_if_started() {
  if [ "$started" = "started" ]; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

backups_dir="$(profile_dir "$profile")/backups"
mkdir -p "$backups_dir"
backup="$backups_dir/work-$(date +%Y%m%d-%H%M%S).tar.gz"
if ! docker exec "$CONTAINER_NAME" tar -C "/home/$APP_USER" -czf - work > "$backup"; then
  rm -f "$backup"
  stop_if_started
  exit 1
fi
stop_if_started
printf 'Backed up %s (%s)\n' "$backup" "$(du -h "$backup" | cut -f1)"

if [ "${BACKUP_KEEP:-0}" -gt 0 ] 2>/dev/null; then
  shopt -s nullglob
  all_backups=("$backups_dir"/work-*.tar.gz)
  excess=$(( ${#all_backups[@]} - BACKUP_KEEP ))
  if [ "$excess" -gt 0 ]; then
    for old in "${all_backups[@]:0:$excess}"; do
      rm -f "$old"
    done
    printf 'Pruned %d old backup(s), keeping the newest %s (BACKUP_KEEP).\n' "$excess" "$BACKUP_KEEP"
  fi
fi
