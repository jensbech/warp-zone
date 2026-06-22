set shell := ["bash", "-euo", "pipefail", "-c"]

default_profile := "work-ubuntu"
profiles_root := env_var_or_default('HOME', '') + "/container"

default:
	@printf '\033[1;36m%s\033[0m\n' 'Container setup'
	@printf '\033[2m%s\033[0m\n' 'Default profile: work-ubuntu'
	@printf '\033[2m%s\033[0m\n\n' 'Profiles path: ~/container'
	@printf '  \033[1;32m%-34s\033[0m \033[2m%s\033[0m\n' 'just create-profile' 'Interactive profile wizard'
	@printf '  \033[1;32m%-34s\033[0m \033[2m%s\033[0m\n' 'just create-profile-default <name>' 'Create a profile with defaults'
	@printf '  \033[1;32m%-34s\033[0m \033[2m%s\033[0m\n' 'just list-profiles' 'Show available profiles'
	@printf '  \033[1;32m%-34s\033[0m \033[2m%s\033[0m\n' 'just build [profile]' 'Build profile image'
	@printf '  \033[1;32m%-34s\033[0m \033[2m%s\033[0m\n' 'just open [profile]' 'Start and enter profile'
	@printf '  \033[1;32m%-34s\033[0m \033[2m%s\033[0m\n' 'just rebuild [profile]' 'Rebuild and recreate profile'
	@printf '  \033[1;32m%-34s\033[0m \033[2m%s\033[0m\n' 'just install-deps' 'Install Node CLI dependencies'

create-profile:
	./create-profile.sh

create-profile-default name:
	./create-profile.sh --dir {{name}} --yes

build profile=default_profile:
	~/container/{{profile}}/build.sh

open profile=default_profile:
	~/container/{{profile}}/open.sh

rebuild profile=default_profile:
	~/container/{{profile}}/rebuild.sh

list-profiles:
	mkdir -p ~/container
	for dir in ~/container/*/; do \
	  [ -d "$dir" ] || continue; \
	  if [ -f "$dir/profile.env" ]; then \
	    printf '%s\n' "${dir%/}"; \
	  fi; \
	done

install-deps:
	npm install
