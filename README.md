# warp-zone 🌀

Jump from macOS into a Linux dev world. `warp-zone` spins up isolated Linux dev environments using Apple's [`container`](https://github.com/apple/container) runtime — step in on your Mac, pop out in Linux.

Each **profile** is a reusable container with your chosen distro and tools — repos and credentials stay inside it, so your host stays clean.

## Quick start

```bash
just new          # create a profile (interactive)
just open         # build it and drop into a shell
```

That's it. `just open` builds the image the first time, then re-enters the same container on later runs.

## Commands

Run `just` to see the menu.

| Command | What it does |
| --- | --- |
| `just new` | Create a profile with the setup wizard |
| `just up <recipe> [name]` | Create a profile from a recipe (if needed) and enter it |
| `just new-from <recipe> [name]` | Create a profile from a saved recipe (without entering) |
| `just recipes` | List saved recipes |
| `just save [profile] [recipe]` | Save a profile's setup as a recipe |
| `just open [profile]` | Build (if needed) and enter a profile |
| `just ssh [profile]` | SSH into a profile (when SSH is enabled) |
| `just run <profile> <cmd>` | Run a one-off command in a profile |
| `just forward <port> [profile] [local]` | Forward a container port to localhost (needs SSH) |
| `just doctor` | Check host tools, disk, profiles, and containers for problems |
| `just list` | List your profiles |
| `just status [profile]` | Show profile state, resources, SSH, and backup usage |
| `just` / `warp` | Show your profiles and all commands |
| `just start/stop/restart [profile]` | Control a container without changing its state |
| `just backup/restore [profile]` | Save or restore the container's `~/work` directory |
| `just configure [profile]` | Change a profile's settings with the wizard |
| `just install-global` | Install `warp` so commands work from any directory |
| `just build [profile]` | Build the image only |
| `just rebuild [profile]` | Rebuild image and recreate the container |
| `just update [profile]` | Update OS/apt packages inside a container |
| `just update-all` | Update OS/apt packages in every container, in parallel |
| `just logs [profile]` | Show a container's logs |
| `just prune` | Remove stopped containers and unused images |
| `just destroy [profile]` | Permanently delete a profile, its container, and image |

`profile` defaults to `dev` when omitted; each profile lives in `~/container/<name>`.

After `just install-global`, run `warp` for a profile overview and common commands or `warp help` for help. `warp open`, `warp manage`, and every other command work from anywhere. The installer writes `~/.local/bin/warp` and adds that directory to your shell PATH when needed.

The profile name is the **only name you pick** — the container, its image, and your Linux username inside it all default to it (so the `dev` profile logs you in as `dev`).

## What's inside

The wizard asks for a name, a base distro, and which optional tools to include.

- **Distro:** Ubuntu 24.04 LTS (default), Ubuntu 22.04 LTS, or Debian 12.
- **Always included:** git, ripgrep, jq, fzf, bat, eza, tmux, zsh.
- **Optional tool groups (off by default):**
  - *Languages & runtimes:* Node.js · Python 3 · Go · Rust · .NET SDK · Java · Ruby · Bun · Deno
  - *Cloud & infrastructure:* Docker CLI · kubectl · Helm · k9s · Terraform · Pulumi · AWS CLI · Azure CLI · Google Cloud CLI
  - *Databases:* PostgreSQL client · MySQL/MariaDB client · Redis CLI · SQLite
  - *CLI utilities:* GitHub CLI · jira · Neovim · lazygit · git-delta · yq · direnv · HTTPie · btop

The default is a **minimal base** — leave every tool group unchecked and you get a clean Linux box with just the essentials above. Add tool groups only when you need them.

## Recipes — declarative setups

A **recipe** is a saved, declarative profile setup — distro, tool groups, pinned versions, extra packages — stored in this repo under `recipes/<name>.env` so your setups are versioned in git and reproducible on demand:

```bash
just recipes                  # list saved recipes (with settings and validation)
just up node-web api          # create profile "api" from the node-web recipe and enter it
just save api my-stack        # save an existing profile's setup as a recipe
just up my-stack              # ...and spin it up again anywhere, any time
```

Saved recipes also appear as **starting points in the `just new` wizard**, so you can begin from a recipe and tweak it interactively. A recipe uses the same `KEY='value'` format as `profile.env`, minus the instance-specific keys (profile/container/image name, Linux user, SSH alias and key) — those derive from the profile name you pick. A leading `# description: ...` line is shown by `just recipes`, which also flags unrecognized keys so typos don't silently make it into builds.

Beyond the tool toggles, a recipe (or any `profile.env`) can make the setup highly specific:

