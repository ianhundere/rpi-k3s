# etcd-snapshot

host-level etcd backup timers for kube-master (the only etcd node). not gitops —
flux can't manage the node — so this dir is the record and `install.sh` is the deploy.

## what

three systemd timers, three scripts:

| timer | when | does |
|---|---|---|
| `etcd-snapshot-take` | 03/09/15/21 | `k3s etcd-snapshot save --name scheduled`, then `prune --name scheduled` |
| `etcd-snapshot-verify` | hourly | exit 1 + `daemon.crit` in the journal when *either* producer's newest snapshot is past 7h |
| `etcd-snapshot-sync` | hourly | `rsync -a --delete` the snapshot dir to the nas at `/volume3/rpi-k3s/etcd-backup/<hostname>` |

snapshots live in `/var/lib/rancher/k3s/server/db/snapshots`. the nas share is
pushed to borgbase nightly by the nas's own scripts, so etcd state goes offsite
with nothing further on the node.

## why

k3s has its own `--etcd-snapshot-schedule-cron` (`k3s-config/k3s_server-config.yml`:
every 6h, retention 8). on 2026-08-13 it silently stopped firing — valid config,
manual saves fine, nothing logged — and the hourly sync kept mirroring the same
stale files, so every surface said "backups running" while they went 18h cold.
`take` is the second producer; `verify` checks freshness, not job success.

the built-in cron came back on its own around 2026-09-07. both producers stay:
two ~50MB snapshots per 6h is cheap insurance against it going quiet again.

`take` fires at 03/09/15/21, offset 3h from the built-in `0 */6 * * *`, so the
two interleave instead of landing a minute apart and leaving a 6h gap — the real
coverage is a snapshot every 3h.

`verify` checks each prefix on its own — newest `scheduled-*` and newest
`etcd-snapshot-*`, either past 7h fails. one shared "newest file" check would
put us straight back in 2026-08-13: whichever producer is still alive keeps the
check green while the other is silently dead. the boundary is real minutes, so
7h01m fails.

`take` prunes because on-demand saves are exempt from `etcd-snapshot-retention`:
by 2026-09-09 there were ~105 `scheduled-*` files (~5GB) and the nas mirror
matched. `prune` applies the retention count from `/etc/rancher/k3s/config.yaml`
to the `scheduled-` prefix only — the named one-offs (`pre-ip-swap-*` etc.) stay.

## check freshness

```bash
ssh kube-master 'sudo /usr/local/bin/etcd-snapshot-verify'   # "ok: scheduled-* 1h12m old (...), etcd-snapshot-* 2h9m old (...)"
ssh kube-master "systemctl list-timers 'etcd-snapshot*'; systemctl --failed"
ssh kube-master 'sudo ls -lt /var/lib/rancher/k3s/server/db/snapshots | head -5'
ssh kube-master 'sudo k3s etcd-snapshot list'
```

`verify` must run as root: the snapshot dir is `0700`, and an unprivileged run
says "no snapshots" — a false alarm, not a stale backup.

the cluster does have alerting — gatus in `apps/gatus/`, ntfy push plus a
healthchecks.io deadman — but these timers are **not** wired into it. a stale
snapshot is journal-only today: `systemctl --failed` and
`journalctl -t etcd-snapshot-verify`. open follow-up: an `OnFailure=` unit on
`etcd-snapshot-verify.service` that posts to the ntfy topic.

## deploy

```bash
scp -r tools/etcd-snapshot kube-master:
ssh kube-master 'sudo bash ~/etcd-snapshot/install.sh'
```

`install.sh` copies the scripts to `/usr/local/bin` (0755) and the units to
`/etc/systemd/system`, reloads systemd, and enables the three timers. re-run it
after any edit here; it's idempotent.

after changing `take`, run it once by hand and confirm the prune:

```bash
ssh kube-master 'sudo /usr/local/bin/etcd-snapshot-take && sudo ls /var/lib/rancher/k3s/server/db/snapshots | grep -c ^scheduled-'
```

expect 8.

## gotchas

- never pass `--snapshot-retention` to `save` or `prune`: config.yaml already sets it and k3s dies with "Cannot use two forms of the same flag"
- `sync` uses `--delete`, so the nas mirror follows local pruning; borgbase keeps the history
- `sync` refuses (exit 1) when the local dir is empty or unreadable — `--delete` would otherwise mirror the emptiness over the copy a rebuilt node restores from
- `take.service` uses `Requisite=k3s.service`, not `Requires=`: during a `--cluster-reset` restore k3s is stopped on purpose and the timer must fail, not start it
- `k3s etcd-snapshot list` and the `etcdsnapshotfiles` crs track the files; `prune` cleans both
- restore: <https://docs.k3s.io/datastore/backup-restore> (`k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>`)
