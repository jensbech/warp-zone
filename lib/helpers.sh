#!/usr/bin/env bash
set -euo pipefail

profiles_root="${HOME}/warp"
warp_label='com.warp-zone.profile'

profile_dir() {
  printf '%s/%s\n' "$profiles_root" "$1"
}

load_profile() {
  local profile="$1"
  local env_file
  env_file="$(profile_dir "$profile")/profile.env"
  if [ ! -f "$env_file" ]; then
    printf '\033[31mNo such profile: %s\033[0m\n' "$profile" >&2
    exit 1
  fi
  set -a
  . "$env_file"
  set +a
}

profile_names() {
  local dir
  shopt -s nullglob
  for dir in "$profiles_root"/*/; do
    [ -f "$dir/profile.env" ] || continue
    basename "${dir%/}"
  done
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker is not installed or not on PATH — https://docs.docker.com/get-started/get-docker/\n' >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    printf 'Cannot reach the Docker daemon. %s\n' "$(docker_start_hint)" >&2
    exit 1
  fi
}

host_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    Linux) printf 'linux\n' ;;
    *) printf 'other\n' ;;
  esac
}

docker_start_hint() {
  if [ "$(host_os)" = "linux" ]; then
    if [ -S /var/run/docker.sock ] && [ ! -w /var/run/docker.sock ]; then
      printf 'Your user cannot use /var/run/docker.sock — run: sudo usermod -aG docker "$USER" and log in again.'
    else
      printf 'Start it with: sudo systemctl start docker (or start your Docker runtime).'
    fi
  else
    printf 'Start Docker Desktop (or your Docker runtime) and try again.'
  fi
}

default_route_mtu() {
  local iface
  if [ "$(host_os)" = "macos" ]; then
    route -n get default 2>/dev/null | awk '/mtu/ {getline; print $7}'
  elif command -v ip >/dev/null 2>&1; then
    iface="$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
    [ -n "$iface" ] && cat "/sys/class/net/$iface/mtu" 2>/dev/null
  fi
  return 0
}

sed_in_place() {
  local expr="$1" file="$2" tmp
  tmp="$(mktemp)"
  sed "$expr" "$file" > "$tmp" && cat "$tmp" > "$file"
  rm -f "$tmp"
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

container_running() {
  [ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = 'true' ]
}

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

container_missing() {
  printf 'Container not created yet — run: just open %s\n' "$1" >&2
  if ! docker info >/dev/null 2>&1; then
    printf 'Docker is not reachable either. %s\n' "$(docker_start_hint)" >&2
  fi
  exit 1
}

require_container() {
  local profile="$1" name="$2"
  if ! container_exists "$name"; then
    container_missing "$profile"
  fi
}

# Like require_container + ensure_running in one inspect. Prints "started" when
# it had to start the container.
require_running() {
  local profile="$1" name="$2" running
  if ! running="$(docker container inspect -f '{{.State.Running}}' "$name" 2>/dev/null)"; then
    container_missing "$profile"
  fi
  if [ "$running" != 'true' ]; then
    docker start "$name" >/dev/null
    printf 'started\n'
  fi
}

# Second field of the line whose first field is $2, in "name state ..." lines.
state_from_lines() {
  local line
  while IFS= read -r line; do
    if [ "${line%% *}" = "$2" ]; then
      line="${line#* }"
      printf '%s\n' "${line%% *}"
      return 0
    fi
  done <<<"$1"
  return 1
}

list_has() {
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
  esac
  return 1
}

remove_ssh_block() {
  local alias_name="$1" config="${2:-$HOME/.ssh/config}" begin end tmp
  begin="# >>> warp-zone:${alias_name} >>>"
  end="# <<< warp-zone:${alias_name} <<<"
  if [ -f "$config" ] && grep -Fqx "$begin" "$config"; then
    tmp="$(mktemp)"
    awk -v b="$begin" -v e="$end" '
      $0==b { skip=1 }
      skip!=1 { print }
      $0==e { skip=0 }
    ' "$config" > "$tmp"
    mv "$tmp" "$config"
    chmod 600 "$config"
    return 0
  fi
  return 1
}

# Start the container if it exists but is stopped. Prints "started" when it had
# to start it, so callers can put it back the way they found it.
ensure_running() {
  if ! container_running "$1"; then
    docker start "$1" >/dev/null
    printf 'started\n'
  fi
}

warp_containers() {
  docker ps --all --filter "label=$warp_label" --format '{{.Names}}'
}

warp_volumes() {
  docker volume ls --filter "label=$warp_label" --format '{{.Name}}'
}

warp_images() {
  docker image ls --filter "label=$warp_label" --format '{{.Repository}}:{{.Tag}}'
}

container_profile_label() {
  docker container inspect -f "{{index .Config.Labels \"$warp_label\"}}" "$1" 2>/dev/null || true
}

volume_profile_label() {
  docker volume inspect -f "{{index .Labels \"$warp_label\"}}" "$1" 2>/dev/null || true
}

tailscale_ready() {
  command -v tailscale >/dev/null 2>&1 \
    && tailscale status --json --peers=false 2>/dev/null | grep -q '"BackendState": *"Running"'
}

tailscale_dns_name() {
  tailscale status --json --peers=false 2>/dev/null \
    | awk -F'"' '/"Self"/ { self = 1 } self && $2 == "DNSName" { sub(/\.$/, "", $4); print $4; exit }'
}

tailscale_scheme() {
  if tailscale status --json --peers=false 2>/dev/null \
    | awk '/"CertDomains"/ { if ($0 ~ /null/) exit 1; getline; exit ($0 ~ /"/) ? 0 : 1 } END { if (NR == 0) exit 1 }'; then
    printf 'https\n'
  else
    printf 'http\n'
  fi
}

tailscale_url() {
  printf '%s://%s:%s\n' "$(tailscale_scheme)" "$(tailscale_dns_name)" "$1"
}

tailscale_serve_port() {
  local port="$1"
  tailscale serve --bg --yes "--$(tailscale_scheme)=$port" "http://127.0.0.1:$port" >/dev/null
}

tailscale_unserve_port() {
  local port="$1" scheme
  tailscale serve status --json 2>/dev/null | grep -q "\"Proxy\": *\"http://127.0.0.1:$port\"" || return 0
  for scheme in https http; do
    tailscale serve --yes "--$scheme=$port" off >/dev/null 2>&1 && return 0
  done
  return 1
}
