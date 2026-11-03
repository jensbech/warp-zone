#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/helpers.sh"

passthrough_pattern='^INCLUDE_|^TOOLS$|^NODE_MAJOR$|^EXTRA_APT_PACKAGES$|_VERSION$'

while IFS= read -r var; do
  unset "$var"
done < <(compgen -v | grep -E "$passthrough_pattern" || true)

set -a
. "$script_dir/profile.env"
set +a

require_docker

# Tool selection reaches the image as three build args, so the Dockerfile never
# needs editing for a new tool: TOOLS (catalog ids), LEGACY_INCLUDES (the older
# INCLUDE_<TOOL>='true' flags, which install-tools.sh maps onto catalog ids) and
# TOOL_VERSIONS (NODE_MAJOR and every *_VERSION pin). Both lists are sorted so
# reordering profile.env never busts the layer cache. The jira CLI is built from
# source in its own stage, which needs Go — but only when it is selected.
tools="$(printf '%s\n' ${TOOLS:-} | sort -u | tr '\n' ' ')"
legacy_includes=""
tool_versions=""
docker_version_args=()
profile_keys="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$script_dir/profile.env" | sort -u)"
for var in $profile_keys; do
  case "$var" in
    INCLUDE_*)
      if [ "${!var}" = "true" ]; then legacy_includes="$legacy_includes $var"; fi
      ;;
    DOCKER_VERSION | DOCKER_BUILDX_VERSION | DOCKER_COMPOSE_VERSION)
      docker_version_args+=(--build-arg "$var=${!var}")
      ;;
    NODE_MAJOR | *_VERSION)
      tool_versions="$tool_versions $var=${!var}"
      ;;
  esac
done
legacy_includes="${legacy_includes# }"
tool_versions="${tool_versions# }"

jira_selected=false
case " $tools $(printf '%s' "$legacy_includes" | tr 'A-Z_' 'a-z-' | sed 's/include-//g') " in
  *" jira "*) jira_selected=true ;;
esac

jira_builder_image="${BASE_IMAGE:-ubuntu:24.04}"
if [ "$jira_selected" = "true" ]; then
  jira_builder_image='golang:1.24-bookworm'
fi

build_args=(
  --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:24.04}"
  --build-arg "JIRA_BUILDER_IMAGE=$jira_builder_image"
  --build-arg "INCLUDE_JIRA=$jira_selected"
  --build-arg "APP_USER=$APP_USER"
  --build-arg "APP_UID=$APP_UID"
  --build-arg "PROFILE_PROMPT=$PROFILE_PROMPT"
  --build-arg "TOOLS=${tools% }"
  --build-arg "LEGACY_INCLUDES=$legacy_includes"
  --build-arg "TOOL_VERSIONS=$tool_versions"
  --build-arg "EXTRA_APT_PACKAGES=${EXTRA_APT_PACKAGES:-}"
  ${docker_version_args[@]+"${docker_version_args[@]}"}
)

# --pull refreshes the base image so a freshly built image starts from the
# latest published distro layer; the Dockerfile then applies OS updates on top.
progress_args=()
if [ "${DOCKER_BUILDKIT:-}" != "0" ] && docker buildx version >/dev/null 2>&1; then
  progress_args=(--progress plain)
fi

docker build \
  --pull \
  ${progress_args[@]+"${progress_args[@]}"} \
  -t "$IMAGE_NAME" \
  --label "$warp_label=$PROFILE_NAME" \
  "${build_args[@]}" \
  -f "$script_dir/Dockerfile" \
  "$script_dir"
