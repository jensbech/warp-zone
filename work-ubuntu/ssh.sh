#!/usr/bin/env bash
set -euo pipefail

# Host-side helper: make `ssh <alias>` (and VS Code Remote-SSH) work for this
# profile. Run with --setup-only to (re)write the SSH config without connecting.
#
# Transport: instead of relying on container IPs or .test DNS (which may not
# resolve), SSH is tunnelled through `container exec` + netcat. This works
# regardless of host networking and survives the container's IP changing.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$script_dir/profile.env"

mode="${1:-connect}"

if [ "${INCLUDE_SSH:-false}" != "true" ]; then
  printf 'SSH is not enabled for profile "%s".\n' "${PROFILE_NAME:-?}" >&2
  printf 'Re-create it with `just new` and answer yes to "Enable SSH access".\n' >&2
  exit 1
fi

container_name="$CONTAINER_NAME"
host_alias="${SSH_HOSTNAME:-$PROFILE_NAME}"
ssh_user="${APP_USER:-elk}"

if ! container inspect "$container_name" >/dev/null 2>&1; then
  printf 'Container not created yet — run: just open %s\n' "$PROFILE_NAME" >&2
  exit 1
fi

# Write a managed, per-alias block into ~/.ssh/config (replacing any previous one).
ssh_dir="$HOME/.ssh"
config="$ssh_dir/config"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
touch "$config"
chmod 600 "$config"

begin="# >>> warp-zone:${host_alias} >>>"
end="# <<< warp-zone:${host_alias} <<<"

tmp="$(mktemp)"
awk -v b="$begin" -v e="$end" '
  $0==b { skip=1 }
  skip!=1 { print }
  $0==e { skip=0 }
' "$config" > "$tmp"

{
  cat "$tmp"
  printf '%s\n' "$begin"
  printf 'Host %s\n' "$host_alias"
  printf '  HostName %s\n' "$container_name"
  printf '  User %s\n' "$ssh_user"
  # %h is the HostName (the container name). Start it if stopped, then bridge
  # stdio to the container's sshd over `container exec` + nc.
  printf '  %s\n' 'ProxyCommand container start %h >/dev/null 2>&1 ; exec container exec -i %h nc 127.0.0.1 22'
  printf '  StrictHostKeyChecking accept-new\n'
  printf '  UserKnownHostsFile %s/known_hosts.warp-zone\n' "$ssh_dir"
  printf '%s\n' "$end"
} > "$config"
rm -f "$tmp"

printf 'SSH ready: ssh %s   (user %s, via container exec)\n' "$host_alias" "$ssh_user"
printf 'VS Code:   Remote-SSH -> Connect to Host -> %s\n' "$host_alias"

if [ "$mode" != "--setup-only" ]; then
  exec ssh "$host_alias"
fi
