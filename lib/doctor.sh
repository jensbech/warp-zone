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

have_docker=false
docker_up=false

printf '\nHost tools\n'
if command -v docker >/dev/null 2>&1; then
  have_docker=true
  ok "docker CLI installed ($(docker --version 2>/dev/null))"
else
  fail 'docker is not installed or not on PATH — https://docs.docker.com/desktop/setup/install/mac-install/'
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

printf '\nDocker engine\n'
if [ "$have_docker" = "true" ]; then
  if docker info >/dev/null 2>&1; then
    docker_up=true
    engine_version="$(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
    engine_cpu="$(docker info --format '{{.NCPU}}' 2>/dev/null)"
    engine_mem="$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null) / 1024 / 1024 / 1024 ))"
    ok "daemon reachable (${engine_version} · ${engine_cpu} CPU · ${engine_mem}G RAM available to profiles)"
  else
    fail 'cannot reach the Docker daemon — start Docker Desktop (or your Docker runtime)'
  fi
fi

printf '\nNetwork\n'
route_mtu="$(route -n get default 2>/dev/null | awk '/mtu/ {getline; print $7}')"
if [ -n "$route_mtu" ] && [ "$route_mtu" -lt 1500 ] 2>/dev/null; then
  warn "the default route has MTU ${route_mtu} (a VPN, most likely)"
  printf "  ${dim}Docker Desktop assumes 1500, so large image pulls can die with \"unexpected EOF\".${reset}\n"
  printf "  ${dim}Fix the host: Docker Desktop -> Settings -> Resources -> Network -> MTU = ${route_mtu}.${reset}\n"
  printf "  ${dim}Fix a profile's own engine: DOCKERD_ARGS=\"--mtu ${route_mtu}\" in its profile.env, then: just rebuild <profile>${reset}\n"
else
  ok "default route MTU ${route_mtu:-1500}"
fi

printf '\nDisk\n'
available_kb="$(df -k "$HOME" 2>/dev/null | tail -n1 | awk '{print $4}')"
if [ -n "$available_kb" ]; then
  available_gb=$((available_kb / 1024 / 1024))
  if [ "$available_gb" -lt 50 ]; then
    warn "only ${available_gb} GB free on the host disk; 50 GB or more is recommended"
  else
    ok "${available_gb} GB free on the host disk"
  fi
fi
if [ "$docker_up" = "true" ]; then
  reclaimable="$(docker system df --format '{{.Type}}: {{.Size}} ({{.Reclaimable}} reclaimable)' 2>/dev/null || true)"
  if [ -n "$reclaimable" ]; then
    while IFS= read -r line; do
      printf "  ${dim}%s${reset}\n" "$line"
    done <<<"$reclaimable"
    printf "  ${dim}reclaim with: just prune${reset}\n"
  fi
fi

printf '\nProfiles\n'
profiles="$(profile_names)"
if [ -z "$profiles" ]; then
  printf "  ${dim}none — create one with: just new${reset}\n"
fi
for profile in $profiles; do
  set +e
  (
    load_profile "$profile"
    [ "$docker_up" = "true" ] || exit 0
    if ! container_exists "$CONTAINER_NAME"; then
      printf "  ${dim}%-18s not created yet — run: just open %s${reset}\n" "$profile" "$profile"
      exit 0
    fi
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
      printf "  ${yellow}warn${reset}  %-18s container exists but image %s is missing — run: just rebuild %s\n" "$profile" "$IMAGE_NAME" "$profile"
      exit 2
    fi
    if ! volume_exists "$WORK_VOLUME"; then
      printf "  ${yellow}warn${reset}  %-18s work volume %s is missing — run: just rebuild %s\n" "$profile" "$WORK_VOLUME" "$profile"
      exit 2
    fi
    if container_running "$CONTAINER_NAME" && ! docker exec "$CONTAINER_NAME" docker info >/dev/null 2>&1; then
      printf "  ${yellow}warn${reset}  %-18s inner Docker engine is not running — check: just run %s \"sudo cat /var/log/dockerd.log\"\n" "$profile" "$profile"
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

# Duplicate SSH ports would make one profile unreachable, and the failure looks
# like an SSH problem rather than a config one — so name it here.
if [ -n "$profiles" ]; then
  dupes="$(
    for profile in $profiles; do
      (load_profile "$profile"; printf '%s\n' "${SSH_PORT:-}") 2>/dev/null
    done | sort | uniq -d
  )"
  if [ -n "$dupes" ]; then
    printf '\nSSH ports\n'
    for port in $dupes; do
      warn "port $port is claimed by more than one profile — change SSH_PORT in one of them, then: just rebuild <profile>"
    done
  fi
fi

if [ "$docker_up" = "true" ]; then
  orphan_containers=""
  for name in $(warp_containers); do
    label="$(container_profile_label "$name")"
    [ -n "$label" ] && [ -f "$profiles_root/$label/profile.env" ] && continue
    orphan_containers="$orphan_containers $name"
  done
  orphan_volumes=""
  for name in $(warp_volumes); do
    label="$(volume_profile_label "$name")"
    [ -n "$label" ] && [ -f "$profiles_root/$label/profile.env" ] && continue
    orphan_volumes="$orphan_volumes $name"
  done
  if [ -n "$orphan_containers$orphan_volumes" ]; then
    printf '\nLeftovers\n'
    [ -n "$orphan_containers" ] && warn "containers with no profile:${orphan_containers}"
    [ -n "$orphan_volumes" ] && warn "volumes with no profile:${orphan_volumes}"
    printf "  ${dim}remove them with: just prune${reset}\n"
  fi
fi

printf '\n'
if [ "$problems" -eq 0 ]; then
  printf "${green}Everything looks good.${reset}\n"
else
  printf "${yellow}%d issue(s) found — see above.${reset}\n" "$problems"
  exit 1
fi
