#!/usr/bin/env bash
set -euo pipefail

# Host-side helper: make `ssh <alias>` (and VS Code Remote-SSH) work for this
# profile. Run with --setup-only to (re)write the SSH config without connecting.
#
# Transport: the container publishes port 22 on 127.0.0.1:$SSH_PORT, so this is
# an ordinary TCP connection — no ProxyCommand, and scp/rsync/VS Code all work.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/helpers.sh"

. "$script_dir/profile.env"

mode="${1:-connect}"

if [ "${INCLUDE_SSH:-false}" != "true" ]; then
  printf 'SSH is not enabled for profile "%s".\n' "${PROFILE_NAME:-?}" >&2
  printf 'Turn it on with: just configure %s\n' "${PROFILE_NAME:-?}" >&2
  exit 1
fi

container_name="$CONTAINER_NAME"
host_alias="${SSH_HOSTNAME:-$PROFILE_NAME}"
ssh_user="${APP_USER:-dev}"
ssh_port="$SSH_PORT"
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

require_docker
require_container "$PROFILE_NAME" "$container_name"

# Write a managed, per-alias block into ~/.ssh/config (replacing any previous one).
ssh_dir="$HOME/.ssh"
config="$ssh_dir/config"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
touch "$config"
chmod 600 "$config"

begin="# >>> warp-zone:${host_alias} >>>"
end="# <<< warp-zone:${host_alias} <<<"

if awk -v alias="$host_alias" '
  $1 == "Host" { for (i = 2; i <= NF; i++) if ($i == alias) found = 1 }
  END { exit found ? 0 : 1 }
' "$config" && ! grep -Fqx "$begin" "$config"; then
  printf 'SSH alias "%s" is already managed outside warp-zone. Replace it? [y/N] ' "$host_alias"
  read -r answer
  if [ "$answer" != y ] && [ "$answer" != Y ]; then
    printf 'Choose another SSH alias in profile.env, then run: just open %s\n' "$PROFILE_NAME" >&2
    exit 1
  fi
  tmp_unmanaged="$(mktemp)"
  awk -v alias="$host_alias" '
    $1 == "Host" {
      has = 0
      for (i = 2; i <= NF; i++) if ($i == alias) has = 1
      if (!has) { skip = 0; print; next }
      line = "Host"; kept = 0
      for (i = 2; i <= NF; i++) if ($i != alias) { line = line " " $i; kept++ }
      if (kept == 0) { skip = 1; next }
      skip = 0; print line; next
    }
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
  printf '  HostName 127.0.0.1\n'
  printf '  Port %s\n' "$ssh_port"
  printf '  User %s\n' "$ssh_user"
  # Every profile answers on 127.0.0.1 with its own host key, so the usual
  # known_hosts bookkeeping only produces false alarms here.
  printf '  StrictHostKeyChecking no\n'
  printf '  UserKnownHostsFile /dev/null\n'
  printf '  LogLevel ERROR\n'
  printf '%s\n' "$end"
} > "$config"
rm -f "$tmp"

printf 'SSH ready: ssh %s   (user %s, 127.0.0.1:%s)\n' "$host_alias" "$ssh_user" "$ssh_port"
printf 'VS Code:   Remote-SSH -> Connect to Host -> %s\n' "$host_alias"

if [ "$mode" != "--setup-only" ]; then
  if [ "$has_ssh_pubkey" != "true" ]; then
    printf 'No SSH public key found on the host.\n' >&2
    printf 'Create one with:  ssh-keygen -t ed25519\n' >&2
    printf 'Then re-run:      just open %s\n' "$PROFILE_NAME" >&2
    exit 1
  fi
  if ! container_running "$container_name"; then
    docker start "$container_name" >/dev/null
  fi
  if ! docker exec "$container_name" sh -lc "test -s '$ssh_home/.ssh/authorized_keys'"; then
    printf 'SSH key is not authorized in profile "%s" yet.\n' "$PROFILE_NAME" >&2
    printf 'Run: just open %s\n' "$PROFILE_NAME" >&2
    exit 1
  fi
  exec ssh "$host_alias"
fi
