#!/usr/bin/env bash
set -euo pipefail

profiles_root="${HOME}/warp"
warp_label='com.warp-zone.profile'

profile_dir() {
  printf '%s/%s\n' "$profiles_root" "$1"
}

load_profile() {
  local profile="$1"
  local env_file
  env_file="$(profile_dir "$profile")/profile.env"
  if [ ! -f "$env_file" ]; then
    printf 'No such profile: %s\n' "$profile" >&2
    exit 1
  fi
  set -a
  . "$env_file"
  set +a
}

profile_names() {
  local dir
  shopt -s nullglob
  for dir in "$profiles_root"/*/; do
    [ -f "$dir/profile.env" ] || continue
    basename "${dir%/}"
  done
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker is not installed or not on PATH — https://docs.docker.com/desktop/setup/install/mac-install/\n' >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    printf 'Cannot reach the Docker daemon. Start Docker Desktop (or your Docker runtime) and try again.\n' >&2
    exit 1
  fi
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

container_running() {
  [ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = 'true' ]
}

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

require_container() {
  local profile="$1" name="$2"
  if ! container_exists "$name"; then
    printf 'Container not created yet — run: just open %s\n' "$profile" >&2
    exit 1
  fi
}

# Start the container if it exists but is stopped. Prints "started" when it had
# to start it, so callers can put it back the way they found it.
ensure_running() {
  if ! container_running "$1"; then
    docker start "$1" >/dev/null
    printf 'started\n'
  fi
}

warp_containers() {
  docker ps --all --filter "label=$warp_label" --format '{{.Names}}'
}

warp_volumes() {
  docker volume ls --filter "label=$warp_label" --format '{{.Name}}'
}

warp_images() {
  docker image ls --filter "label=$warp_label" --format '{{.Repository}}:{{.Tag}}'
}

container_profile_label() {
  docker container inspect -f "{{index .Config.Labels \"$warp_label\"}}" "$1" 2>/dev/null || true
}

volume_profile_label() {
  docker volume inspect -f "{{index .Labels \"$warp_label\"}}" "$1" 2>/dev/null || true
}
