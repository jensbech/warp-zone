set shell := ["bash", "-euo", "pipefail", "-c"]

default_profile := "dev"
profiles_root := env_var_or_default('HOME', '') + "/warp"

default:
	@"{{justfile_directory()}}/lib/menu.sh" just

alias create-profile := new
alias create-profile-default := new-default
alias list-profiles := list
alias delete := destroy

new:
	./create-profile.sh

new-default name:
	./create-profile.sh --dir {{name}} --yes

new-from recipe name='':
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{justfile_directory()}}"
	name="{{name}}"
	./create-profile.sh --recipe '{{recipe}}' --dir "${name:-{{recipe}}}" --yes

save profile=default_profile name='':
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{justfile_directory()}}"
	name="{{name}}"
	./create-profile.sh --export "${name:-{{profile}}}" --dir '{{profile}}'

recipes:
	@./create-profile.sh --list-recipes

up recipe name='':
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{justfile_directory()}}"
	name="{{name}}"
	name="${name:-{{recipe}}}"
	if [ ! -d "$HOME/warp/$name" ]; then
	  ./create-profile.sh --recipe '{{recipe}}' --dir "$name" --yes
	fi
	just --justfile "{{justfile()}}" open "$name"

configure profile=default_profile:
	./create-profile.sh --dir {{profile}} --configure

# Refresh a profile's copies of the template scripts and lib helpers, so fixes
# in the repo reach existing profiles on every open/build/rebuild/ssh/restore.
_sync profile:
	#!/usr/bin/env bash
	set -euo pipefail
	dir="$HOME/warp/{{profile}}"
	if [ ! -d "$dir" ]; then
	  printf 'No profile named "{{profile}}". Run `warp` to see profiles or `warp new` to create one.\n' >&2
	  exit 1
	fi
	src="{{justfile_directory()}}"
	cp "$src/template/Dockerfile" "$src/template/.dockerignore" "$src/template/bootstrap-home" "$src/template/warp-init" "$src/template/build.sh" "$src/template/open.sh" "$src/template/rebuild.sh" "$src/template/ssh.sh" "$dir/"
	mkdir -p "$dir/templates" "$dir/lib"
	cp "$src/template/templates/.bashrc" "$src/template/templates/.zshenv" "$src/template/templates/.zshrc" "$dir/templates/"
	cp "$src/lib/helpers.sh" "$src/lib/backup.sh" "$src/lib/restore.sh" "$dir/lib/"
	if [ ! -f "$dir/setup.sh" ]; then
	  cp "$src/template/setup.sh" "$dir/setup.sh"
	fi
	chmod +x "$dir/build.sh" "$dir/open.sh" "$dir/rebuild.sh" "$dir/ssh.sh" "$dir/bootstrap-home" "$dir/warp-init" "$dir/lib/"*.sh

build profile=default_profile: (_sync profile)
	~/warp/{{profile}}/build.sh

open profile=default_profile: (_sync profile)
	~/warp/{{profile}}/open.sh

rebuild profile=default_profile: (_sync profile)
	~/warp/{{profile}}/rebuild.sh

start profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/warp/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	docker start "$CONTAINER_NAME" >/dev/null

stop profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/warp/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	docker stop "$CONTAINER_NAME" >/dev/null

restart profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/warp/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	docker restart "$CONTAINER_NAME" >/dev/null

ssh profile=default_profile: (_sync profile)
	~/warp/{{profile}}/ssh.sh

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
	@"{{justfile_directory()}}/lib/menu.sh" warp

doctor:
	"{{justfile_directory()}}/lib/doctor.sh"

forward port profile=default_profile local_port='':
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/warp/{{profile}}/profile.env"
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
	env_file="$HOME/warp/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	  printf 'Container not created yet - run: just open %s\n' "{{profile}}" >&2
	  exit 1
	fi
	docker start "$CONTAINER_NAME" >/dev/null
	if [ -t 0 ]; then tty_flags=(-it); else tty_flags=(-i); fi
	docker exec "${tty_flags[@]}" "$CONTAINER_NAME" su - "$APP_USER" -c {{quote(cmd)}}

logs profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/warp/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	. "$env_file"
	docker logs "$CONTAINER_NAME"

prune:
	"{{justfile_directory()}}/lib/prune.sh"

install-global:
	"{{justfile_directory()}}/install-warp.sh"

