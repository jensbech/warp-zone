# warp-zone

Isolated Linux dev containers on Docker, for macOS and Linux hosts. Each **profile** is a container (Ubuntu or Debian) with the tools you pick and its own Docker engine. Repos and credentials stay inside; your host stays clean.

## Quick start

Needs Docker, [just](https://just.systems) and Node 18+. `./setup.sh` checks them and prints install hints.

```bash
./setup.sh   # once: checks prerequisites, installs deps and the global `warp` command
just new     # wizard: name, recipe, tools, T3 Code
just open    # build on first run, then enter a shell
```

`warp <cmd>` works anywhere after setup. `[profile]` defaults to `dev`; profiles live in `~/warp/<name>`; work in `~/work`.

## Commands

| Command | Does |
| --- | --- |
| `new [name]` · `configure [profile]` | Create / change a profile with the wizard |
| `open [profile]` · `ssh [profile]` · `run <profile> <cmd>` | Enter, SSH in, run one command |
| `t3 [profile] [qr]` | Open T3 Code in this browser, or show a QR code to pair another device |
| `forward <ports> [profile] [local]` | Reach in-profile ports from the host (via SSH) |
| `list` · `status [profile]` · `logs [profile]` | Inspect |
| `start` · `stop` · `restart [profile]` | Control the container |
| `recipes` · `save [profile] [name] [shared]` · `up <recipe> [name]` · `forget-recipe <name>` | Recipes |
| `build` · `rebuild` · `update [profile]` · `update-all` | Images and OS packages |
| `backup` · `restore [profile]` | `~/work` tarballs |
| `destroy [profile]` | Delete everything for a profile (asks for the name) |
| `doctor` · `prune` · `smoke [name]` | Diagnose, reclaim space, self-test |

## Tools

Always included: git, ripgrep, jq, fzf, bat, eza, tmux, zsh, Claude Code, Docker. Pick more from about 270 tools in `template/catalog.json`. In the wizard, type to fuzzy-search and press space to toggle. Text that matches nothing becomes an extra distro package.

`profile.env` stores the result as `TOOLS='node gh t3code'` and `EXTRA_APT_PACKAGES='…'`. Pin versions with `<ID>_VERSION='x.y.z'`. `~/warp/<name>/setup.sh` runs as root at the end of each build. Apply changes with `just rebuild`.

## T3 Code

Answer yes to **"Serve T3 Code"** in the wizard (or later via `just configure`). The profile then runs [T3 Code](https://github.com/pingdotgg/t3code) and asks who can reach it:

- **Local only:** `http://localhost:<T3CODE_PORT>` on this computer. Pair a browser with `just t3`.
- **Tailscale:** the profile joins your tailnet as **its own machine**, named after the profile — nothing is tied to the host's Tailscale (the host does not even need it installed). T3 Code is published inside the container with `tailscale serve`, at `https://<profile>.<your-tailnet>.ts.net`. It is never on the public internet. The first time, run `tailnet` inside the shell: it prints a login link, waits for you to approve it, and publishes T3 Code. Then `just t3 <profile> qr` shows a QR code to pair your phone or another device. No T3 account is needed.

The node logs in with the ACL tag from `TAILSCALE_TAGS` (default `tag:warp`), so your tailnet policy can fence it in. Tailscale ACLs are default-deny, so a tagged node reaches nothing unless a rule says so: add the tag under `tagOwners`, and grant *your* devices access to it — never the other way round:

```json
"tagOwners": { "tag:warp": ["autogroup:admin"] },
"acls": [
  { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:warp:443"] }
]
```

With no rule that has `tag:warp` as `src`, the profile cannot initiate connections to any other machine on your tailnet. (The internet is unaffected; this is only tailnet traffic.) Tagged nodes also have no key expiry, so the login does not need renewing.

Pairing links are one-time and valid for 15 minutes. State lives in `~/work/.t3code` and `~/work/.tailscale`, so both the T3 Code data and the tailnet identity survive rebuilds. Switching between local and Tailscale recreates the container on the next `just open` (`~/work` is kept), and `destroy` logs the node out of your tailnet. Inside the shell: `tailnet status`, `tailnet serve`, `tailnet logout`. Logs: `just run <profile> "sudo tail /var/log/t3code.log /var/log/tailscaled.log"`.

## Recipes

A recipe is a saved setup in `profile.env` format. Recipes show up as starting points in the wizard.
- **Local** recipes go in `~/.config/warp-zone/recipes`. This is the default for `just save dev my-stack`.
- **Shared** recipes go in this repo's `recipes/`. Use `just save dev my-stack shared`.
- A local recipe wins over a shared one with the same name.

## Good to know

- **Docker inside:** the engine is nested, not shared, and needs `--privileged`. Its image cache survives `rebuild`. If pulls fail on a VPN, set `DOCKERD_ARGS='--mtu 1420'`.
- **SSH / VS Code:** enable SSH in the wizard. `just open` then writes `~/.ssh/config`, so `ssh <alias>` and Remote-SSH work. It listens on `127.0.0.1:<SSH_PORT>`, starting at port 2200.
- **Rebuilds:** they never touch `~/work`, which is on a volume. Only `destroy` deletes it.
- **Hermetic by default:** optionally mount a dotfiles directory read-only to link your git identity and Claude/opencode/Copilot config.
- **macOS vs Linux:**
  - On macOS, `max` CPU/RAM means the Docker VM's share.
  - On Linux it means the whole host. Your user needs the `docker` group, and without buildx builds fall back to the legacy builder.
  - `just doctor` checks all of this.

## Development

`cli/` holds the wizard, `lib/` the scripts behind the Justfile, and `template/` the files copied into each profile (including the catalog).

Tests:
- `node tests/catalog-check.mjs [--online]`
- `node tests/fuzzy.test.mjs`
- `tests/wizard.sh` (needs `expect`)
- `tests/linux/run.sh` runs a real Linux host in a container: `doctor` plus `smoke`
- `just smoke`
