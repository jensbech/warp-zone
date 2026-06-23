# Dev container profiles

Spin up isolated Ubuntu dev environments using Apple's [`container`](https://github.com/apple/container) runtime (macOS). Each **profile** is a reusable container with your chosen tools — repos and credentials stay inside it, so your host stays clean.

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

`profile` defaults to `work-ubuntu` when omitted. Profiles are stored in `~/container/<name>`.

## What's inside

The wizard asks for a name and which tools to include. Available tool groups:

Node.js · .NET SDK · Azure CLI · Pulumi · kubectl · GitHub CLI · jira · k9s · Python 3

Always included: git, ripgrep, jq, fzf, bat, eza, tmux, zsh.

Your dotfiles (`~/proj/pers/dotfiles` by default) are mounted read-only at `/mnt/dotfiles`. Work in `~/work` inside the container.

## Requirements

- macOS with Apple's `container` CLI installed
- [`just`](https://github.com/casey/just)
- Node.js (the wizard installs its own dependencies on first run)

## Customizing a profile

Need a different user, CPU/memory, or dotfiles path? Choose **advanced settings** in the wizard, or edit `~/container/<name>/profile.env` afterwards and run `just rebuild <name>`.
