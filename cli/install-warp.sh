#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
bin_dir="$HOME/.local/bin"
mkdir -p "$bin_dir"
cat > "$bin_dir/warp" <<WRAPPER
#!/usr/bin/env bash
if ! command -v just >/dev/null 2>&1; then
  printf 'warp needs just (https://just.systems). Run %s/setup.sh for install hints.\n' "$repo_root" >&2
  exit 1
fi
if [ "\$#" -eq 0 ]; then
  exec just --justfile "$repo_root/Justfile" manage
fi
if [ "\$1" = "help" ] || [ "\$1" = "--help" ] || [ "\$1" = "-h" ]; then
  cat <<'HELP'
warp - manage isolated Linux development profiles

Examples:
  warp                  Show profiles and common commands
  warp new [name]       Create a profile
  warp open [profile]   Build if needed and enter a profile
  warp up <recipe> [n]  Create from a recipe and enter it
  warp recipes          List local and shared recipes
  warp save [p] [name]  Save a profile as a local recipe
  warp status [profile] Show profile state and configuration
  warp backup [profile] Back up ~/work before a rebuild
  warp restore [profile] Restore ~/work from a backup

Run warp for a profile overview and command guide.
HELP
  exit 0
fi
exec just --justfile "$repo_root/Justfile" "\$@"
WRAPPER
chmod +x "$bin_dir/warp"

case "$(uname -s):${SHELL##*/}" in
  Darwin:zsh|Linux:zsh) shell_rc="$HOME/.zshrc" ;;
  Darwin:bash) shell_rc="$HOME/.bash_profile" ;;
  Linux:bash) shell_rc="$HOME/.bashrc" ;;
  *) shell_rc="$HOME/.profile" ;;
esac

path_line='export PATH="$HOME/.local/bin:$PATH"'
case ":${PATH}:" in
  *":$bin_dir:"*) ;;
  *)
    touch "$shell_rc"
    if ! grep -Fqx "$path_line" "$shell_rc"; then
      printf '\n%s\n' "$path_line" >> "$shell_rc"
    fi
    printf 'Added ~/.local/bin to PATH in %s. Open a new shell or run: source %s\n' "$shell_rc" "$shell_rc"
    ;;
esac
printf 'Installed warp. Run `warp` for profiles and common commands or `warp help` for help.\n'
