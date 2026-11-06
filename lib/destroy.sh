#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

profile="${1:-dev}"
profile_dir="$(profile_dir "$profile")"
if [ ! -d "$profile_dir" ]; then
  printf '\033[31mNo such profile: %s\033[0m\n' "$profile" >&2
  exit 1
fi

CONTAINER_NAME="warp-$profile"
IMAGE_NAME=""
WORK_VOLUME="warp-$profile-work"
DOCKER_VOLUME="warp-$profile-docker"
SSH_HOSTNAME="$profile"
if [ -f "$profile_dir/profile.env" ]; then
  load_profile "$profile"
fi
CONTAINER_NAME="${CONTAINER_NAME:-warp-$profile}"
WORK_VOLUME="${WORK_VOLUME:-warp-$profile-work}"
DOCKER_VOLUME="${DOCKER_VOLUME:-warp-$profile-docker}"
SSH_HOSTNAME="${SSH_HOSTNAME:-$profile}"

printf '\033[1;31mAbout to permanently delete profile "%s":\033[0m\n' "$profile"
printf '  container : %s\n' "$CONTAINER_NAME"
printf '  image     : %s\n' "${IMAGE_NAME:-<none>}"
printf '  volumes   : %s \033[1;31m(your ~/work)\033[0m, %s\n' "$WORK_VOLUME" "$DOCKER_VOLUME"
printf '  directory : %s\n' "$profile_dir"
printf '\033[2m%s\033[0m\n' "Everything in ~/work is deleted with the volume. Back it up first with: just backup $profile"
printf 'Type the profile name (%s) to confirm: ' "$profile"
read -r reply
if [ "$reply" != "$profile" ]; then
  printf '\033[33mName did not match - aborted. Nothing was deleted.\033[0m\n' >&2
  exit 1
fi

if docker exec "$CONTAINER_NAME" tailnet status 2>/dev/null | grep -qv '^off'; then
  docker exec "$CONTAINER_NAME" timeout 20 tailnet logout >/dev/null 2>&1 \
    && printf 'Logged the profile out of your tailnet.\n' \
    || printf '\033[33mNote: could not log the node out of Tailscale - remove "%s" in the admin console.\033[0m\n' "$profile"
fi
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume rm "$WORK_VOLUME" "$DOCKER_VOLUME" >/dev/null 2>&1 || true
if [ -n "$IMAGE_NAME" ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  docker image rm "$IMAGE_NAME" >/dev/null 2>&1 \
    || printf '\033[33mNote: could not delete image %s (it may be in use).\033[0m\n' "$IMAGE_NAME"
fi
if remove_ssh_block "$SSH_HOSTNAME"; then
  printf 'Removed SSH alias "%s" from ~/.ssh/config.\n' "$SSH_HOSTNAME"
fi
rm -rf "$profile_dir"
printf '\033[1;32mDeleted profile "%s" and all its traces.\033[0m\n' "$profile"
