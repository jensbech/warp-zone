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
| `just ssh [profile]` | SSH into a profile (when SSH is enabled) |
| `just list` | List your profiles |
| `just build [profile]` | Build the image only |
| `just rebuild [profile]` | Rebuild image and recreate the container |
| `just update [profile]` | Update OS/apt packages inside a running container |
| `just update-all` | Update OS/apt packages in every container, in parallel |
| `just destroy [profile]` | Permanently delete a profile, its container, and image |

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

By default a profile gets **all host CPU cores and RAM**. Work in `~/work` inside the container.

## Host separation

A profile is **hermetic by default** — nothing from your Mac is mounted, and credentials and repos live only inside the container.

The wizard can optionally open one read-only window to the host: pick **"Link host dotfiles"**, choose a directory (default `~/proj/pers/dotfiles`, mounted read-only at `/mnt/dotfiles`), and tick which pieces to bring in:

- **Git identity** — your `user.name` / `user.email`, copied into the container's `~/.gitconfig`.
- **Claude config** — `settings.json` and `CLAUDE.md`.
- **opencode config** — `opencode.json` and `AGENTS.md`.
- **GitHub Copilot instructions** — `copilot.instructions.md`.

Each linked file is a read-only symlink, so the container can never modify your host. Leave the option off and the profile stays completely sealed. (Shell config — `.zshrc` etc. — always comes from the image template, never the host.)

## SSH & VS Code Remote

Tick **OpenSSH server** in the wizard to make a profile reachable over SSH. When you enable it, the wizard asks two things:

- **SSH host alias** — what you'll type as `ssh <alias>` on your Mac (defaults to the profile name).
- **Public key** — a path on your Mac (default `~/.ssh/id_ed25519.pub`); only that key is authorized (password login is disabled).

Then:

```bash
just open myprofile   # builds, authorizes your key, starts sshd, writes ~/.ssh/config
just ssh myprofile    # or just: ssh <alias>
```

`just open` (and `just ssh`) write a managed block into your `~/.ssh/config` pointing the alias at `<container>.test` — Apple's `container` runtime resolves each container by name on the `.test` domain, so the alias keeps working even if the container's IP changes. In **VS Code**, use **Remote-SSH → Connect to Host → `<alias>`**.

> If `<container>.test` doesn't resolve on your macOS version, set up the local resolver once with `container system dns create test`.

## Requirements

- macOS with Apple's `container` CLI installed
- [`just`](https://github.com/casey/just)
- Node.js (the wizard installs its own dependencies on first run)

## Customizing a profile

Need a different user, CPU/memory, or host-dotfiles setup? Use the wizard (**advanced settings** for user/CPU/memory; the **"Link host dotfiles"** prompt for `DOTFILES_DIR` and the `LINK_*` toggles), or edit `~/container/<name>/profile.env` afterwards and run `just rebuild <name>`. Set `CPUS`/`MEMORY` to `max` for full host resources, or a fixed value like `8` / `16G` to cap them. Set `DOTFILES_DIR=""` for a fully hermetic profile.
