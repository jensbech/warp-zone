#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
name="${1:-zz-wizard-test}"
dir="$HOME/warp/$name"

command -v expect >/dev/null 2>&1 || { printf 'expect is required for this test\n' >&2; exit 1; }
[ ! -e "$dir" ] || { printf 'profile %s already exists\n' "$name" >&2; exit 1; }
trap 'rm -rf "$dir"' EXIT

cd "$repo"
NAME="$name" expect <<'EXP' > /dev/null
set timeout 30
set name $env(NAME)
spawn node cli/create-profile.mjs --dir $name
expect "Profile name"
send "\r"
expect "Start from"
send "\r"
expect "Optional tools"
sleep 0.5
send "lzgit"
sleep 0.4
send " "
sleep 0.3
send "\025"
sleep 0.5
send "pstgr"
sleep 0.4
send " "
sleep 0.3
send "\025"
sleep 0.5
send "libvips-dev"
sleep 0.4
send "\r"
sleep 0.4
send "k8"
sleep 0.4
send "\033\[B"
sleep 0.2
send "\033\[B"
sleep 0.2
send " "
sleep 0.3
send "\r"
expect "Serve T3 Code"
send "y\r"
expect "Who can reach T3 Code"
send "\r"
expect "Customize advanced"
send "n\r"
expect "Create profile"
send "y\r"
expect "Save this setup"
send "n\r"
expect eof
EXP

env_file="$dir/profile.env"
want_tools="TOOLS='k9s lazygit postgres-client t3code'"
want_apt="EXTRA_APT_PACKAGES='libvips-dev'"
grep -qxF "$want_tools" "$env_file" || { printf 'expected %s, got:\n' "$want_tools" >&2; grep -E '^(TOOLS|EXTRA)' "$env_file" >&2; exit 1; }
grep -qxF "$want_apt" "$env_file" || { printf 'expected %s\n' "$want_apt" >&2; exit 1; }
grep -qxF "T3CODE_SERVE='true'" "$env_file" || { printf 'expected T3CODE_SERVE=true\n' >&2; exit 1; }
grep -qE "^T3CODE_PORT='[0-9]+'$" "$env_file" || { printf 'expected a T3CODE_PORT\n' >&2; exit 1; }
grep -qE "^T3CODE_ACCESS='(local|tailscale)'$" "$env_file" || { printf 'expected T3CODE_ACCESS local or tailscale\n' >&2; exit 1; }
if grep -q '^INCLUDE_[A-Z_]*=' "$env_file" && [ "$(grep -c '^INCLUDE_' "$env_file")" -gt 1 ]; then
  printf 'wizard should not write legacy INCLUDE_* tool flags\n' >&2
  exit 1
fi
printf 'wizard ok: %s and %s\n' "$want_tools" "$want_apt"
