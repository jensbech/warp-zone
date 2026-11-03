#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

spec="${1:?ports are required}"
profile="${2:-dev}"
lport="${3:-}"

fail() {
  printf '\033[31m%s\033[0m\n' "$1" >&2
  exit 1
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

load_profile "$profile"
if [ "${INCLUDE_SSH:-false}" != "true" ]; then
  printf 'Port forwarding uses SSH, which is not enabled for "%s".\n' "$profile" >&2
  printf 'Enable it with: just configure %s\n' "$profile" >&2
  exit 1
fi

ports=()
IFS=',' read -ra requested <<< "$spec"
for item in ${requested[@]+"${requested[@]}"}; do
  item="${item// /}"
  [ -n "$item" ] || continue
  case "$item" in
    *-*)
      first="${item%%-*}"; last="${item##*-}"
      if ! valid_port "$first" || ! valid_port "$last" || [ "$first" -gt "$last" ]; then
        fail "Not a valid port range: $item"
      fi
      for ((p = first; p <= last; p++)); do ports+=("$p"); done
      ;;
    *)
      valid_port "$item" || fail "Not a valid port: $item"
      ports+=("$item")
      ;;
  esac
done
if [ "${#ports[@]}" -eq 0 ]; then
  fail 'No ports given.'
fi
if [ -n "$lport" ]; then
  [ "${#ports[@]}" -eq 1 ] || fail 'A local port can only be given when forwarding a single port.'
  valid_port "$lport" || fail "Not a valid local port: $lport"
fi

host_alias="${SSH_HOSTNAME:-$PROFILE_NAME}"
forward_args=()
for port in "${ports[@]}"; do
  local_side="${lport:-$port}"
  forward_args+=(-L "$local_side:127.0.0.1:$port")
  printf '\033[1;36mForwarding localhost:%s -> %s:%s\033[0m\n' "$local_side" "$profile" "$port"
done
printf '\033[2m(Ctrl-C to stop)\033[0m\n'
exec ssh -N -o ExitOnForwardFailure=yes "${forward_args[@]}" "$host_alias"