# Update all OS/apt packages (and rustup, if present) inside a running container.
# Tools pinned to a version at build time (Go, Bun, Deno, kubectl, ...) refresh via `just rebuild`.
update profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	env_file="$HOME/warp/{{profile}}/profile.env"
	if [ ! -f "$env_file" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	set -a; . "$env_file"; set +a
	if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
	  printf 'Container not created yet - run: just open %s\n' "{{profile}}" >&2
	  exit 1
	fi
	started=false
	if [ "$(docker container inspect -f '{{{{.State.Running}}}}' "${CONTAINER_NAME}")" != 'true' ]; then
	  docker start "${CONTAINER_NAME}" >/dev/null
	  started=true
	fi
	printf '\033[1;36mUpdating OS packages in %s...\033[0m\n' "${CONTAINER_NAME}"
	docker exec "${CONTAINER_NAME}" sudo env DEBIAN_FRONTEND=noninteractive bash -c \
	  'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge && apt-get clean'
	docker exec "${CONTAINER_NAME}" bash -lc 'command -v rustup >/dev/null 2>&1 && rustup update || true'
	if [ "$started" = "true" ]; then
	  docker stop "${CONTAINER_NAME}" >/dev/null
	fi
	printf '\033[1;32m%s is up to date\033[0m\n' "${CONTAINER_NAME}"

# Update OS/apt packages in every profile's container, all in parallel.
# Output is captured per profile and printed grouped once all finish.
update-all:
	#!/usr/bin/env bash
	set -euo pipefail
	shopt -s nullglob
	profiles=()
	for dir in "$HOME"/warp/*/; do
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
	      set -a; . "$HOME/warp/$profile/profile.env"; set +a
	      if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
	        echo "skipped: container not created (run: just open $profile)"
	        exit 0
	      fi
	      started=false
	      if [ "$(docker container inspect -f '{{{{.State.Running}}}}' "${CONTAINER_NAME}")" != 'true' ]; then
	        docker start "${CONTAINER_NAME}" >/dev/null
	        started=true
	      fi
	      docker exec "${CONTAINER_NAME}" sudo env DEBIAN_FRONTEND=noninteractive bash -c \
	        'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge && apt-get clean'
	      docker exec "${CONTAINER_NAME}" bash -lc 'command -v rustup >/dev/null 2>&1 && rustup update || true'
	      if [ "$started" = "true" ]; then
	        docker stop "${CONTAINER_NAME}" >/dev/null
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

# Permanently delete a profile and every trace of it: the container, its image,
# BOTH volumes (including ~/work), and the ~/warp/<profile> directory.
# Requires typing the name to confirm.
destroy profile=default_profile:
	#!/usr/bin/env bash
	set -euo pipefail
	profile_dir="$HOME/warp/{{profile}}"
	if [ ! -d "$profile_dir" ]; then
	  printf '\033[31mNo such profile: %s\033[0m\n' "{{profile}}" >&2
	  exit 1
	fi
	container_name="warp-{{profile}}"
	image_name=""
	work_volume="warp-{{profile}}-work"
	docker_volume="warp-{{profile}}-docker"
	if [ -f "$profile_dir/profile.env" ]; then
	  set -a; . "$profile_dir/profile.env"; set +a
	  container_name="${CONTAINER_NAME:-$container_name}"
	  image_name="${IMAGE_NAME:-}"
	  work_volume="${WORK_VOLUME:-$work_volume}"
	  docker_volume="${DOCKER_VOLUME:-$docker_volume}"
	fi
	printf '\033[1;31mAbout to permanently delete profile "%s":\033[0m\n' "{{profile}}"
	printf '  container : %s\n' "${container_name}"
	printf '  image     : %s\n' "${image_name:-<none>}"
	printf '  volumes   : %s \033[1;31m(your ~/work)\033[0m, %s\n' "${work_volume}" "${docker_volume}"
	printf '  directory : %s\n' "${profile_dir}"
	printf '\033[2m%s\033[0m\n' "Everything in ~/work is deleted with the volume. Back it up first with: just backup {{profile}}"
	printf 'Type the profile name (%s) to confirm: ' "{{profile}}"
	read -r reply
	if [ "$reply" != "{{profile}}" ]; then
	  printf '\033[33mName did not match - aborted. Nothing was deleted.\033[0m\n' >&2
	  exit 1
	fi
	docker rm -f "${container_name}" >/dev/null 2>&1 || true
	docker volume rm "${work_volume}" "${docker_volume}" >/dev/null 2>&1 || true
	if [ -n "${image_name}" ] && docker image inspect "${image_name}" >/dev/null 2>&1; then
	  docker image rm "${image_name}" >/dev/null 2>&1 \
	    || printf '\033[33mNote: could not delete image %s (it may be in use).\033[0m\n' "${image_name}"
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
	@mkdir -p ~/warp
	@"{{justfile_directory()}}/lib/status.sh"

install-deps:
	npm install

# End-to-end check on a throwaway profile: build, open, docker-in-docker,
# rebuild-keeps-work, backup/restore, SSH, restart. Cleans up after itself.
smoke name='smoketest' *flags:
	"{{justfile_directory()}}/lib/smoke.sh" '{{name}}' {{flags}}
