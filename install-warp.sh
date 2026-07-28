#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
mkdir -p "$bin_dir"
cat > "$bin_dir/warp" <<EOF
#!/usr/bin/env bash
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
printf 'Installed warp. Try: warp manage\n'
