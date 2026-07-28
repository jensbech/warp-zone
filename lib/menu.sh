#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profiles=( $("$root/lib/status.sh" | awk 'NR > 1 { print $1 }') )
if [ "${#profiles[@]}" -eq 0 ]; then
  printf 'No profiles yet. Run: warp new\n'
  exit 0
fi
select profile in "${profiles[@]}" "Exit"; do
  [ -n "${profile:-}" ] || continue
  [ "$profile" = "Exit" ] && exit 0
  select action in Open Start Stop Restart SSH Status Backup Restore Update Rebuild Destroy Back; do
    [ -n "${action:-}" ] || continue
    case "$action" in
      Open) just --justfile "$root/Justfile" open "$profile" ;;
      Start) just --justfile "$root/Justfile" start "$profile" ;;
      Stop) just --justfile "$root/Justfile" stop "$profile" ;;
      Restart) just --justfile "$root/Justfile" restart "$profile" ;;
      SSH) just --justfile "$root/Justfile" ssh "$profile" ;;
      Status) just --justfile "$root/Justfile" status "$profile" ;;
      Backup) just --justfile "$root/Justfile" backup "$profile" ;;
      Restore) just --justfile "$root/Justfile" restore "$profile" ;;
      Update) just --justfile "$root/Justfile" update "$profile" ;;
      Rebuild) just --justfile "$root/Justfile" rebuild "$profile" ;;
      Destroy) just --justfile "$root/Justfile" destroy "$profile" ;;
      Back) break ;;
    esac
  done
done
