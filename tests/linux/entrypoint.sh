#!/usr/bin/env bash
set -euo pipefail

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  mkdir -p /sys/fs/cgroup/init
  xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :
  sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control
fi

dockerd >/var/log/dockerd.log 2>&1 &
for _ in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
docker info >/dev/null 2>&1 || { cat /var/log/dockerd.log; exit 1; }

rm -rf /home/tester/warp-zone
mkdir -p /home/tester/warp-zone
tar -C /src --exclude=node_modules -cf - . | tar -C /home/tester/warp-zone -xf -
chown -R tester:tester /home/tester/warp-zone
if [ ! -f /home/tester/.ssh/id_ed25519 ]; then
  sudo -u tester -H sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519'
fi

if [ "$#" -eq 0 ]; then
  set -- bash -lc 'cd ~/warp-zone && just doctor || true; just smoke'
fi
cd /home/tester
exec sudo -u tester -H --preserve-env=TERM "$@"
