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
names=()
for b in "${backups[@]}"; do
  names+=("$(basename "$b")")
done
printf 'Available backups:\n'
select name in "${names[@]}" "Cancel"; do
  [ -n "${name:-}" ] || continue
  [ "$name" = "Cancel" ] && exit 0
  backup="${backups[$((REPLY - 1))]}"
  break
done

if ! container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  "$(profile_dir "$profile")/open.sh" --no-shell
fi
started=false
if ! container_running "$CONTAINER_NAME"; then
  container start "$CONTAINER_NAME" >/dev/null
  started=true
fi
printf 'Restore replaces /home/%s/work. Continue? [y/N] ' "$APP_USER"
read -r answer
if [ "$answer" != y ] && [ "$answer" != Y ]; then
  if [ "$started" = "true" ]; then
    container stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  exit 0
fi
container exec "$CONTAINER_NAME" rm -rf "/home/$APP_USER/work"
container exec -i "$CONTAINER_NAME" tar -C "/home/$APP_USER" -xzf - < "$backup"
container exec "$CONTAINER_NAME" chown -R "$APP_USER:$APP_USER" "/home/$APP_USER/work"
if [ "$started" = "true" ]; then
  container stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi
printf 'Restored %s\n' "$backup"
