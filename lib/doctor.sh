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
  if docker buildx version >/dev/null 2>&1; then
    ok 'docker buildx available'
  else
    warn 'docker buildx is missing — builds still work but use the legacy builder'
    if [ "$(host_os)" = "linux" ]; then
      printf "  ${dim}Install it for faster, cached builds: sudo apt-get install docker-buildx-plugin (or your distro's docker-buildx package).${reset}\n"
    else
      printf "  ${dim}Install it for faster, cached builds: update Docker Desktop, or brew install docker-buildx.${reset}\n"
    fi
  fi
else
  fail 'docker is not installed or not on PATH — https://docs.docker.com/get-started/get-docker/'
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
  if engine_info="$(docker info --format '{{.ServerVersion}}|{{.NCPU}}|{{.MemTotal}}|{{.CgroupVersion}}' 2>/dev/null)"; then
    docker_up=true
    IFS='|' read -r engine_version engine_cpu engine_mem_bytes engine_cgroup <<<"$engine_info"
    ok "daemon reachable (${engine_version} · ${engine_cpu} CPU · $((engine_mem_bytes / 1024 / 1024 / 1024))G RAM available to profiles)"
    if [ "$(host_os)" = "linux" ]; then
      [ -n "$engine_cgroup" ] || { [ -f /sys/fs/cgroup/cgroup.controllers ] && engine_cgroup=2 || engine_cgroup=1; }
      if [ "$engine_cgroup" = "2" ]; then
        ok 'cgroup v2 is active'
      else
        warn "cgroup v${engine_cgroup} is active — the inner Docker engine in a profile works best with cgroup v2"
        printf "  ${dim}Boot with systemd.unified_cgroup_hierarchy=1 on the kernel command line, or use a distro that defaults to cgroup v2.${reset}\n"
      fi
    fi
  else
    fail "cannot reach the Docker daemon — $(docker_start_hint)"
    if [ "$(host_os)" = "linux" ] && [ "$(id -u)" != "0" ]; then
      sock=/var/run/docker.sock
      if [ -S "$sock" ] && [ ! -w "$sock" ]; then
        printf "  ${dim}%s is not writable by %s.${reset}\n" "$sock" "$(id -un)"
        if id -nG | tr ' ' '\n' | grep -Fxq docker; then
          printf "  ${dim}You are in the docker group; check that the daemon is healthy: sudo systemctl status docker${reset}\n"
        elif command -v getent >/dev/null 2>&1 && getent group docker | grep -Eq "[:,]$(id -un)(,|\$)"; then
          printf "  ${dim}You were added to the docker group but this session predates it: log out and back in (or run: newgrp docker).${reset}\n"
        else
          printf "  ${dim}Add yourself to the docker group: sudo usermod -aG docker \"\$USER\", then log out and back in.${reset}\n"
        fi
      elif [ ! -S "$sock" ]; then
        printf "  ${dim}%s does not exist: start the daemon (sudo systemctl start docker) or set DOCKER_HOST.${reset}\n" "$sock"
      fi
    fi
  fi
fi

printf '\nNetwork\n'
route_mtu="$(default_route_mtu)"
if [ -n "$route_mtu" ] && [ "$route_mtu" -lt 1500 ] 2>/dev/null; then
  warn "the default route has MTU ${route_mtu} (a VPN, most likely)"
  printf "  ${dim}Docker assumes 1500, so large image pulls can die with \"unexpected EOF\".${reset}\n"
  if [ "$(host_os)" = "macos" ]; then
    printf "  ${dim}Fix the host: Docker Desktop -> Settings -> Resources -> Network -> MTU = ${route_mtu}.${reset}\n"
  else
    printf "  ${dim}Fix the host: set \"mtu\": ${route_mtu} in /etc/docker/daemon.json, then: sudo systemctl restart docker${reset}\n"
  fi
  printf "  ${dim}Fix a profile's own engine: DOCKERD_ARGS=\"--mtu ${route_mtu}\" in its profile.env, then: just rebuild <profile>${reset}\n"
