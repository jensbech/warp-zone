#!/usr/bin/env bash
set -euo pipefail

# End-to-end check of the whole warp-zone contract on a throwaway profile:
# build → open → docker-in-docker → work survives a rebuild → backup/restore →
# SSH → teardown. Everything it creates is named after the profile and removed
# on exit, including on failure.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
. "$script_dir/helpers.sh"

profile="${1:-smoketest}"
keep=false
[ "${2:-}" = "--keep" ] && keep=true

green='\033[1;32m'
red='\033[1;31m'
cyan='\033[1;36m'
dim='\033[2m'
reset='\033[0m'

steps=0
step() { steps=$((steps + 1)); printf '\n%b[%d] %s%b\n' "$cyan" "$steps" "$1" "$reset"; }
pass() { printf '  %bok%b %s\n' "$green" "$reset" "$1"; }
die() { printf '  %bfail%b %s\n' "$red" "$reset" "$1" >&2; exit 1; }

dir="$profiles_root/$profile"
container="warp-$profile"
image="warp-$profile:latest"

cleanup() {
  local rc=$?
  if [ "$keep" = "true" ]; then
    printf '\n%bKept profile "%s" (--keep).%b\n' "$dim" "$profile" "$reset"
    exit "$rc"
  fi
  printf '\n%bCleaning up...%b\n' "$dim" "$reset"
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "warp-$profile-work" "warp-$profile-docker" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf "$dir"
  if [ -f "$HOME/.ssh/config" ]; then
    tmp="$(mktemp)"
    awk -v b="# >>> warp-zone:${profile} >>>" -v e="# <<< warp-zone:${profile} <<<" '
      $0==b { skip=1 } skip!=1 { print } $0==e { skip=0 }
    ' "$HOME/.ssh/config" > "$tmp" && mv "$tmp" "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
  fi
  exit "$rc"
}

require_docker
if [ -d "$dir" ]; then
  die "profile \"$profile\" already exists — pick another name: just smoke <name>"
fi
trap cleanup EXIT

step "Create profile \"$profile\""
"$repo_root/create-profile.sh" --dir "$profile" --yes >/dev/null
[ -f "$dir/profile.env" ] || die 'profile.env was not written'
pass 'profile.env written'

want_ssh=false
for k in "$HOME"/.ssh/*.pub; do
  [ -f "$k" ] && want_ssh=true && break
done
if [ "$want_ssh" = "true" ]; then
  sed -i '' "s/^INCLUDE_SSH=.*/INCLUDE_SSH='true'/" "$dir/profile.env"
  pass 'SSH enabled for this run'
else
  printf '  %bskip%b no ~/.ssh/*.pub on this host — SSH steps will be skipped\n' "$dim" "$reset"
fi

step 'Build image and open the profile'
"$dir/open.sh" --no-shell || die 'open.sh failed'
container_running "$container" || die 'container is not running after open'
pass 'container running'

step 'Docker-in-Docker works'
docker exec "$container" docker info >/dev/null 2>&1 || die 'inner docker daemon is not reachable'
docker exec "$container" docker run --rm hello-world >/dev/null 2>&1 \
  || die 'could not run hello-world inside the profile'
pass 'ran a container inside the profile'
docker exec -u "$(sed -n "s/^APP_USER='\(.*\)'$/\1/p" "$dir/profile.env")" "$container" docker ps >/dev/null 2>&1 \
  || die 'the profile user cannot talk to the inner docker socket'
pass 'profile user is in the docker group'

step 'Work survives a rebuild'
marker="smoke-$(date +%s)"
docker exec "$container" sh -c "echo $marker > /home/\$APP_USER/work/marker.txt" \
  || die 'could not write to ~/work'
"$dir/rebuild.sh" --skip-build >/dev/null || die 'rebuild.sh failed'
got="$(docker exec "$container" sh -c 'cat /home/$APP_USER/work/marker.txt' 2>/dev/null || true)"
[ "$got" = "$marker" ] || die "~/work did not survive the rebuild (got '${got:-nothing}')"
pass '~/work survived a container rebuild'

step 'Inner Docker state survives a rebuild'
docker exec "$container" docker image inspect hello-world >/dev/null 2>&1 \
  || die 'the inner image cache did not survive the rebuild'
pass 'inner image cache survived'

step 'Backup and restore'
"$script_dir/backup.sh" "$profile" >/dev/null || die 'backup.sh failed'
docker exec "$container" sh -c 'rm -f /home/$APP_USER/work/marker.txt'
backup="$(find "$dir/backups" -name 'work-*.tar.gz' | sort | tail -n1)"
[ -n "$backup" ] || die 'no backup file was produced'
docker exec "$container" find "/home/$(sed -n "s/^APP_USER='\(.*\)'$/\1/p" "$dir/profile.env")/work" -mindepth 1 -delete
docker exec -i "$container" sh -c 'tar -C /home/$APP_USER -xzf -' < "$backup" || die 'restoring the archive failed'
got="$(docker exec "$container" sh -c 'cat /home/$APP_USER/work/marker.txt' 2>/dev/null || true)"
[ "$got" = "$marker" ] || die 'restore did not bring the file back'
pass 'backup archive restores cleanly'

if [ "$want_ssh" = "true" ]; then
  step 'SSH round-trip'
  port="$(sed -n "s/^SSH_PORT='\(.*\)'$/\1/p" "$dir/profile.env")"
  out="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o BatchMode=yes -o ConnectTimeout=10 "$profile" 'echo ssh-ok' 2>/dev/null || true)"
  [ "$out" = 'ssh-ok' ] || die "ssh $profile did not answer on 127.0.0.1:$port"
  pass "ssh $profile works over 127.0.0.1:$port"
fi

step 'Stop and start'
docker stop "$container" >/dev/null || die 'stop failed'
docker start "$container" >/dev/null || die 'start failed'
for _ in $(seq 1 180); do
  docker exec "$container" docker info >/dev/null 2>&1 && break
  sleep 0.5
done
docker exec "$container" docker info >/dev/null 2>&1 || die 'inner docker did not come back after a restart'
pass 'inner docker comes back after a restart'

printf '\n%bAll %d checks passed.%b\n' "$green" "$steps" "$reset"
