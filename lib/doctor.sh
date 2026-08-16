#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
dim='\033[2m'
reset='\033[0m'

problems=0

ok() { printf "  ${green}ok${reset}    %s\n" "$1"; }
warn() { printf "  ${yellow}warn${reset}  %s\n" "$1"; problems=$((problems + 1)); }
fail() { printf "  ${red}fail${reset}  %s\n" "$1"; problems=$((problems + 1)); }

printf '%b\n' "${dim}Checking your warp-zone setup...${reset}"

printf '\nHost tools\n'
if command -v container >/dev/null 2>&1; then
  container_version="$(container --version 2>/dev/null | head -n1)"
  ok "container CLI installed (${container_version:-version unknown})"
else
  fail "Apple's container CLI is not installed or not on PATH — https://github.com/apple/container"
fi
if command -v just >/dev/null 2>&1; then
  ok "just installed ($(just --version 2>/dev/null))"
else
  fail 'just is not installed or not on PATH'
fi
if command -v node >/dev/null 2>&1; then
  ok "node installed ($(node --version 2>/dev/null))"
else
  warn 'node is not installed — `just new` needs it'
fi

printf '\nContainer system\n'
if command -v container >/dev/null 2>&1; then
  if container list >/dev/null 2>&1; then
    ok 'container system is running'
  else
    warn 'container system is not running — `just open` starts it, or run: container system start'
  fi
fi

printf '\nDisk\n'
available_kb="$(df -k "$HOME" 2>/dev/null | tail -n1 | awk '{print $4}')"
if [ -n "$available_kb" ]; then
  available_gb=$((available_kb / 1024 / 1024))
  if [ "$available_gb" -lt 50 ]; then
    warn "only ${available_gb} GB free on the profile disk; 50 GB or more is recommended"
  else
    ok "${available_gb} GB free on the profile disk"
  fi
fi

printf '\nProfiles\n'
profiles="$(profile_names)"
if [ -z "$profiles" ]; then
  printf "  ${dim}none — create one with: just new${reset}\n"
fi
all_containers=""
if command -v container >/dev/null 2>&1; then
  all_containers="$(container list --all --quiet 2>/dev/null || true)"
fi
for profile in $profiles; do
  set +e
  (
    load_profile "$profile"
    if ! command -v container >/dev/null 2>&1; then
      exit 0
    fi
    if ! container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      printf "  ${dim}%-18s not created yet — run: just open %s${reset}\n" "$profile" "$profile"
      exit 0
    fi
    if ! container image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
      printf "  ${yellow}warn${reset}  %-18s container exists but image %s is missing — run: just rebuild %s\n" "$profile" "$IMAGE_NAME" "$profile"
      exit 2
    fi
    if [ "${INCLUDE_SSH:-false}" = "true" ]; then
      alias_name="${SSH_HOSTNAME:-$PROFILE_NAME}"
      if ! grep -Fqx "# >>> warp-zone:${alias_name} >>>" "$HOME/.ssh/config" 2>/dev/null; then
        printf "  ${yellow}warn${reset}  %-18s SSH enabled but alias \"%s\" is not in ~/.ssh/config — run: just open %s\n" "$profile" "$alias_name" "$profile"
        exit 2
      fi
    fi
    printf "  ${green}ok${reset}    %-18s\n" "$profile"
  )
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    problems=$((problems + 1))
  elif [ "$rc" -ne 0 ]; then
    fail "$profile — could not read its profile.env"
  fi
done

if [ -n "$all_containers" ]; then
  orphans=""
  for name in $all_containers; do
    if [ ! -f "$profiles_root/$name/profile.env" ]; then
      orphans="$orphans $name"
    fi
  done
  if [ -n "$orphans" ]; then
    printf '\nOther containers\n'
    warn "containers with no matching profile:${orphans} — remove with: container delete <name>"
  fi
fi

printf '\n'
if [ "$problems" -eq 0 ]; then
  printf "${green}Everything looks good.${reset}\n"
else
  printf "${yellow}%d issue(s) found — see above.${reset}\n" "$problems"
  exit 1
fi
