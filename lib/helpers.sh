#!/usr/bin/env bash
set -euo pipefail

profiles_root="${HOME}/container"

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

container_running() {
  container list -q 2>/dev/null | grep -Fxq "$1"
}

profile_names() {
  local dir
  shopt -s nullglob
  for dir in "$profiles_root"/*/; do
    [ -f "$dir/profile.env" ] || continue
    basename "${dir%/}"
  done
}
