<!-- bmad:context -->
<!-- Verified 2026-09-09 against 392894e. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## rpi-k3s

flux gitops for a five-node k3s cluster: kube-master is an amd64 beelink (control plane, etcd, deliberately untainted), kube-worker1-4 are arm64 raspberry pi 4s on custom 48-bit kernels, storage is a synology nas over csi-driver-nfs. `README.md` has the layout and procedures, `CONTEXT.md` the vocabulary, `docs/adr/` the decisions; ops history lives in the owner's notes, not here.

## Policy

- Change the cluster by commit + push; never `kubectl apply`, `edit`, `patch` or `scale` a flux-managed object. The only hand-applied objects are the two in `config/`: `kubectl apply --server-side --force-conflicts` (`docs/adr/0002-config-applied-by-hand.md`).
- Never read `config/*.enc.yaml` or any file containing `ENC[`; `grep -c 'ENC\[' <file>` is the only permitted touch. If a sops command fails, `git checkout -- <file>` instead of inspecting it.
- `git add` named files; never `-A` or `.`. Leave `research/` untracked: the research skill writes there and the owner decides what lands. Squash fix-up commits before pushing.
- Bounce a pod with `kubectl delete pod -n <ns> -l app=<app>`, after giving it a chance to recover on its own; never `kubectl rollout restart`: flux strips `restartedAt` and bounces it a second time.
- Write `$${VAR}` for anything flux must leave alone (shell vars in scripts, gatus env); bare `${VAR}` is substituted from `cluster-vars`/`cluster-secrets`. Per-app `secret.yml` files hold `${VAR}` templates, never literal values.

## Where things are

- `clusters/rpi-k3s/`: `apps.yml` and `infrastructure.yml` both prune, so removing a manifest deletes the live object. Controller memory tiers are patches in `flux-system/kustomization.yaml`; run `tools/audit-flux-tiers.sh` after regenerating `clusters/rpi-k3s/flux-system/gotk-components.yaml`, because kustomize silently drops a patch whose target no longer matches and a whole tier can vanish with no error.
- New nfs workload: copy a `*pv-csi.yml` (static pv, `storageClassName: ""` + `claimRef`) and set the pvc's `volumeName`; the `nfs-csi-*` storage classes are for dynamic pvcs only.
- Image bumps: policies in `infrastructure/image-automation/` plus `$imagepolicy` markers on `apps/` image lines; flux pushes `flux-image-updates` and `.github/workflows/flux-image-pr.yml` opens the pr.
- Adding a public host: listener pair in `infrastructure/envoy-gateway/gateway.yml`, `<X>_HOST` in `config/cluster-vars.yaml`, routes in the app dir, an endpoint in `apps/gatus/configmap.yml`.
- Node-level scripts live in `tools/` (`etcd-snapshot/`, `rpi-kernel-48bit/`); `ansible/` and `k3s-config/` are the node bootstrap of record. `tools/kubeconfig-refresh/` is not node-level: it is a systemd user timer on the owner's laptop that re-copies the rotated admin cert into `~/.kube/config`.

## Running and verifying

- Before every commit: `kubectl kustomize apps >/dev/null && kubectl kustomize infrastructure >/dev/null && kubectl kustomize clusters/rpi-k3s/flux-system >/dev/null`. Also run `tools/audit-flux-tiers.sh` when the commit touches `clusters/rpi-k3s/flux-system`, and `tools/audit-sops-drift.sh` when it adds a `${VAR}`.
- After push: `flux reconcile source git flux-system`, confirm the new sha in `flux get sources git`, then `flux reconcile kustomization apps` (or `infrastructure`). Never `--with-source`; it races the fetch.
- Verify a rollout with `kubectl get pod -n <ns> -w` and the gatus statuses (`kubectl get --raw /api/v1/namespaces/gatus/services/gatus:80/proxy/api/v1/endpoints/statuses`). Pulls on the pis are slow; wait for the watch before calling a rollout stuck. Poll without `sleep`; the owner paces monitoring.
- gatus config or secret change: `kubectl delete pod -n gatus -l app=gatus` after reconcile.
- Match the `flux` cli to the version in `clusters/rpi-k3s/flux-system/gotk-components.yaml` before `flux bootstrap` or an upgrade.
- Nodes: `ssh kube-master` (user dietpi), `ssh kube-worker1..4` (user pi). kube-master's clock is america/new_york; containers log utc.

## Conventions that differ from defaults

- Memory request == limit and no cpu limit on every container, burstable on purpose (`docs/adr/0001-no-cpu-limits.md`). Stateful containers (postgres, mongo, the arrs) get at least 1Gi. One exemption: the envoy data plane is 256Mi request / 1Gi limit in `infrastructure/envoy-gateway/envoyproxy.yml`, a tcmalloc-drift ceiling paired with the weekly pod recycle in `infrastructure/envoy-gateway/cronjob-rotate.yml`; leave both halves alone.
- Probes carry `timeoutSeconds` >= 5; the 1s default crashloops on the pis. Measure ttfb (time to first byte) before switching a tcpSocket probe to httpGet.
- Manifest comments are 2-3 lines stating the constraint; the story goes in the commit message. User-facing copy is lowercase, terse, no emojis.
- kube-master carries no taint and must keep hosting unifi and postgres (`docs/adr/0005-master-untainted.md`); never add `node-role.kubernetes.io/master:NoSchedule`.

## Known pitfalls

- linuxserver `DOCKER_MODS` reinstall on every pod start; on arm64 `universal-calibre` rebuilds calibre from apt each time. Only the vuetorrent mod is in use.
- subPath mounts give `/downloads` and the library different `st_dev`, so the arrs copy instead of hardlinking; lidarr additionally spans two nas volumes. Not a bug.
- `kubectl` failing with "must be logged in to the server" means the admin cert rotated: `~/bin/refresh-k3s-kubeconfig`.
- kube-worker1's `/var/lib/containers` is the quixit arm64 build cache, not junk.
- The etcd built-in snapshot cron died silently once; check snapshot freshness (`ssh kube-master 'sudo /usr/local/bin/etcd-snapshot-verify'`), never job success.

<!-- /bmad:context -->
