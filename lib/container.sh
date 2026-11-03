#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/helpers.sh"

action="${1:?action is required}"
profile="${2:-dev}"
load_profile "$profile"

case "$action" in
  start|stop|restart)
    require_container "$profile" "$CONTAINER_NAME"
    docker "$action" "$CONTAINER_NAME" >/dev/null
    ;;
  logs)
    require_container "$profile" "$CONTAINER_NAME"
    docker logs "$CONTAINER_NAME"
    ;;
  run)
    cmd="${3:?command is required}"
    require_running "$profile" "$CONTAINER_NAME" >/dev/null
    if [ -t 0 ]; then tty_flags=(-it); else tty_flags=(-i); fi
    docker exec "${tty_flags[@]}" "$CONTAINER_NAME" su - "$APP_USER" -c "$cmd"
    ;;
  *)
    printf 'Unknown action: %s\n' "$action" >&2
    exit 1
    ;;
esac
