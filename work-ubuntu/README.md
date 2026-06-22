# Work Container Profile

This directory defines the reusable Ubuntu work container template.

It is designed to keep repos, credentials, and per-tool state inside the container while only mounting `~/proj/pers/dotfiles` from the host.

## Tooling

- Node.js 24
- corepack with pnpm and yarn
- .NET SDK 8 and 10
- Azure CLI
- Pulumi CLI
- kubectl
- GitHub CLI
- jira CLI
- k9s
- Python 3
- git, ripgrep, jq, fzf, bat, eza, tmux, zsh

## Host mount

- `~/proj/pers/dotfiles` is mounted read-only at `/mnt/dotfiles`

## Container behavior

- repos are meant to be cloned into `~/work` inside the container
- credentials are not mounted from macOS
- the container filesystem keeps its own state until you delete the container
- each launch re-applies a Linux-safe shell and selected dotfiles-driven config

## Usage

Create a new profile interactively:

```bash
../create-profile.sh
```

Generated profiles are stored in `~/container`.

Build the image:

```bash
./build.sh
```

Create, start, bootstrap, and enter the container:

```bash
./open.sh
```

Rebuild the image, recreate the container, and enter it:

```bash
./rebuild.sh
```

## Profile settings

Edit `profile.env` in this directory to change:

- profile name
- image and container name
- default Linux username
- CPU and memory allocation
- dotfiles mount path
- included tool groups
