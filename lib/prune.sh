#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

cyan='\033[1;36m'
yellow='\033[1;33m'
dim='\033[2m'
reset='\033[0m'

require_docker

# Warp's own containers are never "garbage" just because they are stopped —
# stopping one is how you park a profile. The only real garbage is dangling build
# artifacts and warp resources whose profile directory is gone.
printf '%bReclaimable now:%b\n' "$cyan" "$reset"
docker system df --format '  {{.Type}}: {{.Reclaimable}}' 2>/dev/null || true
printf '\nRemove dangling images and unused build cache? %b[y/N] %b' "$dim" "$reset"
read -r answer
if [ "$answer" = y ] || [ "$answer" = Y ]; then
  docker image prune -f >/dev/null
  docker builder prune -f >/dev/null
  printf '%breclaimed%b\n' "$dim" "$reset"
else
  printf '%bskipped%b\n' "$dim" "$reset"
fi

orphan_containers=()
for name in $(warp_containers); do
  label="$(container_profile_label "$name")"
  if [ -n "$label" ] && [ -f "$profiles_root/$label/profile.env" ]; then continue; fi
  orphan_containers+=("$name")
done

orphan_volumes=()
for name in $(warp_volumes); do
  label="$(volume_profile_label "$name")"
  if [ -n "$label" ] && [ -f "$profiles_root/$label/profile.env" ]; then continue; fi
  orphan_volumes+=("$name")
done

orphan_images=()
for name in $(warp_images); do
  label="$(docker image inspect -f "{{index .Config.Labels \"$warp_label\"}}" "$name" 2>/dev/null || true)"
  if [ -n "$label" ] && [ -f "$profiles_root/$label/profile.env" ]; then continue; fi
  orphan_images+=("$name")
done

total=$(( ${#orphan_containers[@]} + ${#orphan_volumes[@]} + ${#orphan_images[@]} ))
if [ "$total" -eq 0 ]; then
  printf 'No leftover warp-zone resources.\n'
  exit 0
fi

printf '\n%bLeftovers from deleted profiles:%b\n' "$yellow" "$reset"
for name in ${orphan_containers[@]+"${orphan_containers[@]}"}; do printf '  container  %s\n' "$name"; done
for name in ${orphan_images[@]+"${orphan_images[@]}"}; do printf '  image      %s\n' "$name"; done
for name in ${orphan_volumes[@]+"${orphan_volumes[@]}"}; do printf '  volume     %s  %b\n' "$name" "${dim}(may hold work)${reset}"; done

printf '\nDelete these permanently? [y/N] '
read -r answer
if [ "$answer" != y ] && [ "$answer" != Y ]; then
  printf 'Nothing was deleted.\n'
  exit 0
fi

for name in ${orphan_containers[@]+"${orphan_containers[@]}"}; do
  docker rm -f "$name" >/dev/null && printf 'removed container %s\n' "$name"
done
for name in ${orphan_images[@]+"${orphan_images[@]}"}; do
  docker image rm "$name" >/dev/null 2>&1 && printf 'removed image %s\n' "$name" || true
done
for name in ${orphan_volumes[@]+"${orphan_volumes[@]}"}; do
  docker volume rm "$name" >/dev/null 2>&1 && printf 'removed volume %s\n' "$name" || true
done
