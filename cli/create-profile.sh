#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  printf 'warp-zone needs Node.js 18 or newer, but node was not found.\n' >&2
  printf 'Run ./setup.sh for install hints for your OS.\n' >&2
  exit 1
fi

node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$node_major" -lt 18 ] 2>/dev/null; then
  printf 'warp-zone needs Node.js 18 or newer, but found %s.\n' "$(node -v)" >&2
  printf 'Run ./setup.sh for install hints for your OS.\n' >&2
  exit 1
fi

if [ ! -d "$repo_root/node_modules/@inquirer" ]; then
  printf 'Installing CLI dependencies...\n' >&2
  if ! command -v npm >/dev/null 2>&1; then
    printf 'npm was not found. Install it with Node.js (see ./setup.sh).\n' >&2
    exit 1
  fi
  npm ci --silent --prefix "$repo_root" >&2
fi

mkdir -p "$HOME/warp"

exec node "$script_dir/create-profile.mjs" "$@"
