set shell := ["bash", "-euo", "pipefail", "-c"]

default_profile := "dev"
profiles_root := env_var_or_default('HOME', '') + "/container"

default:
	@printf '\033[1;36m%s\033[0m\n' '🌀 warp-zone'
	@printf '\033[2m%s\033[0m\n\n' 'Jump from macOS into a Linux world · profiles in ~/container · default: dev'
	@printf '\033[1m%s\033[0m\n' 'Get started'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just new' 'Create a profile (interactive wizard)'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just open [profile]' 'Build (if needed) and enter a profile'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just ssh [profile]' 'SSH into a profile (if SSH enabled)'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just run <profile> <cmd>' 'Run a one-off command in a profile'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just forward <port> [profile]' 'Forward a container port to localhost (via SSH)'
	@printf '\n\033[1m%s\033[0m\n' 'Manage'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just list' 'List your profiles'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just status [profile]' 'Show profile state and configuration'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just configure [profile]' 'Change profile settings with the wizard'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just start/stop [profile]' 'Control a container without changing its files'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just backup [profile]' 'Back up ~/work'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just restore [profile]' 'Restore ~/work from a backup'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just build [profile]' 'Build the image only'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just rebuild [profile]' 'Rebuild image and recreate container'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just update [profile]' 'Update OS packages in a running container'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just update-all' 'Update OS packages in every container (parallel)'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just logs [profile]' 'Show a container'"'"'s logs'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just prune' 'Remove stopped containers and unused images'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just doctor' 'Check your setup for problems'
	@printf '  \033[1;31m%-26s\033[0m \033[2m%s\033[0m\n' 'just destroy [profile]' 'Delete a profile, its container, and image'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just manage' 'Show profiles and common management commands'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just install-global' 'Install the warp command for use anywhere'
	@printf '\n\033[2m%s\033[0m\n' 'Tip: profile defaults to "dev" when omitted.'

alias create-profile := new
alias create-profile-default := new-default
alias list-profiles := list
alias delete := destroy

new:
	./create-profile.sh

new-default name:
	./create-profile.sh --dir {{name}} --yes

configure profile=default_profile:
	./create-profile.sh --dir {{profile}} --configure

# Refresh a profile's copies of the template scripts and lib helpers, so fixes
# in the repo reach existing profiles on every open/build/rebuild/ssh/restore.
_sync profile:
	#!/usr/bin/env bash
	set -euo pipefail
	dir="$HOME/container/{{profile}}"
	if [ ! -d "$dir" ]; then
	  printf 'No profile named "{{profile}}". Run `warp` to see profiles or `warp new` to create one.\n' >&2
	  exit 1
	fi
	src="{{justfile_directory()}}"
	cp "$src/template/Containerfile" "$src/template/bootstrap-home" "$src/template/build.sh" "$src/template/open.sh" "$src/template/rebuild.sh" "$src/template/ssh.sh" "$dir/"
	mkdir -p "$dir/templates" "$dir/lib"
	cp "$src/template/templates/.bashrc" "$src/template/templates/.zshenv" "$src/template/templates/.zshrc" "$dir/templates/"
	cp "$src/lib/helpers.sh" "$src/lib/backup.sh" "$src/lib/restore.sh" "$dir/lib/"
	chmod +x "$dir/build.sh" "$dir/open.sh" "$dir/rebuild.sh" "$dir/ssh.sh" "$dir/bootstrap-home" "$dir/lib/"*.sh

build profile=default_profile: (_sync profile)
	~/container/{{profile}}/build.sh

open profile=default_profile: (_sync profile)
	~/container/{{profile}}/open.sh

rebuild profile=default_profile: (_sync profile)
	~/container/{{profile}}/rebuild.sh

start profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/container/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	container start "$CONTAINER_NAME"

stop profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/container/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	container stop "$CONTAINER_NAME"

restart profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/container/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	if container list -q | grep -Fxq "$CONTAINER_NAME"; then
	  container stop "$CONTAINER_NAME"
	fi
	container start "$CONTAINER_NAME"

ssh profile=default_profile: (_sync profile)
	~/container/{{profile}}/ssh.sh

status profile='':
	#!/usr/bin/env bash
	set -euo pipefail
	if [ -n '{{profile}}' ]; then
	  "{{justfile_directory()}}/lib/status.sh" --detail '{{profile}}'
	else
	  "{{justfile_directory()}}/lib/status.sh"
	fi

