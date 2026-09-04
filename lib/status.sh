#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

# One docker call for the whole listing: "<name> <state>" per warp container.
docker_reachable=false
container_states=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_reachable=true
  container_states="$(docker ps --all --filter "label=$warp_label" --format '{{.Names}} {{.State}}' 2>/dev/null || true)"
fi

state_of() {
  local name="$1" line
  if [ "$docker_reachable" != "true" ]; then
    printf 'unknown\n'
    return
  fi
  line="$(grep -m1 "^$name " <<<"$container_states" || true)"
  if [ -z "$line" ]; then
    printf 'not created\n'
  else
    printf '%s\n' "${line#* }"
  fi
}

show_profile() {
  local profile="$1"
  load_profile "$profile"
  local state
  state="$(state_of "$CONTAINER_NAME")"
  local tools=0 key
  while IFS= read -r key; do
    [ "$key" = "INCLUDE_SSH" ] && continue
    [ "${!key:-false}" = "true" ] && tools=$((tools + 1))
  done < <(compgen -v | grep '^INCLUDE_' || true)
  local ssh_cell='no SSH'
  if [ "${INCLUDE_SSH:-false}" = "true" ]; then
    ssh_cell="${SSH_HOSTNAME:-$PROFILE_NAME}:${SSH_PORT}"
  fi
  printf '%-18s %-12s %-14s %-10s %-8s %s\n' "$PROFILE_NAME" "$state" "$BASE_IMAGE" "${CPUS}/${MEMORY}" "$tools tools" "$ssh_cell"
}

if [ "${1:-}" = "--detail" ]; then
  profile="${2:?profile is required}"
  load_profile "$profile"
  (show_profile "$profile")
  printf '\nDirectory: %s\nContainer: %s\nImage: %s\nUser: %s\n' "$(profile_dir "$profile")" "$CONTAINER_NAME" "$IMAGE_NAME" "$APP_USER"
  printf 'Volumes: %s (work), %s (docker)\n' "$WORK_VOLUME" "$DOCKER_VOLUME"
  if [ "${INCLUDE_SSH:-false}" = "true" ]; then
    printf 'SSH: ssh %s  (127.0.0.1:%s)\n' "${SSH_HOSTNAME:-$PROFILE_NAME}" "$SSH_PORT"
  else
    printf 'SSH: disabled (port %s reserved)\n' "$SSH_PORT"
  fi
  printf 'Dotfiles: %s\n' "${DOTFILES_DIR:-hermetic}"
  if [ "$docker_reachable" = "true" ] && container_running "$CONTAINER_NAME"; then
    inner="$(docker exec "$CONTAINER_NAME" docker info --format '{{.ServerVersion}} · {{.Images}} images · {{.ContainersRunning}} running' 2>/dev/null || true)"
    printf 'Inner Docker: %s\n' "${inner:-not ready}"
  fi
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
