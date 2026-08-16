#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

if all_containers="$(container list --all --quiet 2>/dev/null)"; then
  have_all_list=true
else
  have_all_list=false
  all_containers=""
fi
running_containers="$(container list -q 2>/dev/null || true)"

container_exists() {
  if [ "$have_all_list" = "true" ]; then
    grep -Fxq "$1" <<<"$all_containers"
  else
    container inspect "$1" >/dev/null 2>&1
  fi
}

show_profile() {
  local profile="$1"
  load_profile "$profile"
  local state="not created"
  if container_exists "$CONTAINER_NAME"; then
    if grep -Fxq "$CONTAINER_NAME" <<<"$running_containers"; then state="running"; else state="stopped"; fi
  fi
  local tools=0 key
  while IFS= read -r key; do
    [ "$key" = "INCLUDE_SSH" ] && continue
    [ "${!key:-false}" = "true" ] && tools=$((tools + 1))
  done < <(compgen -v | grep '^INCLUDE_' || true)
  printf '%-18s %-12s %-14s %-10s %-8s %s\n' "$PROFILE_NAME" "$state" "$BASE_IMAGE" "${CPUS}/${MEMORY}" "$tools tools" "${SSH_HOSTNAME:-no SSH}"
}

if [ "${1:-}" = "--detail" ]; then
  profile="${2:?profile is required}"
  load_profile "$profile"
  (show_profile "$profile")
  printf '\nDirectory: %s\nContainer: %s\nImage: %s\nUser: %s\n' "$(profile_dir "$profile")" "$CONTAINER_NAME" "$IMAGE_NAME" "$APP_USER"
  printf 'SSH: %s\nDotfiles: %s\n' "${SSH_HOSTNAME:-disabled}" "${DOTFILES_DIR:-hermetic}"
  backups="$(profile_dir "$profile")/backups"
  if [ -d "$backups" ]; then
    printf 'Backups: %s\n' "$(du -sh "$backups" | cut -f1)"
  else
    printf 'Backups: none\n'
  fi
  exit 0
fi

printf '%-18s %-12s %-14s %-10s %-8s %s\n' 'PROFILE' 'STATE' 'DISTRO' 'CPU/RAM' 'TOOLS' 'SSH'
for profile in $(profile_names); do
  set +e
  (show_profile "$profile")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '%-18s %s\n' "$profile" 'error reading profile.env'
  fi
done
