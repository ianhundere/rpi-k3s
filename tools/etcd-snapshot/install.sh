#!/usr/bin/env bash
# deploy the etcd-snapshot scripts + timers onto this node. idempotent: re-run after any edit.
# must run as root on the etcd node (kube-master): sudo bash install.sh
set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -x /usr/local/bin/k3s ] || { echo "/usr/local/bin/k3s missing: not a k3s node" >&2; exit 1; }
[ -d /var/lib/rancher/k3s/server/db ] || { echo "no k3s server datastore: run this on the etcd node" >&2; exit 1; }

for s in etcd-snapshot-take etcd-snapshot-verify etcd-snapshot-sync; do
  install -o root -g root -m 755 "$here/$s" "/usr/local/bin/$s"
done
for u in "$here"/etcd-snapshot-*.service "$here"/etcd-snapshot-*.timer; do
  install -o root -g root -m 644 "$u" /etc/systemd/system/
done

systemctl daemon-reload
systemctl enable --now etcd-snapshot-take.timer etcd-snapshot-verify.timer etcd-snapshot-sync.timer
systemctl list-timers 'etcd-snapshot*' --no-pager
echo "installed. next: sudo /usr/local/bin/etcd-snapshot-take && sudo /usr/local/bin/etcd-snapshot-verify"
