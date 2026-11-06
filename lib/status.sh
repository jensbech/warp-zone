#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

# One docker call for the whole listing: "<name> <state>" per warp container.
# If it fails the daemon is unreachable (or docker is missing).
docker_reachable=false
container_states=""
if command -v docker >/dev/null 2>&1 \
  && container_states="$(docker ps --all --filter "label=$warp_label" --format '{{.Names}} {{.State}}' 2>/dev/null)"; then
  docker_reachable=true
fi

state_of() {
  if [ "$docker_reachable" != "true" ]; then
    printf 'unknown\n'
  else
    state_from_lines "$container_states" "$1" || printf 'not created\n'
  fi
}

show_profile() {
  local tools=0 key id seen=" "
  state="$(state_of "$CONTAINER_NAME")"
  for key in $(compgen -v INCLUDE_ || true); do
    [ "$key" = "INCLUDE_SSH" ] && continue
    [ "${!key:-false}" = "true" ] && seen="$seen$(printf '%s' "${key#INCLUDE_}" | tr 'A-Z_' 'a-z-') "
  done
  for id in ${TOOLS:-} ${EXTRA_APT_PACKAGES:-}; do
    case "$seen" in
      *" $id "*) ;;
      *) seen="$seen$id " ;;
    esac
  done
  for id in $seen; do
    tools=$((tools + 1))
  done
  local ssh_cell='no SSH'
  if [ "${INCLUDE_SSH:-false}" = "true" ]; then
    ssh_cell="${SSH_HOSTNAME:-$PROFILE_NAME}:${SSH_PORT}"
  fi
  printf '%-18s %-12s %-14s %-10s %-8s %s\n' "$PROFILE_NAME" "$state" "$BASE_IMAGE" "${CPUS}/${MEMORY}" "$tools tools" "$ssh_cell"
}

if [ "${1:-}" = "--detail" ]; then
  profile="${2:?profile is required}"
  load_profile "$profile"
  show_profile
  printf '\nDirectory: %s\nContainer: %s\nImage: %s\nUser: %s\n' "$(profile_dir "$profile")" "$CONTAINER_NAME" "$IMAGE_NAME" "$APP_USER"
  printf 'Volumes: %s (work), %s (docker)\n' "$WORK_VOLUME" "$DOCKER_VOLUME"
  if [ "${INCLUDE_SSH:-false}" = "true" ]; then
    printf 'SSH: ssh %s  (127.0.0.1:%s)\n' "${SSH_HOSTNAME:-$PROFILE_NAME}" "$SSH_PORT"
  else
    printf 'SSH: disabled (port %s reserved)\n' "$SSH_PORT"
  fi
  if [ "${T3CODE_SERVE:-false}" = "true" ]; then
    printf 'T3 Code: http://localhost:%s  (pair with: just t3 %s)\n' "${T3CODE_PORT:-?}" "$profile"
    if [ "${T3CODE_ACCESS:-local}" = "tailscale" ]; then
      tailnet_state="not-running"
      if [ "$docker_reachable" = "true" ] && [ "$state" = "running" ]; then
        tailnet_state="$(docker exec "$CONTAINER_NAME" tailnet status 2>/dev/null || printf 'off')"
      fi
      case "${tailnet_state%% *}" in
        running) printf 'Tailnet: %s  (pair another device with: just t3 %s qr)\n' "${tailnet_state#* }" "$profile" ;;
        *) printf 'Tailnet: %s  (inside the shell, run: tailnet)\n' "${tailnet_state%% *}" ;;
      esac
    fi
  else
    printf 'T3 Code: not served\n'
  fi
  printf 'Dotfiles: %s\n' "${DOTFILES_DIR:-hermetic}"
  if [ "$docker_reachable" = "true" ] && [ "$state" = "running" ]; then
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
  (load_profile "$profile"; show_profile)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '%-18s %s\n' "$profile" 'error reading profile.env'
  fi
done