else
  ok "default route MTU ${route_mtu:-1500}"
fi

printf '\nDisk\n'
available_kb="$(df -Pk "$HOME" 2>/dev/null | tail -n1 | awk '{print $4}')"
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

containers=""
images=""
volumes=""
if [ "$docker_up" = "true" ]; then
  containers="$(docker ps --all --format '{{.Names}} {{.State}} {{.Label "'"$warp_label"'"}}' 2>/dev/null || true)"
  images="$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)"
  volumes="$(docker volume ls --format '{{.Name}} {{.Label "'"$warp_label"'"}}' 2>/dev/null || true)"
fi

ports_file="$(mktemp)"
trap 'rm -f "$ports_file"' EXIT

printf '\nProfiles\n'
profiles="$(profile_names)"
if [ -z "$profiles" ]; then
  printf "  ${dim}none — create one with: just new${reset}\n"
fi
for profile in $profiles; do
  set +e
  (
    load_profile "$profile"
    printf '%s\n' "${SSH_PORT:-}" >> "$ports_file"
    [ "$docker_up" = "true" ] || exit 0
    state="$(state_from_lines "$containers" "$CONTAINER_NAME")" || {
      printf "  ${dim}%-18s not created yet — run: just open %s${reset}\n" "$profile" "$profile"
      exit 0
    }
    if ! list_has "$images" "$IMAGE_NAME"; then
      printf "  ${yellow}warn${reset}  %-18s container exists but image %s is missing — run: just rebuild %s\n" "$profile" "$IMAGE_NAME" "$profile"
      exit 2
    fi
    if ! list_has "$(awk '{print $1}' <<<"$volumes")" "$WORK_VOLUME"; then
      printf "  ${yellow}warn${reset}  %-18s work volume %s is missing — run: just rebuild %s\n" "$profile" "$WORK_VOLUME" "$profile"
      exit 2
    fi
    if [ "$state" = "running" ] && ! docker exec "$CONTAINER_NAME" docker info >/dev/null 2>&1; then
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
    if [ "$state" = "running" ] && [ "${T3CODE_SERVE:-false}" = "true" ] && [ "${T3CODE_ACCESS:-local}" = "tailscale" ]; then
      tailnet_state="$(docker exec "$CONTAINER_NAME" tailnet status 2>/dev/null || printf 'off')"
      case "${tailnet_state%% *}" in
        running) ;;
        needs-login | stopped)
          printf "  ${yellow}warn${reset}  %-18s T3 Code is set to Tailscale, but the profile is not logged in — inside the shell, run: tailnet\n" "$profile"
          exit 2
          ;;
        needs-approval)
          printf "  ${yellow}warn${reset}  %-18s Tailscale node is waiting for approval in the admin console\n" "$profile"
          exit 2
          ;;
        off)
          printf "  ${yellow}warn${reset}  %-18s T3 Code is set to Tailscale, but tailscaled is not running in the profile — run: just rebuild %s\n" "$profile" "$profile"
          exit 2
          ;;
      esac
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
dupes="$(grep -v '^$' "$ports_file" | sort | uniq -d || true)"
if [ -n "$dupes" ]; then
  printf '\nSSH ports\n'
  for port in $dupes; do
    warn "port $port is claimed by more than one profile — change SSH_PORT in one of them, then: just rebuild <profile>"
  done
fi

if [ "$docker_up" = "true" ]; then
  orphan_containers=""
  while read -r name _ label; do
    [ -n "${name:-}" ] && [ -n "${label:-}" ] || continue
    [ -f "$profiles_root/$label/profile.env" ] && continue
    orphan_containers="$orphan_containers $name"
  done <<<"$containers"
  orphan_volumes=""
  while read -r name label; do
    [ -n "${name:-}" ] && [ -n "${label:-}" ] || continue
    [ -f "$profiles_root/$label/profile.env" ] && continue
    orphan_volumes="$orphan_volumes $name"
  done <<<"$volumes"
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
