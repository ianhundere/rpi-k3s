# rpi-k3s

flux-managed k3s cluster on four raspberry pi 4s (4gb), a beelink mini s (n5095, 8gb) and a synology ds723+ for storage. flux applies everything in kubernetes from this repo except the metallb install (deferred) and the two hand-applied objects in `config/`.

## layout

- `clusters/rpi-k3s/` - flux entry point: `flux-system/` (bootstrap manifests + controller memory tiers), `infrastructure.yml`, `apps.yml`. both kustomizations prune, so removing a manifest removes the object
- `infrastructure/` - cert-manager, envoy gateway, metallb pool, tailscale operator, csi-driver-nfs, image automation, system-upgrade-controller (disabled between upgrades)
- `apps/` - one dir per app; the media stack under `apps/media/`
- `config/` - `cluster-vars.yaml` (plaintext hostnames and lan ips) and `cluster-secrets.enc.yaml` (sops). the only objects applied by hand
- `ansible/` - node bootstrap and dr path; ips are placeholders on purpose
- `k3s-config/` - the k3s server and agent config of record
- `tools/` - `audit-flux-tiers.sh`, `audit-sops-drift.sh`, `kubeconfig-refresh/`, `rpi-kernel-48bit/`, `etcd-snapshot/`
- `.github/workflows/flux-image-pr.yml` - turns flux image bumps into a daily pr
- `AGENTS.md`, `CONTEXT.md`, `docs/adr/` - agent rules, vocabulary, decisions

## nodes

| node | hardware | role | ssh |
|---|---|---|---|
| kube-master | beelink mini s n5095, 8gb, amd64, dietpi | control plane + etcd on the internal ssd; untainted, hosts unifi and the heavier postgres pods | `dietpi@kube-master` |
| kube-worker1-3 | raspberry pi 4, 4gb, arm64, sd card | workers; custom 48-bit kernel from `tools/rpi-kernel-48bit/` | `pi@kube-worker1..3` |
| kube-worker4 | raspberry pi 4, 4gb, arm64, usb boot (the ex-master) | worker; same 48-bit kernel as the other three; never etcd again | `pi@kube-worker4` |

all nodes run debian 13 and k3s v1.35.1+k3s1. addresses are dhcp reservations and stay out of git - fill `ansible/inventory.yml` locally. the nas exports `/volume1/media`, `/volume2/music` and `/volume3/rpi-k3s`.

## bootstrap

### nodes

flash raspberry pi os (enable ssh in the imager), reserve the ips on the router, fill the `# TODO` placeholders in `ansible/inventory.yml`, then:

```bash
cd ansible && ansible-playbook playbooks/99-full-bootstrap.yml
```

the playbooks set hostname and timezone, append `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory` to the pi `cmdline.txt`, install `nfs-common` (plus apparmor on amd64), install the k3s server, join the agents and print the remaining manual steps. the master is deliberately not tainted (`docs/adr/0005-master-untainted.md`). copy `k3s-config/k3s_server-config.yml` to `/etc/rancher/k3s/config.yaml` on the master (fill `node-ip` and `tls-san`) so the disabled servicelb/traefik and the etcd snapshot schedule survive a reinstall; `k3s_agent-config.yml` is the same for workers. `vcgencmd measure_temp` checks poe-hat temps.

### local kubectl

```bash
scp dietpi@kube-master:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127\.0\.0\.1/<master_ip>/' ~/.kube/config   # gnu sed; mac: sed -i ''
```

the admin cert rotates when k3s restarts, after which every `kubectl` fails with `You must be logged in to the server`. `tools/kubeconfig-refresh/` installs a user timer that keeps the local copy current; one-off: `~/bin/refresh-k3s-kubeconfig`.

### flux

```bash
export GITHUB_TOKEN=$(gh auth token)
flux bootstrap github --owner=ianhundere --repository=rpi-k3s --branch=main \
  --path=clusters/rpi-k3s --personal \
  --components-extra=image-reflector-controller,image-automation-controller
cat ~/.config/sops/age/keys.txt | kubectl create secret generic sops-age \
  --namespace=flux-system --from-file=age.agekey=/dev/stdin
```

