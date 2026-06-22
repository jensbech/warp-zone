#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$script_dir/node_modules" ]; then
  printf 'Installing CLI dependencies...\n' >&2
  npm install --prefix "$script_dir" >&2
fi

mkdir -p "$HOME/container"

node "$script_dir/create-profile.mjs" "$@"
