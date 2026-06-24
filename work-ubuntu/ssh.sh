#!/usr/bin/env bash
set -euo pipefail

# Host-side helper: make `ssh <alias>` (and VS Code Remote-SSH) work for this
# profile. Run with --setup-only to refresh the SSH config without connecting.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$script_dir/profile.env"

mode="${1:-connect}"

if [ "${INCLUDE_SSH:-false}" != "true" ]; then
  printf 'SSH is not enabled for profile "%s".\n' "${PROFILE_NAME:-?}" >&2
  printf 'Re-create it with `just new` and tick "OpenSSH server".\n' >&2
  exit 1
fi

container_name="$CONTAINER_NAME"
host_alias="${SSH_HOSTNAME:-$PROFILE_NAME}"
ssh_user="${APP_USER:-elk}"
# Apple's container runtime resolves each container by name on the .test domain.
target_host="${container_name}.test"

if ! container inspect "$container_name" >/dev/null 2>&1; then
  printf 'Container not created yet — run: just open %s\n' "$PROFILE_NAME" >&2
  exit 1
fi

if ! container list -q | grep -Fxq "$container_name"; then
  container start "$container_name" >/dev/null
fi

# Make sure sshd is actually listening (idempotent).
container exec "$container_name" bash -c 'mkdir -p /run/sshd; pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd' || true

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
  printf '  HostName %s\n' "$target_host"
  printf '  User %s\n' "$ssh_user"
  printf '  StrictHostKeyChecking accept-new\n'
  printf '  UserKnownHostsFile %s/known_hosts.warp-zone\n' "$ssh_dir"
  printf '%s\n' "$end"
} > "$config"
rm -f "$tmp"

printf 'SSH ready: ssh %s   (%s@%s)\n' "$host_alias" "$ssh_user" "$target_host"
printf 'VS Code:   Remote-SSH -> Connect to Host -> %s\n' "$host_alias"

if [ "$mode" != "--setup-only" ]; then
  exec ssh "$host_alias"
fi
