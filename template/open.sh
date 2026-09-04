#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/helpers.sh"

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
work_volume="$WORK_VOLUME"
docker_volume="$DOCKER_VOLUME"
dotfiles_dir="${DOTFILES_DIR:-}"
cpus="$CPUS"
memory="$MEMORY"
ssh_port="$SSH_PORT"

require_docker

# "max" (the default) means give the container everything the Docker VM has.
# That ceiling is the VM's allocation, not your Mac's — Docker Desktop decides
# how much of the host it gets, and asking for more than that fails to start.
if [ -z "$cpus" ] || [ "$cpus" = "max" ]; then
  cpus="$(docker info --format '{{.NCPU}}')"
fi
if [ -z "$memory" ] || [ "$memory" = "max" ]; then
  memory="$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 ))m"
fi

# Host dotfiles are optional. An empty DOTFILES_DIR keeps the profile hermetic —
# no host mount at all.
# DOCKERD_ARGS reaches the inner daemon as one value — building it into an array
# keeps flags like "--mtu 1420" from splitting into separate docker arguments.
env_args=()
if [ -n "${DOCKERD_ARGS:-}" ]; then
  env_args+=(-e "DOCKERD_ARGS=$DOCKERD_ARGS")
fi

mount_args=()
if [ -n "$dotfiles_dir" ]; then
  if [ ! -d "$dotfiles_dir" ]; then
    printf 'Configured dotfiles directory does not exist: %s\n' "$dotfiles_dir" >&2
    exit 1
  fi
  mount_args+=(-v "$dotfiles_dir:/mnt/dotfiles:ro")
fi

# Which dotfiles pieces to link during bootstrap.
link_git_identity="${LINK_GIT_IDENTITY:-false}"
link_claude="${LINK_CLAUDE:-false}"
link_opencode="${LINK_OPENCODE:-false}"
link_copilot="${LINK_COPILOT:-false}"

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
    if [ -n "$ssh_authorized_key" ] && [ -n "$ssh_pubkey_path" ]; then
      printf 'Note: %s not found; authorizing existing key(s) in ~/.ssh instead.\n' \
        "$ssh_pubkey_path" >&2
    fi
  fi
  if [ -z "$ssh_authorized_key" ]; then
    printf 'Warning: no SSH public key found on the host.\n' >&2
    printf '         Create one with:  ssh-keygen -t ed25519\n' >&2
    printf '         then re-run:      just open %s\n' "$PROFILE_NAME" >&2
  fi
fi

if ! docker image inspect "$image_name" >/dev/null 2>&1; then
  "$script_dir/build.sh"
fi

if ! container_exists "$container_name"; then
  # --privileged is what makes the inner dockerd work. The two volumes carry
  # everything worth keeping: ~/work (yours) and /var/lib/docker (its images and
  # volumes), so recreating the container costs nothing but the container itself.
  docker volume create --label "$warp_label=$PROFILE_NAME" "$work_volume" >/dev/null
  docker volume create --label "$warp_label=$PROFILE_NAME" "$docker_volume" >/dev/null
  docker run -d \
    --name "$container_name" \
    --hostname "$PROFILE_NAME" \
    --label "$warp_label=$PROFILE_NAME" \
    --privileged \
    --restart unless-stopped \
    --cpus "$cpus" \
    --memory "$memory" \
    -p "127.0.0.1:$ssh_port:22" \
    -v "$work_volume:/home/$APP_USER/work" \
    -v "$docker_volume:/var/lib/docker" \
    ${env_args[@]+"${env_args[@]}"} \
    ${mount_args[@]+"${mount_args[@]}"} \
    "$image_name" >/dev/null
fi

if ! container_running "$container_name"; then
  docker start "$container_name" >/dev/null
fi

probe="$(docker exec "$container_name" sh -c '
  if [ -x /usr/sbin/sshd ]; then printf "sshd\n"; fi
  if [ -x /usr/local/bin/bootstrap-home ]; then printf "bootstrap=/usr/local/bin/bootstrap-home\n"; fi
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

docker exec "$container_name" env \
  LINK_GIT_IDENTITY="$link_git_identity" \
  LINK_CLAUDE="$link_claude" \
  LINK_OPENCODE="$link_opencode" \
  LINK_COPILOT="$link_copilot" \
  SSH_ENABLE="$ssh_enable" \
  SSH_AUTHORIZED_KEY="$ssh_authorized_key" \
  "$bootstrap_command"

# The inner dockerd starts in the background, so a fresh container can hand you a
# shell before `docker` works in it. Wait it out rather than let that race show.
if ! docker exec "$container_name" docker info >/dev/null 2>&1; then
  printf 'Waiting for the profile'\''s Docker engine...'
  for _ in $(seq 1 180); do
    if docker exec "$container_name" docker info >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  if docker exec "$container_name" docker info >/dev/null 2>&1; then
    printf ' ready\n'
  else
    printf ' not ready\n'
    printf 'The inner Docker engine did not start. Inspect it with:\n' >&2
    printf '  just run %s "sudo cat /var/log/dockerd.log"\n' "$PROFILE_NAME" >&2
  fi
fi

# Write/refresh the host-side SSH config so `ssh <alias>` and VS Code Remote work.
if [ "$ssh_enable" = "true" ]; then
  "$script_dir/ssh.sh" --setup-only || true
fi

# Without a terminal there is no shell to hand over — scripts calling open.sh
# (rebuild, restore, smoke) just want the container up and bootstrapped.
if [ "$no_shell" = "true" ] || [ ! -t 0 ]; then
  exit 0
fi

set +e
docker exec -it "$container_name" su - "$APP_USER"
exit_code=$?
set -e

if [ "$exit_code" -eq 130 ]; then
  exit 0
fi

exit "$exit_code"