backup profile=default_profile:
	"{{justfile_directory()}}/lib/backup.sh" '{{profile}}'

restore profile=default_profile: (_sync profile)
	"{{justfile_directory()}}/lib/restore.sh" '{{profile}}'

manage:
	"{{justfile_directory()}}/lib/menu.sh"

doctor:
	"{{justfile_directory()}}/lib/doctor.sh"

forward port profile=default_profile local_port='':
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/container/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	if [ "${INCLUDE_SSH:-false}" != "true" ]; then
	  printf 'Port forwarding uses SSH, which is not enabled for "%s".\n' "{{profile}}" >&2
	  printf 'Enable it with: just configure %s\n' "{{profile}}" >&2
	  exit 1
	fi
	lport="{{local_port}}"
	lport="${lport:-{{port}}}"
	host_alias="${SSH_HOSTNAME:-$PROFILE_NAME}"
	printf '\033[1;36mForwarding localhost:%s -> %s:%s\033[0m \033[2m(Ctrl-C to stop)\033[0m\n' "$lport" "{{profile}}" "{{port}}"
	exec ssh -N -L "$lport:127.0.0.1:{{port}}" "$host_alias"

run profile +cmd:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/container/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	if ! container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	  printf 'Container not created yet - run: just open %s\n' "{{profile}}" >&2
	  exit 1
	fi
	if ! container list -q | grep -Fxq "$CONTAINER_NAME"; then
	  container start "$CONTAINER_NAME" >/dev/null
	fi
	container exec -it "$CONTAINER_NAME" su - "$APP_USER" -c {{quote(cmd)}}

logs profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/container/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	container logs "$CONTAINER_NAME"

prune:
	#!/usr/bin/env bash
	set -euo pipefail
	printf 'This removes stopped containers and unused images. Profile backups are kept indefinitely. Continue? [y/N] '
	read -r answer
	[ "$answer" = y ] || [ "$answer" = Y ] || exit 0
	container prune
	container image prune

install-global:
	"{{justfile_directory()}}/install-warp.sh"

# Update all OS/apt packages (and rustup, if present) inside a running container.
# Tools pinned to a version at build time (Go, Bun, Deno, kubectl, ...) refresh via `just rebuild`.
update profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/container/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	set -a; . "$env_file"; set +a
	if ! container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
	  printf 'Container not created yet - run: just open %s\n' "{{profile}}" >&2
	  exit 1
	fi
	started=false
	if ! container list -q | grep -Fxq "${CONTAINER_NAME}"; then
	  container start "${CONTAINER_NAME}" >/dev/null
	  started=true
	fi
	printf '\033[1;36mUpdating OS packages in %s...\033[0m\n' "${CONTAINER_NAME}"
	container exec "${CONTAINER_NAME}" sudo env DEBIAN_FRONTEND=noninteractive bash -c \
	  'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge && apt-get clean'
	container exec "${CONTAINER_NAME}" bash -lc 'command -v rustup >/dev/null 2>&1 && rustup update || true'
	if [ "$started" = "true" ]; then
	  container stop "${CONTAINER_NAME}" >/dev/null
	fi
	printf '\033[1;32m%s is up to date\033[0m\n' "${CONTAINER_NAME}"

