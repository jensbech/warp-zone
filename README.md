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
| `just open [profile]` | Build (if needed) and enter a profile |
| `just list` | List your profiles |
| `just build [profile]` | Build the image only |
| `just rebuild [profile]` | Rebuild image and recreate the container |
| `just update [profile]` | Update OS/apt packages inside a running container |

`profile` defaults to `dev` when omitted. Profiles are stored in `~/container/<name>`.

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

## Staying current

- Every `just build` pulls the latest base image and applies OS updates, so a freshly built image starts patched.
- `just update [profile]` upgrades all OS/apt packages (and `rustup`, if present) inside a running container.
- Tools pinned to a version at build time (Go, Bun, Deno, kubectl, k9s, lazygit, git-delta, yq, AWS CLI) refresh when you `just rebuild`.

By default a profile gets **all host CPU cores and RAM**. Your dotfiles (`~/proj/pers/dotfiles` by default) are mounted read-only at `/mnt/dotfiles`. Work in `~/work` inside the container.

## Requirements

- macOS with Apple's `container` CLI installed
- [`just`](https://github.com/casey/just)
- Node.js (the wizard installs its own dependencies on first run)

## Customizing a profile

Need a different user, CPU/memory, or dotfiles path? Choose **advanced settings** in the wizard, or edit `~/container/<name>/profile.env` afterwards and run `just rebuild <name>`. Set `CPUS`/`MEMORY` to `max` for full host resources, or a fixed value like `8` / `16G` to cap them.
