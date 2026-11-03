#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
image="warp-zone-linux-test"

docker build -t "$image" "$here"
tty_flags=(-i)
[ -t 0 ] && tty_flags=(-it)
exec docker run --rm "${tty_flags[@]}" --privileged \
  -v "$repo:/src:ro" \
  "$image" "$@"
