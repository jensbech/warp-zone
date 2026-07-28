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
ssh_user="${APP_USER:-dev}"
ssh_pubkey_path="${SSH_PUBKEY:-}"
ssh_home="${APP_HOME:-/home/$ssh_user}"

has_ssh_pubkey=false
if [ -n "$ssh_pubkey_path" ] && [ -f "$ssh_pubkey_path" ]; then
  has_ssh_pubkey=true
else
  for k in "$HOME"/.ssh/*.pub; do
    [ -f "$k" ] || continue
    has_ssh_pubkey=true
    break
  done
fi

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

if grep -Fqx "Host $host_alias" "$config" && ! grep -Fqx "$begin" "$config"; then
  printf 'SSH alias "%s" is already managed outside warp-zone. Replace it? [y/N] ' "$host_alias"
  read -r answer
  if [ "$answer" != y ] && [ "$answer" != Y ]; then
    printf 'Choose another SSH alias in profile.env, then run: just open %s\n' "$PROFILE_NAME" >&2
    exit 1
  fi
  tmp_unmanaged="$(mktemp)"
  awk -v alias="$host_alias" '
    $1 == "Host" && $2 == alias { skip=1; next }
    skip && $1 == "Host" { skip=0 }
    !skip { print }
  ' "$config" > "$tmp_unmanaged"
  mv "$tmp_unmanaged" "$config"
fi

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
  printf "  ProxyCommand sh -c 'container start %%h >/dev/null 2>&1; exec container exec -i %%h nc 127.0.0.1 22'\n"
  printf '  StrictHostKeyChecking accept-new\n'
  printf '  UserKnownHostsFile %s/known_hosts.warp-zone\n' "$ssh_dir"
  printf '%s\n' "$end"
} > "$config"
rm -f "$tmp"

printf 'SSH ready: ssh %s   (user %s, via container exec)\n' "$host_alias" "$ssh_user"
printf 'VS Code:   Remote-SSH -> Connect to Host -> %s\n' "$host_alias"

if [ "$mode" != "--setup-only" ]; then
  if [ "$has_ssh_pubkey" != "true" ]; then
    printf 'No SSH public key found on the host.\n' >&2
    printf 'Create one with:  ssh-keygen -t ed25519\n' >&2
    printf 'Then re-run:      just open %s\n' "$PROFILE_NAME" >&2
    exit 1
  fi
  if ! container exec "$container_name" sh -lc "test -s '$ssh_home/.ssh/authorized_keys'"; then
    printf 'SSH key is not authorized in profile "%s" yet.\n' "$PROFILE_NAME" >&2
    printf 'Run: just open %s\n' "$PROFILE_NAME" >&2
    exit 1
  fi
  exec ssh "$host_alias"
fi
