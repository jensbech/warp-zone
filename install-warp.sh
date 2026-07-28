#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
mkdir -p "$bin_dir"
cat > "$bin_dir/warp" <<EOF
#!/usr/bin/env bash
if [ "\$#" -eq 0 ]; then
  exec just --justfile "$script_dir/Justfile" manage
fi
if [ "\$1" = "help" ] || [ "\$1" = "--help" ] || [ "\$1" = "-h" ]; then
  cat <<'HELP'
warp - manage isolated Linux development profiles

Examples:
  warp                  Show profiles and common commands
  warp new              Create a profile
  warp open [profile]   Build if needed and enter a profile
  warp status [profile] Show profile state and configuration
  warp backup [profile] Back up ~/work before a rebuild
  warp restore [profile] Restore ~/work from a backup

Run warp for a profile overview and command guide.
HELP
  exit 0
fi
exec just --justfile "$script_dir/Justfile" "\$@"
EOF
chmod +x "$bin_dir/warp"

case ":${PATH}:" in
  *":$bin_dir:"*) ;;
  *)
    shell_rc="$HOME/.zshrc"
    [ "${SHELL##*/}" = "bash" ] && shell_rc="$HOME/.bashrc"
    touch "$shell_rc"
    if ! grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$shell_rc"; then
      printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$shell_rc"
    fi
    printf 'Added ~/.local/bin to PATH in %s. Open a new shell or run: source %s\n' "$shell_rc" "$shell_rc"
    ;;
esac
printf 'Installed warp. Run `warp` for profiles and common commands or `warp help` for help.\n'
