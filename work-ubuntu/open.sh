#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$script_dir/profile.env"

container_name="$CONTAINER_NAME"
image_name="$IMAGE_NAME"
dotfiles_dir="$DOTFILES_DIR"
cpus="$CPUS"
memory="$MEMORY"

# "max" (the default) means give the container all host CPU cores and RAM.
if [ -z "$cpus" ] || [ "$cpus" = "max" ]; then
  cpus="$(sysctl -n hw.ncpu)"
fi
if [ -z "$memory" ] || [ "$memory" = "max" ]; then
  memory="$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))G"
fi

if [ ! -d "$dotfiles_dir" ]; then
  printf 'Missing dotfiles directory: %s\n' "$dotfiles_dir" >&2
  exit 1
fi

if ! container list >/dev/null 2>&1; then
  container system start
fi

if ! container image inspect "$image_name" >/dev/null 2>&1; then
  "$script_dir/build.sh"
fi

if ! container inspect "$container_name" >/dev/null 2>&1; then
  container create \
    --name "$container_name" \
    --cpus "$cpus" \
    --memory "$memory" \
    --mount "type=bind,source=$dotfiles_dir,target=/mnt/dotfiles,readonly" \
    "$image_name" \
    sleep infinity
fi

if ! container list -q | grep -Fxq "$container_name"; then
  container start "$container_name"
fi

container exec "$container_name" /usr/local/bin/bootstrap-work-ubuntu-home
container exec -it "$container_name" bash -ic "su - $APP_USER"