- **Version pins** — override the image's build args, e.g. `NODE_MAJOR='22'`, `GO_VERSION='1.24.4'`, `KUBECTL_VERSION='v1.36.2'`, `K9S_VERSION`, `PNPM_VERSION`, `YARN_VERSION`, `PULUMI_VERSION`, `LAZYGIT_VERSION`, `DELTA_VERSION`, `YQ_VERSION`.
- **Extra packages** — `EXTRA_APT_PACKAGES='postgresql-16 imagemagick'` installs additional distro packages at build time.
- **Build hook** — every profile has a `~/container/<name>/setup.sh` that runs as root at the end of the image build, like the `RUN` lines of a Dockerfile, for anything the flags can't express. `just save` stores it with the recipe as `recipes/<name>.setup.sh`, and `just new-from` copies it into profiles created from that recipe.

## Staying current

- Every `just build` pulls the latest base image and applies OS updates, so a freshly built image starts patched.
- `just update [profile]` upgrades all OS/apt packages (and `rustup`, if present) inside a running container.
- Tools pinned to a version at build time (Go, Bun, Deno, kubectl, k9s, lazygit, git-delta, yq, AWS CLI) refresh when you `just rebuild`.

By default a profile gets **2 CPU cores and 8G RAM**. Choose all available resources in the wizard or set `CPUS` / `MEMORY` to `max` when a workload needs more. Work in `~/work` inside the container.

## Backups and rebuilds

`just rebuild` replaces the container, so it offers to back up `~/work` first. Backups are stored indefinitely in `~/container/<name>/backups`. Use `just backup <name>` at any time and `just restore <name>` to replace the profile's `~/work` with a selected backup. To cap how many backups a profile keeps, set `BACKUP_KEEP=<n>` in its `profile.env` — each new backup then prunes all but the newest *n*.

## Host separation

A profile is **hermetic by default** — nothing from your Mac is mounted, and credentials and repos live only inside the container.

The wizard can optionally open one read-only window to the host: pick **"Link host dotfiles"**, choose a directory (default `~/proj/pers/dotfiles`, mounted read-only at `/mnt/dotfiles`), and tick which pieces to bring in:

- **Git identity** — your `user.name` / `user.email`, copied into the container's `~/.gitconfig`.
- **Claude config** — `settings.json` and `CLAUDE.md`.
- **opencode config** — `opencode.json` and `AGENTS.md`.
- **GitHub Copilot instructions** — `copilot.instructions.md`.

Each linked file is a read-only symlink, so the container can never modify your host. Leave the option off and the profile stays completely sealed. (Shell config — `.zshrc` etc. — always comes from the image template, never the host. To customize the shell inside a container, put your additions in `~/.zshrc.local` or `~/.bashrc.local` — those survive every re-open, as do any `git config` changes you make inside the container.)

## SSH & VS Code Remote

Answer **yes** to *"Enable SSH access"* in the wizard to make a profile reachable over SSH. It then asks:

- **SSH host alias** — what you'll type as `ssh <alias>` on your Mac (defaults to the profile name).
- **Public key** — a path on your Mac (default `~/.ssh/id_ed25519.pub`). If that file doesn't exist, any keys found in `~/.ssh/*.pub` are authorized instead. Password login is always disabled.

Then:

```bash
just open myprofile   # builds, authorizes your key(s), runs sshd, writes ~/.ssh/config
just ssh myprofile    # or just: ssh <alias>
```

**No host networking, IPs, or DNS required.** The SSH connection is tunnelled through `container exec` (via a `ProxyCommand` in your `~/.ssh/config`), so it works regardless of the container's IP and even cold-starts the container on connect. In **VS Code**, use **Remote-SSH → Connect to Host → `<alias>`**.

`sshd` runs as part of the container's command, so it comes back automatically whenever the container starts (e.g. after a host reboot). You need a public key on your Mac — if you don't have one, run `ssh-keygen -t ed25519` and re-open the profile.

## Requirements

- macOS with Apple's `container` CLI installed
- [`just`](https://github.com/casey/just)
- Node.js (the wizard installs its own dependencies on first run)

## Customizing a profile

Need a different user, CPU/memory, or host-dotfiles setup? Use the wizard (**advanced settings** for user/CPU/memory; the **"Link host dotfiles"** prompt for `DOTFILES_DIR` and the `LINK_*` toggles), or edit `~/container/<name>/profile.env` afterwards and run `just rebuild <name>`. Set `CPUS`/`MEMORY` to `max` for full host resources, or a fixed value like `8` / `16G` to cap them. Set `DOTFILES_DIR=""` for a fully hermetic profile.
