#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

profile="${1:-dev}"
load_profile "$profile"
backups_dir="$(profile_dir "$profile")/backups"
shopt -s nullglob
backups=("$backups_dir"/work-*.tar.gz)
if [ "${#backups[@]}" -eq 0 ]; then
  printf 'No backups for profile %s.\n' "$profile" >&2
  exit 1
fi
printf 'Available backups:\n'
select backup in "${backups[@]}" "Cancel"; do
  [ -n "${backup:-}" ] || continue
  [ "$backup" = "Cancel" ] && exit 0
  break
done

if ! container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  "$(profile_dir "$profile")/open.sh" </dev/null >/dev/null
fi
if ! container_running "$CONTAINER_NAME"; then
  container start "$CONTAINER_NAME" >/dev/null
fi
printf 'Restore replaces /home/%s/work. Continue? [y/N] ' "$APP_USER"
read -r answer
[ "$answer" = y ] || [ "$answer" = Y ] || exit 0
container exec "$CONTAINER_NAME" rm -rf "/home/$APP_USER/work"
container exec -i "$CONTAINER_NAME" tar -C "/home/$APP_USER" -xzf - < "$backup"
container exec "$CONTAINER_NAME" chown -R "$APP_USER:$APP_USER" "/home/$APP_USER/work"
printf 'Restored %s\n' "$backup"