# Update OS/apt packages in every profile's container, all in parallel.
# Output is captured per profile and printed grouped once all finish.
update-all:
	#!/usr/bin/env bash
	set -euo pipefail
	shopt -s nullglob
	profiles=()
	for dir in "$HOME"/container/*/; do
	  [ -f "$dir/profile.env" ] || continue
	  profiles+=("$(basename "${dir%/}")")
	done
	if [ "${#profiles[@]}" -eq 0 ]; then
	  printf '\033[2mNo profiles to update.\033[0m\n'
	  exit 0
	fi
	printf '\033[1;36mUpdating %d profile(s) in parallel: %s\033[0m\n' "${#profiles[@]}" "${profiles[*]}"
	printf '\033[2m(this can take a while; per-profile output appears below as they finish)\033[0m\n'
	tmpdir="$(mktemp -d)"
	pids=()
	for profile in "${profiles[@]}"; do
	  (
	    {
	      set -a; . "$HOME/container/$profile/profile.env"; set +a
	      if ! container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
	        echo "skipped: container not created (run: just open $profile)"
	        exit 0
	      fi
	      started=false
	      if ! container list -q | grep -Fxq "${CONTAINER_NAME}"; then
	        container start "${CONTAINER_NAME}" >/dev/null
	        started=true
	      fi
	      container exec "${CONTAINER_NAME}" sudo env DEBIAN_FRONTEND=noninteractive bash -c \
	        'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge && apt-get clean'
	      container exec "${CONTAINER_NAME}" bash -lc 'command -v rustup >/dev/null 2>&1 && rustup update || true'
	      if [ "$started" = "true" ]; then
	        container stop "${CONTAINER_NAME}" >/dev/null
	      fi
	      echo "done"
	    } >"$tmpdir/$profile.log" 2>&1
	  ) &
	  pids+=("$!")
	done
	rc=0
	failed=()
	for i in "${!pids[@]}"; do
	  if ! wait "${pids[$i]}"; then
	    rc=1
	    failed+=("${profiles[$i]}")
	  fi
	done
	for profile in "${profiles[@]}"; do
	  printf '\n\033[1m=== %s ===\033[0m\n' "$profile"
	  cat "$tmpdir/$profile.log" 2>/dev/null || true
	done
	rm -rf "$tmpdir"
	if [ "$rc" -eq 0 ]; then
	  printf '\n\033[1;32mAll profiles processed.\033[0m\n'
	else
	  printf '\n\033[33mFailed: %s - see output above.\033[0m\n' "${failed[*]}" >&2
	fi
	exit "$rc"

# Permanently delete a profile and every trace of it: the running container, its
# image, and the ~/container/<profile> directory. Requires typing the name to confirm.
destroy profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	profile_dir="$HOME/container/{{profile}}"
	if [ ! -d "$profile_dir" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	container_name="{{profile}}"
	image_name=""
	if [ -f "$profile_dir/profile.env" ]; then
	  set -a; . "$profile_dir/profile.env"; set +a
	  container_name="${CONTAINER_NAME:-{{profile}}}"
	  image_name="${IMAGE_NAME:-}"
	fi
	printf '\033[1;31mAbout to permanently delete profile "%s":\033[0m\n' "{{profile}}"
	printf '  container : %s\n' "${container_name}"
	printf '  image     : %s\n' "${image_name:-<none>}"
	printf '  directory : %s\n' "${profile_dir}"
	printf '\033[2m%s\033[0m\n' "This deletes all container state and cannot be undone."
	printf 'Type the profile name (%s) to confirm: ' "{{profile}}"
	read -r reply
	if [ "$reply" != "{{profile}}" ]; then
	  printf '\033[33mName did not match - aborted. Nothing was deleted.\033[0m\n' >&2
	  exit 1
	fi
	if container inspect "${container_name}" >/dev/null 2>&1; then
	  if container list -q | grep -Fxq "${container_name}"; then
	    container stop "${container_name}" >/dev/null 2>&1 || true
	  fi
	  container delete "${container_name}" >/dev/null 2>&1 || true
	fi
	if [ -n "${image_name}" ]; then
	  container image delete "${image_name}" >/dev/null 2>&1 \
	    || printf '\033[33mNote: could not delete image %s (it may not exist).\033[0m\n' "${image_name}"
	fi
	ssh_alias="${SSH_HOSTNAME:-{{profile}}}"
	ssh_config="$HOME/.ssh/config"
	block_begin="# >>> warp-zone:${ssh_alias} >>>"
	block_end="# <<< warp-zone:${ssh_alias} <<<"
	if [ -f "$ssh_config" ] && grep -Fqx "$block_begin" "$ssh_config"; then
	  tmp="$(mktemp)"
	  awk -v b="$block_begin" -v e="$block_end" '
	    $0==b { skip=1 }
	    skip!=1 { print }
	    $0==e { skip=0 }
	  ' "$ssh_config" > "$tmp"
	  mv "$tmp" "$ssh_config"
	  chmod 600 "$ssh_config"
	  printf 'Removed SSH alias "%s" from ~/.ssh/config.\n' "$ssh_alias"
	fi
	rm -rf "$profile_dir"
	printf '\033[1;32mDeleted profile "%s" and all its traces.\033[0m\n' "{{profile}}"

list:
	@mkdir -p ~/container
	@"{{justfile_directory()}}/lib/status.sh"

install-deps:
	npm install
