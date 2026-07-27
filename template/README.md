# Profile template

This directory is the **template** that `just new` stamps into every profile. When
you create a profile, these files are copied to `~/container/<name>/`, and a
`profile.env` is generated there from your wizard answers.

You normally never edit files here — use `just new` to create profiles and edit
`~/container/<name>/profile.env` to tweak an existing one. This directory matters
only when you want to change the template itself for all *future* profiles.

## What's in here

| File | Role |
| --- | --- |
| `Containerfile` | Image definition. Installs the always-on tools plus any `INCLUDE_*` tool group. |
| `profile.env` | Example profile settings (minimal + hermetic). Each generated profile gets its own copy. |
| `bootstrap-home` | Runs on every `open`: sets up the home dir, shell, git defaults, optional dotfile links, and SSH. |
| `build.sh` / `open.sh` / `rebuild.sh` / `ssh.sh` | The scripts `just build/open/rebuild/ssh` call for a profile. |
| `templates/` | Shell config (`.zshrc`, `.zshenv`, `.bashrc`) installed into the container's home. |

## Running the template directly

The template is self-contained, so you can build and enter it in place using the
settings in `profile.env` (handy when hacking on the template itself):

```bash
./build.sh    # build the image
./open.sh     # create, start, bootstrap, and enter the container
./rebuild.sh  # rebuild the image and recreate the container
```

## How a profile is configured

Everything is driven by `profile.env`. See the top-level
[README](../README.md) for the full list of settings and tool groups; the short
version:

- **Names** — you pick `PROFILE_NAME`; the container name, image name, and Linux
  user (`APP_USER`) default to it.
- **Tools** — optional `INCLUDE_<TOOL>="true"` flags add tool groups on top of the
  always-included base (git, ripgrep, jq, fzf, bat, eza, tmux, zsh).
- **Host mount** — `DOTFILES_DIR=""` keeps the profile hermetic; set it (with the
  `LINK_*` flags) to mount your dotfiles read-only at `/mnt/dotfiles`.
- **Resources** — `CPUS` / `MEMORY`, `"max"` for all host resources.
