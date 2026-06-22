#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$script_dir/profile.env"

container build \
  --progress plain \
  -t "$IMAGE_NAME" \
  --build-arg APP_USER="$APP_USER" \
  --build-arg APP_UID="$APP_UID" \
  --build-arg PROFILE_PROMPT="$PROFILE_PROMPT" \
  --build-arg INCLUDE_NODE="$INCLUDE_NODE" \
  --build-arg INCLUDE_DOTNET="$INCLUDE_DOTNET" \
  --build-arg INCLUDE_AZURE_CLI="$INCLUDE_AZURE_CLI" \
  --build-arg INCLUDE_PULUMI="$INCLUDE_PULUMI" \
  --build-arg INCLUDE_KUBECTL="$INCLUDE_KUBECTL" \
  --build-arg INCLUDE_GH="$INCLUDE_GH" \
  --build-arg INCLUDE_JIRA="$INCLUDE_JIRA" \
  --build-arg INCLUDE_K9S="$INCLUDE_K9S" \
  --build-arg INCLUDE_PYTHON="$INCLUDE_PYTHON" \
  -f "$script_dir/Containerfile" \
  "$script_dir"
