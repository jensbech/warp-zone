#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/helpers.sh"

passthrough_pattern='^INCLUDE_|^NODE_MAJOR$|^EXTRA_APT_PACKAGES$|_VERSION$'

while IFS= read -r var; do
  unset "$var"
done < <(compgen -v | grep -E "$passthrough_pattern" || true)

set -a
. "$script_dir/profile.env"
set +a

require_docker

# Pass the core identity args plus every INCLUDE_* flag, version override, and
# EXTRA_APT_PACKAGES from profile.env, so new tool toggles only need to be added
# to the Dockerfile — not wired up here too.
# The jira CLI is built from source, so that stage needs Go — but only then.
jira_builder_image="${BASE_IMAGE:-ubuntu:24.04}"
if [ "${INCLUDE_JIRA:-false}" = "true" ]; then
  jira_builder_image='golang:1.24-bookworm'
fi

build_args=(
  --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:24.04}"
  --build-arg "JIRA_BUILDER_IMAGE=$jira_builder_image"
  --build-arg "APP_USER=$APP_USER"
  --build-arg "APP_UID=$APP_UID"
  --build-arg "PROFILE_PROMPT=$PROFILE_PROMPT"
)

while IFS= read -r var; do
  build_args+=(--build-arg "$var=${!var}")
done < <(compgen -v | grep -E "$passthrough_pattern" | sort)

# --pull refreshes the base image so a freshly built image starts from the
# latest published distro layer; the Dockerfile then applies OS updates on top.
docker build \
  --pull \
  --progress plain \
  -t "$IMAGE_NAME" \
  --label "$warp_label=$PROFILE_NAME" \
  "${build_args[@]}" \
  -f "$script_dir/Dockerfile" \
  "$script_dir"
