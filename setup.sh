#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) os=other ;;
esac

red='\033[1;31m'; green='\033[1;32m'; cyan='\033[1;36m'; dim='\033[2m'; reset='\033[0m'
problems=0
ok() { printf '  %b✓%b %s\n' "$green" "$reset" "$1"; }
bad() { printf '  %b✗%b %s\n' "$red" "$reset" "$1"; problems=$((problems + 1)); }
hint() { printf '      %b%s%b\n' "$dim" "$1" "$reset"; }

linux_pkg_hint() {
  if command -v apt-get >/dev/null 2>&1; then
    hint "$1"
  elif command -v dnf >/dev/null 2>&1; then
    hint "$2"
  elif command -v pacman >/dev/null 2>&1; then
    hint "$3"
  else
    hint "$4"
  fi
}

printf '%bwarp-zone setup%b (%s)\n\n' "$cyan" "$reset" "$os"

if ! command -v docker >/dev/null 2>&1; then
  bad 'docker is not installed'
  if [ "$os" = macos ]; then
    hint 'brew install --cask docker   (or Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/)'
    hint 'then open Docker.app once so the daemon starts'
  else
    hint 'curl -fsSL https://get.docker.com | sh'
    hint 'sudo usermod -aG docker "$USER"   then log out and back in'
  fi
elif ! docker info >/dev/null 2>&1; then
  bad 'docker is installed but the daemon is not reachable'
  if [ "$os" = macos ]; then
    hint 'Start Docker Desktop (open -a Docker) and wait until it is running'
  else
    hint 'sudo systemctl enable --now docker'
    hint 'sudo usermod -aG docker "$USER"   then log out and back in (or run: newgrp docker)'
  fi
else
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo reachable)"
fi

if command -v just >/dev/null 2>&1; then
  ok "just $(just --version | awk '{print $2}')"
else
  bad 'just is not installed'
  if [ "$os" = macos ]; then
    hint 'brew install just'
  else
    linux_pkg_hint 'sudo apt-get install -y just   (Ubuntu 24.04+/Debian 13+; otherwise use the installer below)' \
      'sudo dnf install -y just' \
      'sudo pacman -S just' \
      'curl --proto =https --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin'
    hint 'or: curl --proto =https --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin'
  fi
fi

node_ok=false
if command -v node >/dev/null 2>&1; then
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$node_major" -ge 18 ]; then
    ok "node $(node -v)"
    node_ok=true
  else
    bad "node $(node -v) is too old (need 18 or newer)"
  fi
else
  bad 'node is not installed (need 18 or newer)'
fi
if [ "$node_ok" != true ]; then
  if [ "$os" = macos ]; then
    hint 'brew install node'
  else
    linux_pkg_hint 'sudo apt-get install -y nodejs npm   (newer: https://github.com/nodesource/distributions)' \
      'sudo dnf install -y nodejs npm' \
      'sudo pacman -S nodejs npm' \
      'https://nodejs.org/en/download'
  fi
elif ! command -v npm >/dev/null 2>&1; then
  bad 'npm is not installed'
  if [ "$os" = macos ]; then hint 'brew install node'; else hint 'sudo apt-get install -y npm   (or your distro equivalent)'; fi
fi

if [ "$problems" -gt 0 ]; then
  printf '\n%bFix the items above, then re-run: ./setup.sh%b\n' "$red" "$reset" >&2
  exit 1
fi

if [ ! -d "$script_dir/node_modules/@inquirer" ]; then
  printf '\nInstalling CLI dependencies...\n'
  npm ci --silent --prefix "$script_dir"
fi
ok 'CLI dependencies'

"$script_dir/cli/install-warp.sh"

printf '\n%bAll set.%b Next:\n' "$green" "$reset"
printf '  warp new        create a profile (open a new shell first if warp is not found)\n'
printf '  warp open       build it and drop into a shell\n'
