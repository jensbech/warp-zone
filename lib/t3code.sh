#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

profile="${1:-dev}"
mode="${2:-open}"
load_profile "$profile"

if [ "${T3CODE_SERVE:-false}" != "true" ] || [ -z "${T3CODE_PORT:-}" ]; then
  printf 'T3 Code is not served by profile "%s".\n' "$profile" >&2
  printf 'Turn it on with: just configure %s   (then: just open %s)\n' "$profile" "$profile" >&2
  exit 1
fi

require_docker
require_running "$profile" "$CONTAINER_NAME" >/dev/null

if ! docker exec "$CONTAINER_NAME" sh -c 'command -v t3 >/dev/null 2>&1'; then
  printf 'This image was built without T3 Code. Run: just rebuild %s\n' "$profile" >&2
  exit 1
fi

binding="$(docker container inspect -f '{{index .Config.Labels "com.warp-zone.t3code"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
if [ "$binding" != "$T3CODE_PORT" ]; then
  printf 'The container was created before T3 Code was enabled. Run: just open %s\n' "$profile" >&2
  exit 1
fi

base_url="http://localhost:$T3CODE_PORT"
tailnet_url=""
if [ "${T3CODE_ACCESS:-local}" = "tailscale" ]; then
  if tailscale_ready && tailscale_serve_port "$T3CODE_PORT"; then
    printf '%s\n' "$T3CODE_PORT" > "$(profile_dir "$profile")/.tailscale-port"
    tailnet_url="$(tailscale_url "$T3CODE_PORT")"
  else
    printf 'Warning: T3CODE_ACCESS is tailscale, but Tailscale is not running on this host.\n' >&2
  fi
fi
if [ "$mode" = "qr" ] && [ -z "$tailnet_url" ]; then
  printf 'A QR code is for other devices, which need T3CODE_ACCESS=tailscale. Change it with: just configure %s\n' "$profile" >&2
  exit 1
fi
pair_base="$base_url"
[ "$mode" = "qr" ] && pair_base="$tailnet_url"
t3code_home="${APP_HOME:-/home/$APP_USER}/work/.t3code"

ready=false
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/3773' 2>/dev/null; then
    ready=true
    break
  fi
  sleep 0.5
done
if [ "$ready" != "true" ]; then
  printf 'T3 Code is not answering inside the profile. Inspect it with:\n' >&2
  printf '  just run %s "sudo tail -50 /var/log/t3code.log"\n' "$profile" >&2
  exit 1
fi

pairing="$(docker exec -u "$APP_USER" -e HOME="${APP_HOME:-/home/$APP_USER}" "$CONTAINER_NAME" \
  t3 auth pairing create --base-dir "$t3code_home" --base-url "$pair_base" --ttl 15m --label "$(hostname -s 2>/dev/null || printf host)" --json)"
pair_url="$(printf '%s\n' "$pairing" | sed -n 's/.*"pairUrl": *"\([^"]*\)".*/\1/p')"
if [ -z "$pair_url" ]; then
  printf 'Could not mint a pairing link:\n%s\n' "$pairing" >&2
  exit 1
fi

printf 'T3 Code:  %s\n' "$base_url"
[ -n "$tailnet_url" ] && printf 'Tailnet:  %s   (any device on your tailnet)\n' "$tailnet_url"
printf 'Pair:     %s   (one-time link, valid 15 minutes)\n' "$pair_url"

if [ "$mode" = "qr" ]; then
  if command -v node >/dev/null 2>&1 && node "$script_dir/../cli/qr.mjs" "$pair_url" 2>/dev/null; then
    printf 'Scan it with the device you want to pair.\n'
  fi
  exit 0
fi
if [ "$mode" = "--print" ]; then
  exit 0
fi
if [ "$(host_os)" = "macos" ] && command -v open >/dev/null 2>&1; then
  open "$pair_url"
elif command -v xdg-open >/dev/null 2>&1 && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  xdg-open "$pair_url" >/dev/null 2>&1 &
else
  printf 'Open the pair link in a browser on this machine.\n'
fi
