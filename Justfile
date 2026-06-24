set shell := ["bash", "-euo", "pipefail", "-c"]

default_profile := "dev"
profiles_root := env_var_or_default('HOME', '') + "/container"

default:
	@printf '\033[1;36m%s\033[0m\n' '🌀 warp-zone'
	@printf '\033[2m%s\033[0m\n\n' 'Jump from macOS into a Linux world · profiles in ~/container · default: dev'
	@printf '\033[1m%s\033[0m\n' 'Get started'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just new' 'Create a profile (interactive wizard)'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just open [profile]' 'Build (if needed) and enter a profile'
	@printf '\n\033[1m%s\033[0m\n' 'Manage'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just list' 'List your profiles'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just build [profile]' 'Build the image only'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just rebuild [profile]' 'Rebuild image and recreate container'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just update [profile]' 'Update OS packages in a running container'
	@printf '  \033[1;31m%-26s\033[0m \033[2m%s\033[0m\n' 'just destroy [profile]' 'Delete a profile, its container, and image'
	@printf '\n\033[2m%s\033[0m\n' 'Tip: profile defaults to "dev" when omitted.'

alias create-profile := new
alias create-profile-default := new-default
alias list-profiles := list
alias delete := destroy

new:
	./create-profile.sh

new-default name:
	./create-profile.sh --dir {{name}} --yes

build profile=default_profile:
	~/container/{{profile}}/build.sh

open profile=default_profile:
	~/container/{{profile}}/open.sh

rebuild profile=default_profile:
	~/container/{{profile}}/rebuild.sh

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
	if ! container list -q | grep -Fxq "${CONTAINER_NAME}"; then
	  container start "${CONTAINER_NAME}" >/dev/null
	fi
	printf '\033[1;36mUpdating OS packages in %s...\033[0m\n' "${CONTAINER_NAME}"
	container exec "${CONTAINER_NAME}" sudo env DEBIAN_FRONTEND=noninteractive bash -c \
	  'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge && apt-get clean'
	container exec "${CONTAINER_NAME}" bash -lc 'command -v rustup >/dev/null 2>&1 && rustup update || true'
	printf '\033[1;32m%s is up to date\033[0m\n' "${CONTAINER_NAME}"

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
	rm -rf "$profile_dir"
	printf '\033[1;32mDeleted profile "%s" and all its traces.\033[0m\n' "{{profile}}"

list:
	@mkdir -p ~/container
	@found=0; \
	for dir in ~/container/*/; do \
	  [ -f "$dir/profile.env" ] || continue; \
	  found=1; \
	  printf '\033[1;32m%s\033[0m\n' "$(basename "${dir%/}")"; \
	done; \
	if [ "$found" = 0 ]; then \
	  printf '\033[2m%s\033[0m\n' 'No profiles yet — run: just new'; \
	fi

install-deps:
	npm install
