#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

no_shell=false
for arg in "$@"; do
  if [ "$arg" = "--no-shell" ]; then no_shell=true; fi
done

while IFS= read -r var; do
  unset "$var"
done < <(compgen -v | grep -E '^(INCLUDE_|LINK_|SSH_)' || true)

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

# SSH access: collect the host public key(s) so bootstrap can authorize them.
# Prefer the configured key; if it is missing, fall back to any keys in ~/.ssh.
ssh_enable="${INCLUDE_SSH:-false}"
ssh_pubkey_path="${SSH_PUBKEY:-}"
ssh_authorized_key=""
if [ "$ssh_enable" = "true" ]; then
  if [ -n "$ssh_pubkey_path" ] && [ -f "$ssh_pubkey_path" ]; then
    ssh_authorized_key="$(cat "$ssh_pubkey_path")"
  else
    nl=$'\n'
    for k in "$HOME"/.ssh/*.pub; do
      [ -f "$k" ] || continue
      if [ -n "$ssh_authorized_key" ]; then
        ssh_authorized_key="$ssh_authorized_key$nl$(cat "$k")"
      else
        ssh_authorized_key="$(cat "$k")"
      fi
    done
    if [ -n "$ssh_authorized_key" ]; then
      printf 'Note: %s not found; authorizing existing key(s) in ~/.ssh instead.\n' \
        "${ssh_pubkey_path:-the configured key}" >&2
    fi
  fi
  if [ -z "$ssh_authorized_key" ]; then
    printf 'Warning: no SSH public key found on the host.\n' >&2
    printf '         Create one with:  ssh-keygen -t ed25519\n' >&2
    printf '         then re-run:      just open %s\n' "$PROFILE_NAME" >&2
  fi
fi

# Every container runs sshd as part of its command when the image has it, so
# SSH comes back up automatically whenever the container starts (e.g. after a
# host reboot) — even for profiles that enable SSH after the container exists.
run_command=(sh -c 'if command -v sshd >/dev/null 2>&1; then mkdir -p /run/sshd; /usr/sbin/sshd; fi; exec sleep infinity')

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
    "${run_command[@]}"
fi

if ! container list -q | grep -Fxq "$container_name"; then
  container start "$container_name"
fi

probe="$(container exec "$container_name" sh -c '
  if [ -x /usr/sbin/sshd ]; then printf "sshd\n"; fi
  if [ -x /usr/local/bin/bootstrap-home ]; then printf "bootstrap=/usr/local/bin/bootstrap-home\n"
  elif [ -x /usr/local/bin/bootstrap-work-ubuntu-home ]; then printf "bootstrap=/usr/local/bin/bootstrap-work-ubuntu-home\n"
  fi
' || true)"

if [ "$ssh_enable" = "true" ] && ! printf '%s\n' "$probe" | grep -qx 'sshd'; then
  printf 'Warning: SSH is enabled in profile.env but this image was built without it.\n' >&2
  printf '         Run: just rebuild %s\n' "$PROFILE_NAME" >&2
  ssh_enable=false
fi

bootstrap_command="$(printf '%s\n' "$probe" | sed -n 's/^bootstrap=//p')"
if [ -z "$bootstrap_command" ]; then
  printf 'Profile image is missing its bootstrap command. Run: just rebuild %s\n' "$PROFILE_NAME" >&2
  exit 1
fi

container exec "$container_name" env \
  LINK_GIT_IDENTITY="$link_git_identity" \
  LINK_CLAUDE="$link_claude" \
  LINK_OPENCODE="$link_opencode" \
  LINK_COPILOT="$link_copilot" \
  SSH_ENABLE="$ssh_enable" \
  SSH_AUTHORIZED_KEY="$ssh_authorized_key" \
  "$bootstrap_command"

# Write/refresh the host-side SSH config so `ssh <alias>` and VS Code Remote work.
if [ "$ssh_enable" = "true" ]; then
  "$script_dir/ssh.sh" --setup-only || true
fi

if [ "$no_shell" = "true" ]; then
  exit 0
fi

set +e
container exec -it "$container_name" su - "$APP_USER"
exit_code=$?
set -e

if [ "$exit_code" -eq 130 ]; then
  exit 0
fi

exit "$exit_code"