the `flux` cli must match the version in `clusters/rpi-k3s/flux-system/gotk-components.yaml` before a bootstrap or upgrade. after regenerating `gotk-components.yaml` run `tools/audit-flux-tiers.sh`: the controller memory patches in `clusters/rpi-k3s/flux-system/kustomization.yaml` fail open, so kustomize silently drops any whose target no longer matches and a whole tier can vanish with no error.

### disaster recovery

1. nodes: the ansible bootstrap above
2. the host steps ansible does not do: copy `k3s-config/k3s_server-config.yml` to `/etc/rancher/k3s/config.yaml` on the master (fill `node-ip` and `tls-san`) and `k3s-config/k3s_agent-config.yml` to the same path on each worker, then `sudo bash install.sh` from `tools/etcd-snapshot/` on the master for the take/verify/sync timers
3. is the datastore gone? if a snapshot survives, restore it and skip to step 7: copy the newest file from `/volume3/rpi-k3s/etcd-backup/<hostname>/` on the nas to the master and run `k3s server --cluster-reset --cluster-reset-restore-path=<file>`. flux, the `sops-age` secret, the two `config/` objects and the by-hand metallb install all come back with it, so rebuilding them first is wasted work. steps 4-6 are the other branch: bootstrap from scratch, only when there is no usable snapshot
4. install metallb (v0.14.8) by hand. it is not in git - `infrastructure/metallb/config.yml` is only the pool and its crds arrive with the install, so without it the pool never applies, `infrastructure` never goes ready (`wait: true`) and `apps` never starts (`dependsOn`)
5. flux bootstrap and the age key (above) - the age key backup is the whole secret
6. apply `config/` by hand (deploy workflow below); flux fills every `${VAR}` from it
7. `flux get all -A` until everything is ready. pvcs bind to static pvs that point at the existing nas dirs, so no data moves

## deploy workflow

```bash
git add apps/<app>/<file>.yml        # named files, never -A
git commit -m "..."
git push
flux reconcile source git flux-system && flux get sources git   # confirm the new sha first
flux reconcile kustomization apps    # or: infrastructure
```

`apps` and `infrastructure` reconcile every 2m on their own; the two `flux reconcile` commands only shorten the wait. keep them as two: `flux reconcile source git flux-system` first, then `flux reconcile kustomization` once the new sha shows. do not collapse them into `flux reconcile kustomization --with-source`, which races the fetch and reconciles the old sha. squash fix-up commits before pushing.

### secrets and variables

per-app `secret.yml` files are plaintext templates: every value is a `${VAR}` that flux fills at postbuild from the `cluster-vars` configmap and the `cluster-secrets` secret. the only file holding real secret values is `config/cluster-secrets.enc.yaml`. write `$${VAR}` for anything flux must leave alone (shell vars in scripts, gatus env). adding a secret: add the key with `sops config/cluster-secrets.enc.yaml`, re-apply as below, reference `${VAR}` in the manifest.

flux does not manage `config/` (`docs/adr/0002-config-applied-by-hand.md`); apply both objects server-side after every edit:

```bash
sops -d config/cluster-secrets.enc.yaml | kubectl apply --server-side --force-conflicts -f -
kubectl apply --server-side --force-conflicts -f config/cluster-vars.yaml
```

plain `kubectl apply` writes the decrypted values into the `last-applied-configuration` annotation. `tools/audit-sops-drift.sh` diffs the sops store against the live secret, asserts that annotation is absent, and fails on any manifest `${VAR}` defined in neither store.

### suspend

```bash
flux suspend kustomization apps      # freezes every app dir; there is no per-app kustomization
flux resume kustomization apps
flux suspend source git flux-system  # stops every sync
flux resume source git flux-system
```

### image updates

`infrastructure/image-automation/` scans the registries and commits tag bumps to the `flux-image-updates` branch, rewriting only image lines under `apps/` that carry a `# {"$imagepolicy": "flux-system:<name>"}` marker. `.github/workflows/flux-image-pr.yml` opens the pr daily; squash-merge it. the repo deletes the branch on merge and the workflow deletes a stale or conflicting one, so flux rebuilds it from main on the next bump. check the changelog before merging lidarr (nightly, tubifarry) or unifi bumps. the private quixit and tufkin registries are scanned with the `ghcr-secret` templated in `infrastructure/image-automation/ghcr-secret.yml` (`${GHCR_TOKEN}` from the sops store, `config/cluster-secrets.enc.yaml`), so a rebuild keeps scanning.

