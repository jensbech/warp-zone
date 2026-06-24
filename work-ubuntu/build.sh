#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
. "$script_dir/profile.env"
set +a

# Pass the core identity args plus every INCLUDE_* flag from profile.env, so new
# tool toggles only need to be added to the Containerfile — not wired up here too.
build_args=(
  --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:24.04}"
  --build-arg "APP_USER=$APP_USER"
  --build-arg "APP_UID=$APP_UID"
  --build-arg "PROFILE_PROMPT=$PROFILE_PROMPT"
)

while IFS= read -r var; do
  build_args+=(--build-arg "$var=${!var}")
done < <(compgen -v | grep '^INCLUDE_' | sort)

# Always refresh the base image so a freshly built image starts from the latest
# published distro layer; the Containerfile then applies OS updates on top.
container image pull "${BASE_IMAGE:-ubuntu:24.04}" >/dev/null 2>&1 || true

container build \
  --progress plain \
  -t "$IMAGE_NAME" \
  "${build_args[@]}" \
  -f "$script_dir/Containerfile" \
  "$script_dir"
