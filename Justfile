set shell := ["bash", "-euo", "pipefail", "-c"]

default_profile := "dev"
profiles_root := env_var_or_default('HOME', '') + "/warp"

default:
	@"{{justfile_directory()}}/lib/menu.sh" just

alias create-profile := new
alias create-profile-default := new-default
alias list-profiles := list
alias delete := destroy

setup:
	"{{justfile_directory()}}/setup.sh"

new name='':
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{justfile_directory()}}"
	name="{{name}}"
	if [ -n "$name" ]; then
	  exec ./cli/create-profile.sh --dir "$name"
	fi
	exec ./cli/create-profile.sh

new-default name:
	./cli/create-profile.sh --dir {{name}} --yes

new-from recipe name='':
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{justfile_directory()}}"
	name="{{name}}"
	./cli/create-profile.sh --recipe '{{recipe}}' --dir "${name:-{{recipe}}}" --yes

# Save a profile's setup as a recipe. Local by default (~/.config/warp-zone/recipes);
# add `shared` as the last argument to write into this repo's recipes/ instead.
save profile=default_profile name='' scope='':
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{justfile_directory()}}"
	name="{{name}}"
	scope="{{scope}}"
	if [ "$name" = "shared" ] || [ "$name" = "--shared" ]; then
	  name=""
	  scope="shared"
	fi
	shared=()
	case "$scope" in
	  shared|--shared) shared=(--shared) ;;
	  '') ;;
	  *) printf 'Unknown option "%s" (use: shared)\n' "$scope" >&2; exit 1 ;;
	esac
	./cli/create-profile.sh --export "${name:-{{profile}}}" --dir '{{profile}}' ${shared[@]+"${shared[@]}"}

recipes:
	@./cli/create-profile.sh --list-recipes

forget-recipe name:
	./cli/create-profile.sh --forget '{{name}}'

up recipe name='':
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{justfile_directory()}}"
	name="{{name}}"
	name="${name:-{{recipe}}}"
	if [ ! -d "$HOME/warp/$name" ]; then
	  ./cli/create-profile.sh --recipe '{{recipe}}' --dir "$name" --yes
	fi
	just --justfile "{{justfile()}}" open "$name"

configure profile=default_profile:
	./cli/create-profile.sh --dir {{profile}} --configure

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
	cp "$src/template/Dockerfile" "$src/template/.dockerignore" "$src/template/catalog.json" "$src/template/install-tools.sh" "$src/template/bootstrap-home" "$src/template/warp-init" "$src/template/tailnet" "$src/template/build.sh" "$src/template/open.sh" "$src/template/rebuild.sh" "$src/template/ssh.sh" "$dir/"
	mkdir -p "$dir/templates" "$dir/lib"
	cp "$src/template/templates/.bashrc" "$src/template/templates/.zshenv" "$src/template/templates/.zshrc" "$dir/templates/"
	cp "$src/lib/helpers.sh" "$src/lib/backup.sh" "$src/lib/restore.sh" "$dir/lib/"
	if [ ! -f "$dir/setup.sh" ]; then
	  cp "$src/template/setup.sh" "$dir/setup.sh"
	fi
	chmod +x "$dir/build.sh" "$dir/open.sh" "$dir/rebuild.sh" "$dir/ssh.sh" "$dir/bootstrap-home" "$dir/warp-init" "$dir/tailnet" "$dir/lib/"*.sh

build profile=default_profile: (_sync profile)
	~/warp/{{profile}}/build.sh

open profile=default_profile: (_sync profile)
	~/warp/{{profile}}/open.sh

rebuild profile=default_profile: (_sync profile)
	~/warp/{{profile}}/rebuild.sh

start profile=default_profile:
	@"{{justfile_directory()}}/lib/container.sh" start '{{profile}}'

stop profile=default_profile:
	@"{{justfile_directory()}}/lib/container.sh" stop '{{profile}}'

restart profile=default_profile:
	@"{{justfile_directory()}}/lib/container.sh" restart '{{profile}}'

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

# Reach a port that something inside the profile is listening on. Accepts one
# port, a comma-separated list, or a range (4663-4673). A single port may be
# remapped locally: `just forward 3000 dev 8080`.
forward ports profile=default_profile local_port='':
	@"{{justfile_directory()}}/lib/forward.sh" '{{ports}}' '{{profile}}' '{{local_port}}'

t3 profile=default_profile mode='open':
	@"{{justfile_directory()}}/lib/t3code.sh" '{{profile}}' '{{mode}}'

run profile +cmd:
	@"{{justfile_directory()}}/lib/container.sh" run '{{profile}}' {{quote(cmd)}}

logs profile=default_profile:
	@"{{justfile_directory()}}/lib/container.sh" logs '{{profile}}'

prune:
	"{{justfile_directory()}}/lib/prune.sh"

install-global:
	"{{justfile_directory()}}/cli/install-warp.sh"

# Update all OS/apt packages (and rustup, if present) inside a running container.
# Tools pinned to a version at build time (Go, Bun, Deno, kubectl, ...) refresh via `just rebuild`.
update profile=default_profile:
	@"{{justfile_directory()}}/lib/update.sh" '{{profile}}'

# Update OS/apt packages in every profile's container, all in parallel.
# Output is captured per profile and printed grouped once all finish.
update-all:
	@"{{justfile_directory()}}/lib/update.sh" --all

# Permanently delete a profile and every trace of it: the container, its image,
# BOTH volumes (including ~/work), and the ~/warp/<profile> directory.
# Requires typing the name to confirm.
destroy profile=default_profile:
	@"{{justfile_directory()}}/lib/destroy.sh" '{{profile}}'

list:
	@mkdir -p ~/warp
	@"{{justfile_directory()}}/lib/status.sh"

# End-to-end check on a throwaway profile: build, open, docker-in-docker,
# rebuild-keeps-work, backup/restore, SSH, restart. Cleans up after itself.
smoke name='smoketest' *flags='':
	"{{justfile_directory()}}/lib/smoke.sh" '{{name}}' {{flags}}
