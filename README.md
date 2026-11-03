# warp-zone

Isolated Linux dev containers on Docker. Each **profile** is a reusable container (Ubuntu or Debian) with the tools you pick; repos and credentials stay inside it, so your host stays clean. Every profile runs its own Docker engine (docker-in-docker), so `docker`, `compose`, `buildx` and testcontainers work inside without touching your host's daemon. Works on macOS and Linux.

## Requirements

| | macOS | Linux |
| --- | --- | --- |
| Docker | Docker Desktop, OrbStack or Colima | Docker Engine (native dockerd); your user in the `docker` group |
| [just](https://just.systems) | any recent (`brew install just`) | 1.21 or newer |
| Node.js | 18+ | 18+ |

`./setup.sh` checks all of this (with install hints for your OS), runs `npm ci`, and installs the global `warp` command.

## Quick start

```bash
./setup.sh      # once: checks prerequisites, installs deps and `warp`
just new        # wizard: name, start from, tools
just open       # build on first run, then drop into a shell
```

Anywhere after setup, `warp` is the same as `just` (`warp open`, `warp new`, ...). Profiles live in `~/warp/<name>`; `profile` defaults to `dev`.

## Commands

Run `just` (or `warp`) for a menu. `[profile]` defaults to `dev`.

| Group | Command | What it does |
| --- | --- | --- |
| Everyday | `just new [name]` | Create a profile with the wizard |
| | `just new-default <name>` | Create a minimal profile, no questions |
| | `just open [profile]` | Build if needed and enter |
| | `just ssh [profile]` | SSH in (needs SSH enabled) |
| | `just run <profile> <cmd...>` | Run one command in a profile |
| | `just forward <ports> [profile] [local_port]` | Reach in-profile ports from the host |
| | `just list` / `just status [profile]` | Profiles at a glance / detail for one |
| | `just start\|stop\|restart [profile]` | Control the container |
| | `just logs [profile]` | Container logs |
| Profiles & recipes | `just configure [profile]` | Re-run the wizard on a profile |
| | `just recipes` | List recipes (local and shared) |
| | `just up <recipe> [name]` | Create from a recipe if needed, then enter |
| | `just new-from <recipe> [name]` | Create from a recipe, don't enter |
| | `just save [profile] [name] [shared]` | Save a profile as a recipe |
| | `just forget-recipe <name>` | Delete a local recipe |
| Maintenance | `just build\|rebuild [profile]` | Build the image / rebuild and recreate the container |
| | `just update [profile]` / `just update-all` | Upgrade OS packages inside container(s) |
| | `just backup\|restore [profile]` | Back up / restore `~/work` |
| | `just destroy [profile]` | Delete container, image, volumes and `~/work` (asks for the name) |
| | `just doctor` | Check host, Docker, disk and profiles |
| | `just prune` | Reclaim dangling images and leftovers |
| | `just smoke [name]` | End-to-end self-test on a throwaway profile |
| | `just setup` / `just install-global` | Run setup / (re)install `warp` |

Docker names are the profile name with a `warp-` prefix (container `warp-dev`, volumes `warp-dev-work` and `warp-dev-docker`) and carry a `com.warp-zone.profile` label, so warp-zone only touches its own resources. The Linux user inside defaults to the profile name; work in `~/work`.

## Tools and the catalog

Always installed: git, ripgrep, jq, fzf, bat, eza, tmux, zsh, Claude Code and the Docker engine. Everything else comes from `template/catalog.json` (about 268 tools: languages, cloud and Kubernetes CLIs, databases, editors, linters, AI CLIs, ...).

- **Search:** in the wizard's picker, type to filter, arrows to move, space to toggle, enter to confirm, Ctrl-U to clear. Text that matches nothing can be added as an extra distro package.
- **Configure:** `profile.env` holds `TOOLS='node gh psql'` (catalog ids) and `EXTRA_APT_PACKAGES='imagemagick'`. Legacy `INCLUDE_<TOOL>='true'` flags still work. Apply changes with `just rebuild`.
- **Pin:** `<ID>_VERSION='1.2.3'` pins any release tool (e.g. `GO_VERSION`, `KUBECTL_VERSION`); `NODE_MAJOR='22'` picks the Node line. Unpinned tools install the latest at build time.
- **Add a tool:** add an entry to `template/catalog.json` (id, label, group, keywords, check, install) and run `node tests/catalog-check.mjs`.
- **Anything else:** `~/warp/<name>/setup.sh` runs as root at the end of every build, like extra `RUN` lines.

## Recipes

A recipe is a saved profile setup (distro, tools, pins, extra packages, build hook) in the same `KEY='value'` format as `profile.env`. Recipes appear as starting points in the wizard.

- **Local** (default): `${XDG_CONFIG_HOME:-~/.config}/warp-zone/recipes`, private to you. `just save dev my-stack`.
- **Shared**: `recipes/` in this repo, committed. `just save dev my-stack shared`.
- A local recipe wins over a shared one with the same name; `just recipes` shows which is which.

```bash
just save api my-stack
just up my-stack second     # new profile "second" from it, then enter
```

## Docker inside a profile

The engine is nested, not shared: containers started inside a profile are invisible to the host and to other profiles. The cost is `--privileged` and a per-profile image cache (volume `warp-<name>-docker`, kept across `rebuild`, removed by `destroy`).

Ports published inside a profile bind to the profile, not the host. Bridge them over SSH (enable SSH first with `just configure`):

```bash
just forward 3000 dev                  # one port
just forward 4663,4664,4669-4673 dev   # list and ranges
just forward 3000 dev 8080             # localhost:8080 -> profile:3000
```

If the inner engine cannot pull images but the host can, it is usually MTU (VPNs). Set `DOCKERD_ARGS='--mtu 1420'` in `profile.env` and `just rebuild`; `just doctor` flags this.

## SSH and VS Code

Enable SSH in the wizard; give it a host alias and a public key (default `~/.ssh/id_ed25519.pub`, falling back to any `~/.ssh/*.pub`). Password login is off. `just open` authorizes the key and writes `~/.ssh/config`; then `just ssh`, `ssh <alias>`, scp, rsync and VS Code Remote-SSH all work. sshd is published on `127.0.0.1:<SSH_PORT>` (from 2200 up, assigned at creation, recorded in `profile.env`).

## Backups and rebuilds

`~/work` is on a named volume, so `just rebuild` never touches it, nor the profile's Docker state. `just backup` writes a tarball to `~/warp/<name>/backups` (cap with `BACKUP_KEEP=<n>`); `just restore` replaces `~/work` from one. Only `just destroy` deletes the volumes.

`just update` upgrades OS packages in place; `just rebuild` pulls a fresh base image and refreshes unpinned tools. Resources default to 2 CPUs and 8G; set `CPUS` / `MEMORY` (or `max`) in `profile.env`.

## Host separation and dotfiles

Profiles are hermetic by default: nothing from the host is mounted. The wizard can mount one directory read-only at `/mnt/dotfiles` (`DOTFILES_DIR`) and symlink git identity, Claude config, opencode config and Copilot instructions from it (`LINK_*` flags). Shell config always comes from the image; put personal additions in `~/.zshrc.local` or `~/.bashrc.local`.

## macOS and Linux

- **macOS:** Docker runs in a VM, so `max` CPU/memory means the VM's allocation and its disk fills faster (`just doctor` reports reclaimable space).
- **Linux:** native dockerd; `max` means the whole host. Your user needs the `docker` group. Distro `docker.io` without buildx falls back to the legacy builder. `just doctor` also checks the socket, buildx, cgroup v2 and MTU.

## Development

```
cli/        wizard (create-profile.mjs, tool-picker.mjs) and launchers
lib/        bash helpers behind the Justfile; some are copied into each profile
template/   files stamped into every profile, plus catalog.json
recipes/    shared recipes
tests/      see below
```

| Test | Run |
| --- | --- |
| Catalog consistency (`--online` also checks URLs) | `node tests/catalog-check.mjs` |
| Picker fuzzy matching | `node tests/fuzzy.test.mjs` |
| Linux host in a container (real dockerd: `doctor` + `smoke`) | `tests/linux/run.sh` |
| Wizard end to end (needs `expect`) | `tests/wizard.sh` |
| Tools actually install (long) | `tests/verify-tools.sh`, `tests/catalog-apt.sh` |
| Full flow on a throwaway profile | `just smoke` |
