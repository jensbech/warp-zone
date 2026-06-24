#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$script_dir/profile.env"

container_name="$CONTAINER_NAME"
image_name="$IMAGE_NAME"
dotfiles_dir="${DOTFILES_DIR:-}"
cpus="$CPUS"
memory="$MEMORY"

# "max" (the default) means give the container all host CPU cores and RAM.
if [ -z "$cpus" ] || [ "$cpus" = "max" ]; then
  cpus="$(sysctl -n hw.ncpu)"
fi
if [ -z "$memory" ] || [ "$memory" = "max" ]; then
  memory="$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))G"
fi

# Host dotfiles are optional. An empty DOTFILES_DIR keeps the profile hermetic —
# no host mount at all.
mount_args=()
if [ -n "$dotfiles_dir" ]; then
  if [ ! -d "$dotfiles_dir" ]; then
    printf 'Configured dotfiles directory does not exist: %s\n' "$dotfiles_dir" >&2
    exit 1
  fi
  mount_args+=(--mount "type=bind,source=$dotfiles_dir,target=/mnt/dotfiles,readonly")
fi

# Which dotfiles pieces to link during bootstrap. Legacy profiles (created before
# these flags existed) link everything when dotfiles are mounted, preserving the
# original behavior; new profiles set the flags explicitly in profile.env.
if [ -n "$dotfiles_dir" ]; then default_link=true; else default_link=false; fi
link_git_identity="${LINK_GIT_IDENTITY:-$default_link}"
link_claude="${LINK_CLAUDE:-$default_link}"
link_opencode="${LINK_OPENCODE:-$default_link}"
link_copilot="${LINK_COPILOT:-$default_link}"

# SSH access: read the host public key so bootstrap can authorize it.
ssh_enable="${INCLUDE_SSH:-false}"
ssh_pubkey_path="${SSH_PUBKEY:-}"
ssh_authorized_key=""
if [ "$ssh_enable" = "true" ]; then
  if [ -n "$ssh_pubkey_path" ] && [ -f "$ssh_pubkey_path" ]; then
    ssh_authorized_key="$(cat "$ssh_pubkey_path")"
  else
    printf 'Warning: SSH enabled but public key not found: %s\n' "${ssh_pubkey_path:-<unset>}" >&2
    printf '         sshd will start, but you will not be able to log in until a key is added.\n' >&2
  fi
fi

if ! container list >/dev/null 2>&1; then
  container system start
fi

if ! container image inspect "$image_name" >/dev/null 2>&1; then
  "$script_dir/build.sh"
fi

if ! container inspect "$container_name" >/dev/null 2>&1; then
  container create \
    --name "$container_name" \
    --cpus "$cpus" \
    --memory "$memory" \
    ${mount_args[@]+"${mount_args[@]}"} \
    "$image_name" \
    sleep infinity
fi

if ! container list -q | grep -Fxq "$container_name"; then
  container start "$container_name"
fi

container exec "$container_name" env \
  LINK_GIT_IDENTITY="$link_git_identity" \
  LINK_CLAUDE="$link_claude" \
  LINK_OPENCODE="$link_opencode" \
  LINK_COPILOT="$link_copilot" \
  SSH_ENABLE="$ssh_enable" \
  SSH_AUTHORIZED_KEY="$ssh_authorized_key" \
  /usr/local/bin/bootstrap-work-ubuntu-home

# Write/refresh the host-side SSH config so `ssh <alias>` and VS Code Remote work.
if [ "$ssh_enable" = "true" ]; then
  "$script_dir/ssh.sh" --setup-only || true
fi

container exec -it "$container_name" bash -ic "su - $APP_USER"