## storage

csi-driver-nfs (`infrastructure/csi-driver-nfs/`, chart 4.13.4 in `kube-system`) mounts the nas. every live workload rides a static pv (`apps/<app>/*pv-csi.yml`: `storageClassName: ""` plus `claimRef`, bound by the pvc's `volumeName`) that points at its existing dir: `/volume3/rpi-k3s/<ns>/<name>` (tufkin is the literal `/volume3/rpi-k3s/tufkin`), `/volume1/media` for `media-data`, `/volume2/music` for `music-data`. the `nfs-csi-rpik3s`, `nfs-csi-music` and `nfs-csi-video` storage classes exist for future dynamic pvcs only. `local-path` is the cluster default and holds slskd's app dir, which pins that pod to one node. the split is deliberate: music sits on nvme (`/volume2`) and is backed up, while movies, tv and downloads sit on sata (`/volume1`) and are not. it is the split itself, not the backup policy, that stops lidarr hardlinking - its downloads are on `/volume1` and its library on `/volume2`, two filesystems, so every import is a copy.

## ingress

metallb hands one lan ip to the envoy data plane (pool in `infrastructure/metallb/config.yml`; the metallb install itself is not in git yet). `shared-gateway` in `envoy-gateway-system` carries one listener pair per public host and apps attach httproutes by `sectionName`. cert-manager's gateway-shim reads the `cert-manager.io/cluster-issuer` annotation on the gateway and issues a let's encrypt cert per https listener over http-01, so tls secrets live in `envoy-gateway-system`. the lb exposes only 80 and 443; non-http services ride 443 by sni passthrough (soju). `media.tools` and `monitor.clusterian.pw` are http-only lan names.

adding a public host: a listener pair in `infrastructure/envoy-gateway/gateway.yml`, a `<X>_HOST` key in `config/cluster-vars.yaml`, redirect + https routes in the app dir, an endpoint in `apps/gatus/configmap.yml`.

```bash
kubectl get gateway -n envoy-gateway-system shared-gateway
kubectl get certificates,orders,challenges -n envoy-gateway-system
kubectl get httproute,tlsroute -A
```

## apps

public, https via cert-manager:

- filebrowser (share.clusterian.pw) - `apps/filebrowser/`
- unifi (unifi.clusterian.pw) - network controller; an nginx sidecar terminates the self-signed backend tls; needs kube-master's 8gb - `apps/unifi/`
- quixit (quixit.us) - music collaboration challenge; phase transitions run in-app; source in the quixit repo - `apps/quixit/`
- tufkin (auth.quixit.us) - oauth for quixit - `apps/tufkin/`
- plex (media.clusterian.pw) - runs on the nas; an endpointslice points the service there - `apps/media/plex/`
- soju (irc.clusterian.pw:443) - irc bouncer, tls passthrough - `apps/irc/` (readme there)

lan and tailnet, http:

- gatus (monitor.clusterian.pw, `http://gatus` on the tailnet) - 22 black-box checks, ntfy alerts, healthchecks.io deadman - `apps/gatus/`
- media-postgres - postgres 18 shared by sonarr, radarr, prowlarr and lidarr - `apps/media/postgres/`
- sonarr, radarr, prowlarr, lidarr, calibre (a calibre-web image), qbittorrent, soulseek (a slskd image) - `media.tools/<app>`, except qbittorrent at `media.tools/qbit` - `apps/media/<app>/`
- ninjam-server - parked: every resource is commented out of its kustomization and the configmap says how to revive it - `apps/ninjam-server/`

the media apps and gatus carry `tailscale.com/expose` on their service; the operator in `infrastructure/tailscale/` runs one proxy per service, sized by the `bounded` proxyclass.

media notes:

- the arrs (sonarr, radarr, prowlarr, lidarr) use `media-postgres` via `<APP>__POSTGRES__*` env. `config.xml` still holds `<UrlBase>/<app></UrlBase>` and lives at `/volume3/rpi-k3s/media/media-config/<app>/config.xml` (the `media-config` pvc, subpath `<app>`)
- prowlarr manages indexers and syncs them to sonarr, radarr and lidarr. lidarr additionally runs the tubifarry plugin as its own slskd indexer and download client (install via system > plugins; remote path mapping `host=soulseek, remote=/downloads/, local=/downloads/soulseek/` or every import fails)
- download clients from the arrs: qbittorrent at `qbittorrent.media:80`, soulseek at `soulseek.media:80`
- qbittorrent, soulseek and prowlarr share a pod with a gluetun sidecar (protonvpn wireguard). qbittorrent and soulseek also run a `port-sync` sidecar that rewrites the listen port when proton rotates the forwarded one (`port-sync.configmap.yml`)
- qbittorrent's service is a clusterip on port 80; envoy and the tailscale proxy reach it in-cluster
- calibre probes `httpGet /login` with `timeoutSeconds` 5-10. not `/`, which renders the whole library; not `tcpSocket`, which a hung app still passes
- linuxserver `DOCKER_MODS` install on every pod start; on arm64 only the vuetorrent mod is cheap enough to keep

## k3s upgrades

`infrastructure/system-upgrade-controller/` stays commented out of `infrastructure/kustomization.yml` between upgrades. one minor version at a time:

1. bump `version` in both plans in `infrastructure/system-upgrade-controller/config.yml`
2. uncomment `system-upgrade-controller/` in `infrastructure/kustomization.yml`, push
3. `kubectl get pods,plans -n system-upgrade`; the job deadline is 3600s because pulls on the pis are slow
4. re-comment the dir and push; infrastructure prunes, so the controller and its namespace go away

## backups

- etcd: k3s snapshots every 6h with 8 kept (`k3s-config/k3s_server-config.yml`), plus the systemd timers vendored in `tools/etcd-snapshot/` and installed on kube-master by its `install.sh`: `etcd-snapshot-take` (every 6h, prunes `scheduled-*` to the same retention), `etcd-snapshot-verify` (hourly, fails when the newest snapshot is older than 7h) and `etcd-snapshot-sync` (hourly rsync to the nas at `/volume3/rpi-k3s/etcd-backup/<hostname>/`). the built-in cron died silently once, so check freshness, not job status: `ssh kube-master 'sudo /usr/local/bin/etcd-snapshot-verify'`
- app data lives on the nas. the nas pushes its shares, including `/volume3/rpi-k3s` (app configs, postgres dirs, etcd snapshots) and `/volume2/music`, to borgbase nightly from scripts on the nas itself, not this repo. `/volume1/media` has no offsite copy on purpose
- the age key at `~/.config/sops/age/keys.txt` - without it nothing decrypts

## monitoring

gatus (`apps/gatus/configmap.yml`) probes every public host and its cert expiry, the acme port-80 redirect, the media stack in-cluster, the three postgres instances, nfs, ntfy itself and a healthchecks.io deadman. alerts go to an ntfy topic; the topic and ping url live only in the sops store. `cronjob-restart-watch.yml` pages on any container restart, which black-box checks cannot see. gatus reads its config once at start, so after pushing a config change bounce it: `kubectl delete pod -n gatus -l app=gatus`.

```bash
kubectl get --raw /api/v1/namespaces/gatus/services/gatus:80/proxy/api/v1/endpoints/statuses \
  | jq -r '.[]|"\(.name) \(.results[-1].success)"'
```

## debugging

```bash
flux get all -A                                   # one-screen view
flux logs --level=error -A --since=1h             # why a kustomization is not ready
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl delete pod -n <ns> -l app=<app>           # bounce; never rollout restart, flux reverts the annotation and bounces again
tools/audit-flux-tiers.sh                         # controller memory tiers still applied
tools/audit-sops-drift.sh                         # sops store vs live secret, unresolved ${VAR}s
ssh kube-master 'sudo journalctl -u k3s -e'       # server logs; workers: k3s-agent
```

image pulls on the pis are slow; wait for the pod watch before calling a rollout stuck. kube-master's clock is america/new_york; containers log utc.

## uninstall

```bash
sudo /usr/local/bin/k3s-uninstall.sh          # master
sudo /usr/local/bin/k3s-agent-uninstall.sh    # workers
```
