set shell := ["bash", "-euo", "pipefail", "-c"]

default_profile := "work-ubuntu"
profiles_root := env_var_or_default('HOME', '') + "/container"

default:
	@printf '\033[1;36m%s\033[0m\n' '🌀 warp-zone'
	@printf '\033[2m%s\033[0m\n\n' 'Jump from macOS into a Linux world · profiles in ~/container · default: work-ubuntu'
	@printf '\033[1m%s\033[0m\n' 'Get started'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just new' 'Create a profile (interactive wizard)'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just open [profile]' 'Build (if needed) and enter a profile'
	@printf '\n\033[1m%s\033[0m\n' 'Manage'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just list' 'List your profiles'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just build [profile]' 'Build the image only'
	@printf '  \033[1;32m%-26s\033[0m \033[2m%s\033[0m\n' 'just rebuild [profile]' 'Rebuild image and recreate container'
	@printf '\n\033[2m%s\033[0m\n' 'Tip: profile defaults to "work-ubuntu" when omitted.'

alias create-profile := new
alias create-profile-default := new-default
alias list-profiles := list

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
