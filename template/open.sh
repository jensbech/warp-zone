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
done < <(compgen -v | grep -E '^(INCLUDE_|LINK_|SSH_|T3CODE_)' || true)

. "$script_dir/profile.env"

container_name="$CONTAINER_NAME"
image_name="$IMAGE_NAME"
work_volume="$WORK_VOLUME"
docker_volume="$DOCKER_VOLUME"
dotfiles_dir="${DOTFILES_DIR:-}"
cpus="$CPUS"
memory="$MEMORY"
ssh_port="$SSH_PORT"
t3code_serve="${T3CODE_SERVE:-false}"
t3code_port="${T3CODE_PORT:-}"
t3code_binding=""
if [ "$t3code_serve" = "true" ]; then
  if [ -z "$t3code_port" ]; then
    printf 'T3CODE_SERVE is on but T3CODE_PORT is empty in profile.env. Run: just configure %s\n' "$PROFILE_NAME" >&2
    exit 1
  fi
  t3code_binding="$t3code_port"
fi

require_docker

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

container_info="$(docker container inspect -f '{{.State.Running}} {{index .Config.Labels "com.warp-zone.t3code"}}' "$container_name" 2>/dev/null)" || container_info=missing
container_state="${container_info%% *}"
if [ "$container_state" != missing ] && [ "${container_info#* }" != "$t3code_binding" ]; then
  printf 'T3 Code settings changed; recreating the container (~/work and its Docker state are kept)...\n'
  docker rm -f "$container_name" >/dev/null
  container_state=missing
fi

if [ "$container_state" = missing ]; then
  if ! docker image inspect "$image_name" >/dev/null 2>&1; then
    "$script_dir/build.sh"
  fi

# "max" (the default) means give the container everything the Docker VM has.
# That ceiling is the Docker engine's allocation: the whole host on Linux, the VM's
# share on macOS (Docker Desktop decides), and asking for more fails to start.
if [ -z "$cpus" ] || [ "$cpus" = "max" ]; then
  cpus="$(docker info --format '{{.NCPU}}')"
fi
if [ -z "$memory" ] || [ "$memory" = "max" ]; then
  memory="$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 ))m"
fi

  # --privileged is what makes the inner dockerd work. The two volumes carry
  # everything worth keeping: ~/work (yours) and /var/lib/docker (its images and
  # volumes), so recreating the container costs nothing but the container itself.
  docker volume create --label "$warp_label=$PROFILE_NAME" "$work_volume" >/dev/null
  docker volume create --label "$warp_label=$PROFILE_NAME" "$docker_volume" >/dev/null
  t3code_args=()
  if [ "$t3code_serve" = "true" ]; then
    t3code_args+=(-p "127.0.0.1:$t3code_port:3773" -e T3CODE_SERVE=true)
  fi
  docker run -d \
    --name "$container_name" \
    --hostname "$PROFILE_NAME" \
    --label "$warp_label=$PROFILE_NAME" \
    --label "com.warp-zone.t3code=$t3code_binding" \
    --privileged \
    --restart unless-stopped \
    --cpus "$cpus" \
    --memory "$memory" \
    -p "127.0.0.1:$ssh_port:22" \
    -v "$work_volume:/home/$APP_USER/work" \
    -v "$docker_volume:/var/lib/docker" \
    ${env_args[@]+"${env_args[@]}"} \
    ${t3code_args[@]+"${t3code_args[@]}"} \
    ${mount_args[@]+"${mount_args[@]}"} \
    "$image_name" >/dev/null
fi

if [ "$container_state" = false ]; then
  docker start "$container_name" >/dev/null
fi

bootstrap_script='
  [ -x /usr/local/bin/bootstrap-home ] || exit 90
  rc=0
  if [ "$SSH_ENABLE" = true ] && [ ! -x /usr/sbin/sshd ]; then
    SSH_ENABLE=false
    rc=91
  fi
  export SSH_ENABLE
  /usr/local/bin/bootstrap-home || exit $?
  if [ "$T3CODE_SERVE" = true ] && ! command -v t3 >/dev/null 2>&1; then
    rc=93
  fi
  if ! docker info >/dev/null 2>&1; then
    printf "Waiting for the profile'\''s Docker engine..."
    i=0
    while [ "$i" -lt 180 ] && ! docker info >/dev/null 2>&1; do
      sleep 0.5
      i=$((i + 1))
    done
    if docker info >/dev/null 2>&1; then
      printf " ready\n"
    else
      printf " not ready\n"
      [ "$rc" -eq 0 ] && rc=92
    fi
  fi
  exit "$rc"
'

set +e
docker exec \
  -e LINK_GIT_IDENTITY="$link_git_identity" \
  -e LINK_CLAUDE="$link_claude" \
  -e LINK_OPENCODE="$link_opencode" \
  -e LINK_COPILOT="$link_copilot" \
  -e SSH_ENABLE="$ssh_enable" \
  -e SSH_AUTHORIZED_KEY="$ssh_authorized_key" \
  -e T3CODE_SERVE="$t3code_serve" \
  "$container_name" sh -c "$bootstrap_script"
bootstrap_rc=$?
set -e

case "$bootstrap_rc" in
  0) ;;
  90)
    printf 'Profile image is missing its bootstrap command. Run: just rebuild %s\n' "$PROFILE_NAME" >&2
    exit 1
    ;;
  91)
    printf 'Warning: SSH is enabled in profile.env but this image was built without it.\n' >&2
    printf '         Run: just rebuild %s\n' "$PROFILE_NAME" >&2
    ssh_enable=false
    ;;
  93)
    printf 'Warning: T3 Code is enabled but this image was built without it.\n' >&2
    printf '         Run: just rebuild %s\n' "$PROFILE_NAME" >&2
    t3code_serve=false
    ;;
  92)
    printf 'The inner Docker engine did not start. Inspect it with:\n' >&2
    printf '  just run %s "sudo cat /var/log/dockerd.log"\n' "$PROFILE_NAME" >&2
    ;;
  *) exit "$bootstrap_rc" ;;
esac

# Write/refresh the host-side SSH config so `ssh <alias>` and VS Code Remote work.
if [ "$ssh_enable" = "true" ]; then
  "$script_dir/ssh.sh" --setup-only || true
fi

tailnet_state="$script_dir/.tailscale-port"
tailnet_port=""
if [ "$t3code_serve" = "true" ] && [ "${T3CODE_ACCESS:-local}" = "tailscale" ]; then
  tailnet_port="$t3code_port"
fi
if [ -f "$tailnet_state" ] && [ "$(cat "$tailnet_state")" != "$tailnet_port" ] && command -v tailscale >/dev/null 2>&1; then
  tailscale_unserve_port "$(cat "$tailnet_state")" || true
  rm -f "$tailnet_state"
fi

if [ "$t3code_serve" = "true" ]; then
  printf 'T3 Code:   http://localhost:%s   (pair this browser with: just t3 %s)\n' "$t3code_port" "$PROFILE_NAME"
  if [ -n "$tailnet_port" ]; then
    if tailscale_ready && tailscale_serve_port "$tailnet_port"; then
      printf '%s\n' "$tailnet_port" > "$tailnet_state"
      printf 'Tailnet:   %s   (pair another device with: just t3 %s qr)\n' "$(tailscale_url "$tailnet_port")" "$PROFILE_NAME"
    else
      printf 'Warning: T3CODE_ACCESS is tailscale, but Tailscale is not running on this host - T3 Code is local only for now.\n' >&2
    fi
  fi
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
