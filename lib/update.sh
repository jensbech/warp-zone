#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

apply_updates() {
  local name="$1" started rc=0
  started="$(require_running "$2" "$name")"
  docker exec "$name" sudo env DEBIAN_FRONTEND=noninteractive bash -c \
    'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge && apt-get clean' || rc=$?
  if [ "$rc" -eq 0 ]; then
    docker exec "$name" bash -lc 'command -v rustup >/dev/null 2>&1 && rustup update || true' || rc=$?
  fi
  if [ "$started" = "started" ]; then
    docker stop "$name" >/dev/null || true
  fi
  return "$rc"
}

update_one() {
  local profile="$1"
  load_profile "$profile"
  printf '\033[1;36mUpdating OS packages in %s...\033[0m\n' "$CONTAINER_NAME"
  apply_updates "$CONTAINER_NAME" "$profile"
  printf '\033[1;32m%s is up to date\033[0m\n' "$CONTAINER_NAME"
}

update_quiet() {
  local profile="$1"
  load_profile "$profile"
  if ! container_exists "$CONTAINER_NAME"; then
    echo "skipped: container not created (run: just open $profile)"
    return 0
  fi
  apply_updates "$CONTAINER_NAME" "$profile"
  echo "done"
}

if [ "${1:-}" != "--all" ]; then
  update_one "${1:-dev}"
  exit 0
fi

profiles=()
while IFS= read -r name; do
  profiles+=("$name")
done < <(profile_names)
if [ "${#profiles[@]}" -eq 0 ]; then
  printf '\033[2mNo profiles to update.\033[0m\n'
  exit 0
fi
printf '\033[1;36mUpdating %d profile(s) in parallel: %s\033[0m\n' "${#profiles[@]}" "${profiles[*]}"
printf '\033[2m(this can take a while; per-profile output appears below as they finish)\033[0m\n'
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
pids=()
for profile in "${profiles[@]}"; do
  (update_quiet "$profile") >"$tmpdir/$profile.log" 2>&1 &
  pids+=("$!")
done
rc=0
failed=()
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    rc=1
    failed+=("${profiles[$i]}")
  fi
done
for profile in "${profiles[@]}"; do
  printf '\n\033[1m=== %s ===\033[0m\n' "$profile"
  cat "$tmpdir/$profile.log" 2>/dev/null || true
done
if [ "$rc" -eq 0 ]; then
  printf '\n\033[1;32mAll profiles processed.\033[0m\n'
else
  printf '\n\033[33mFailed: %s - see output above.\033[0m\n' "${failed[*]}" >&2
fi
exit "$rc"
