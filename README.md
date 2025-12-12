# rpi-k3s

These manifests are supported by 4 Raspberry Pi 4s with 4GB RAM, a Beelink Mini S with a N5095 CPU and 8GB RAM and Synology ds723+.

> **note**: as of december 2025, this cluster uses flux cd for gitops. the manual `envsubst` deployment sections below are deprecated but kept for reference. see [gitops with flux](#gitops-with-flux) for current deployment workflow.

## initial setup

1. download latest vers of raspberry pi OS (e.g. <https://www.raspberrypi.com/software/operating-systems/>)
2. flash sd card
3. create empty ssh file under `/boot/`
    - `touch ssh`
4. connect via ssh
    - `ssh pi@<pi_ip>`
5. configure static ip via router; you'll also want to do this via `/etc/dhcpcd.conf` file.
6. set password
    - `passwd`
7. set hostname (e.g. master/worker)
    - `sudo vi /etc/hostname`
    - `sudo vi /etc/hosts`
8. upgrade / reboot
    - `sudo apt-get update && sudo apt-get -y dist-upgrade && sudo reboot`
9. enable container features by adding the following to `/boot/cmdline.txt`:

    - `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory`

10. edit `/etc/dhcp/dhclient.conf`

    - ```interface eth0
         static ip_address=<pi_ip>/24
         static routers=<router_ip>
         static domain_name_servers=<router_ip>
      ```

11. configure poe hat fan control via `/boot/config.txt` and use `/opt/vc/bin/vcgencmd measure_temp` to check temp (the config may be diff depending on poe hat used):

    - ```[all]
         dtoverlay=i2c-fan,emc2301`
      ```

## configure nfs storage

no matter what, the `nfs-common` package must be installed on all nodes unless a node acts as the primary, otherwise the `nfs-kernel-server` package must be installed.

### recommended

#### synology nas

1. enable the folowing on the synology nas:
    - [nfs service](https://kb.synology.com/en-us/DSM/tutorial/How_to_access_files_on_Synology_NAS_within_the_local_network_NFS#7MrLJcRf6d)
    - [nfs file permissions](https://kb.synology.com/en-us/DSM/tutorial/How_to_access_files_on_Synology_NAS_within_the_local_network_NFS#sZtk71ItBX)
2. follow the [nfs-subdir-external-provisioner](#install-nfs-provisioner) steps below for automated provisioning

### not recommended

#### nodes

1. list all connected devices and find the correct drive:
    - `sudo fdisk -l`
2. create partition
    - `sudo mkfs.ext4 /dev/sda1`
3. mount the disk manually
    - `sudo mkdir <nfs_path>`
    - `sudo chown -R pi:pi <nfs_path>/`
    - `sudo mount /dev/sda1 <nfs_path>`
4. configure disk to automatically mount
    - find the uuid of your mounted drive
        - `sudo blkid`
    - add the following with the correct uuid to `/etc/fstab`
        - `UUID=23e4863c-6568-4dd1-abde-0b128a81b0ba <nfs_path> ext4 defaults 0 0`
    - reboot and make sure the drive has mount
        - `df -ha /dev/sda1`
5. configure nfs
    - install nfs on master
        - `sudo apt-get install nfs-kernel-server -y`
    - add the following to `/etc/exports`
        - `<nfs_path> *(rw,no_root_squash,insecure,async,no_subtree_check,anonuid=1000,anongid=1000)`
    - start the nfs server
        - `sudo exportfs -ra`
    - install nfs on workers
        - `sudo apt-get install nfs-common -y`
    - create directory to mount nfs share
        - `sudo mkdir <nfs_path>`
        - `sudo chown -R pi:pi <nfs_path>/`
    - configure disk to automatically mount by adding the master's ip etc to `/etc/fstab`
        - `sudo vi /etc/fstab`
        - `<master_ip>:<nfs_path> <nfs_path> nfs rw 0 0`

## configure k3s master node

1. ssh to master node
    - `ssh pi@kube-master`
2. if you're not root, you'll want to enable the ability to write to the k3s config file `/etc/rancher/k3s/k3s.yaml`. you'll also want to tell k3s not to deploy its default load balancer, servicelb, and proxy, traefik, since we'll install metallb as load balancer and nginx as proxy manually later on. finally we want to run the k3s installer
    - `export K3S_KUBECONFIG_MODE="644"; export INSTALL_K3S_EXEC="--disable servicelb --disable traefik --kubelet-arg=container-log-max-files=5 --kubelet-arg=container-log-max-size=50Mi --kubelet-arg=image-gc-high-threshold=85 --kubelet-arg=image-gc-low-threshold=80 --cluster-init"; curl -sfL https://get.k3s.io | sh -`
3. verify the master is up
    - `sudo systemctl status k3s`
    - `kubectl get nodes -o wide`
    - `kubectl get pods -A -o wide`
4. taint the master node to avoid deploying to it / save resources for orchestration
    - `kubectl taint node kube-master node-role.kubernetes.io/master:NoSchedule`
5. save the access token to configure the agents
    - `sudo cat /var/lib/rancher/k3s/server/node-token`

## configure k3s worker nodes

<sub>for my x86 worker node, a beelink mini s with an n5095, i had to install:

- `apt-get install apparmor apparmor-utils`</sub>

1. ssh to work node
    - `ssh pi@kube-worker1`
2. set permissions on config file, set the endpoint for the agent, set the token saved from configuring the k3s master node, and run the k3s installer
    - `export K3S_KUBECONFIG_MODE="644"; export K3S_URL="https://<master_ip>:6443"; export K3S_TOKEN=<master_node_token>; export INSTALL_K3S_EXEC="--kubelet-arg=container-log-max-files=5 --kubelet-arg=container-log-max-size=50Mi --kubelet-arg=image-gc-high-threshold=85 --kubelet-arg=image-gc-low-threshold=80"; curl -sfL https://get.k3s.io | sh -`
3. verify agent is up
    - `sudo systemctl status k3s-agent`
    - `kubectl get nodes -o wide`
    - `kubectl get pods -A -o wide`
4. label the worker nodes
    - `kubectl label node <worker_name> node-role.kubernetes.io/node=""`
5. if mixing cpu architectures, include `nodeSelector` or `nodeAffinity` to ensure workloads get deployed to the relevant node.

## connect remotely to cluster

1. install `kubectl` if it's not already installed local computer, [Install Guide](https://kubernetes.io/docs/tasks/tools/install-kubectl/).
2. create the necessary directory and file
    - `mkdir ~/.kube/`
    - `touch ~/.kube/config`
3. copy the file using `scp`
    - `scp pi@<master_ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config`
4. you can either simply edit the `config` file and locate `127.0.0.1` and replace it with the IP address of the master node or use `sed`
    - `sed -i '' 's/127\.0\.0\.1/192\.168\.1\.1/g' ~/.kube/config`

## gitops with flux

> **note**: this cluster uses [flux cd](https://fluxcd.io) for gitops. all deployments are automated from this git repo. secrets are encrypted with [sops](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age).

### bootstrap flux (one-time setup)

1. install flux cli
    - `curl -s https://fluxcd.io/install.sh | sudo bash`
2. bootstrap flux to cluster (requires github token)
    - `export GITHUB_TOKEN=$(gh auth token)`
    - `flux bootstrap github --owner=ianhundere --repository=rpi-k3s --branch=main --path=clusters/rpi-k3s --personal --components-extra=image-reflector-controller,image-automation-controller`
3. install age and sops
    - arch: `sudo pacman -S age sops`
    - debian/ubuntu: `sudo apt install age sops`
    - mac: `brew install age sops`
4. generate age key (backup this file!)
    - `mkdir -p ~/.config/sops/age`
    - `age-keygen -o ~/.config/sops/age/keys.txt`
5. create age secret in cluster
    - `cat ~/.config/sops/age/keys.txt | kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey=/dev/stdin`

### managing secrets

**view/edit secrets:**
```bash
# edit secrets (opens in $EDITOR, auto-encrypts on save)
sops config/cluster-secrets.enc.yaml

# view decrypted secrets
sops -d config/cluster-secrets.enc.yaml
```

**deploy workflow:**
```bash
# 1. edit manifests or secrets
sops config/cluster-secrets.enc.yaml

# 2. commit and push
git add -A
git commit -m "update: whatever you changed"
git push

# 3. flux automatically applies changes within 1 minute
# (or force sync)
flux reconcile kustomization flux-system --with-source
```

**check flux status:**
```bash
flux get all -A
flux get kustomizations
kubectl get pods -n flux-system
```

### disaster recovery

if cluster is lost:
1. restore age private key from backup (`~/.config/sops/age/keys.txt`)
2. bootstrap flux to new cluster (step 2 above)
3. create age secret in new cluster (step 5 above)
4. flux will restore all resources automatically from git

## install metallb - k8s load balancer

> **automated via flux**: metallb is deployed automatically via flux. see `infrastructure/metallb/` for configuration.

## install gateway api & nginx gateway fabric - web proxy

> **Note**: As of November 2025, [ingress-nginx is deprecated](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) with support ending March 2026. This cluster uses the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) with [NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/) as the modern replacement.

> **automated via flux**: nginx-gateway-fabric is deployed automatically via flux using an OCIRepository. see `infrastructure/nginx-gateway-fabric/` for configuration.

**verify installation:**
```bash
kubectl get pods -n nginx-gateway
kubectl get gatewayclass
kubectl get svc -n nginx-gateway
flux get helmreleases -n nginx-gateway
```

## install cert-manager

> **automated via flux**: cert-manager is deployed automatically via flux. see `infrastructure/cert-manager/` for configuration.

> **Note**: cert-manager v1.12+ supports Gateway API. With Gateway API, certificates are referenced directly in Gateway specs rather than using Ingress annotations. be sure to forward port 80 for http01 cert challenges.

### staging

```bash
$ cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: <EMAIL>
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
```

### prod

```bash
$ cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: <EMAIL>
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
```

## deployed applications

> **automated via flux**: applications in `apps/` are deployed automatically via flux. infrastructure components in `infrastructure/` are also flux-managed.

### flux-managed apps

**public-facing (with HTTPS/TLS):**
- **filebrowser** (share.clusterian.pw) - file management interface
  - see: `apps/filebrowser/`
- **unifi** (unifi.clusterian.pw) - network controller
  - uses nginx sidecar proxy to handle self-signed backend TLS certificates
  - see: `apps/unifi/`
- **quixit** (quixit.us) - music collaboration challenge platform
  - automated phase transitions via cronjobs, file-watcher sidecar
  - see: `apps/quixit/` and [quixit/README.md](quixit/README.md) for details
  - see: `apps/quixit/`
- **plex** (media.clusterian.pw) - media server routing
  - uses EndpointSlice to route traffic to NAS (${NFS_IP})
  - see: `apps/media/plex-*`

**application notes:**
- all public-facing apps use Let's Encrypt TLS certificates via cert-manager
- unifi's nginx sidecar accepts self-signed certs with `proxy_ssl_verify off`
- gateway API with NGINX Gateway Fabric handles all HTTP/HTTPS routing

### legacy media apps (not yet in flux)

> **note**: these apps run in the `media` namespace but use old manual deployment configs in `media/` directory

- qbittorrent - torrent client (media.tools/qbittorrent, qbt.media.tools)
- jackett - indexer proxy (media.tools/jackett)
- sonarr - tv automation (media.tools/sonarr)
- radarr - movie automation (media.tools/radarr)
- calibre - ebook management (calibre.media.tools)
- soulseek - music sharing (soulseek.media.tools)

**to migrate these to flux:** move configs from `media/*/` to `apps/media/`, update kustomization.yml

**legacy media apps configuration notes:**
- jackett: requires `ServerConfig.json` in `<nfs_path>/jackett/Jackett` with `{"BasePathOverride": "/jackett"}`
- sonarr: requires `config.xml` in `<nfs_path>/sonarr/` with `<Config><UrlBase>/sonarr</UrlBase></Config>`
- radarr: requires `config.xml` in `<nfs_path>/radarr/` with `<Config><UrlBase>/radarr</UrlBase></Config>`
- connections: radarr/sonarr connect to qbittorrent at `qbittorrent.media:9091`
- indexers: use jackett API at `http://media.tools/jackett/api/v2.0/indexers/<name>/results/torznab/`

## install nfs-provisioner

> **automated via flux**: nfs-provisioner (3 instances for video, music, and config storage) is deployed automatically via flux. see `infrastructure/nfs-provisioner/` for configuration.

**storage classes available:**
- `nfs-video` - for video storage
- `nfs-music` - for music storage
- `nfs-rpik3s` - for config storage

apply pvcs with the appropriate `storageClass` and they will provision automatically.

## k3s system upgrade controller

> **automated via flux**: [system-upgrade-controller](https://docs.k3s.io/upgrades/automated) is deployed via flux. see `infrastructure/system-upgrade-controller/` for configuration.

**controller status:**
- deployed but pending (requires master node taint to schedule)
- upgrade Plans are commented out in kustomization.yml (apply manually when ready to upgrade)

**to perform k3s upgrade:**
1. taint master node to allow controller: `kubectl taint node kube-master CriticalAddonsOnly=true:NoExecute`
2. verify controller is running: `kubectl get pods -n system-upgrade`
3. update version in `infrastructure/system-upgrade-controller/config.yml`
4. uncomment config.yml in kustomization.yml and commit
5. flux will apply the upgrade Plans automatically

## tailscale

> **automated via flux**: tailscale operator is deployed via flux. see `infrastructure/tailscale/` for configuration.

provides vpn access to cluster resources. configuration in `infrastructure/tailscale/`.

## automatic cert rotation/renewal

[k3s client/server certs are valid for 365 days](https://docs.k3s.io/cli/certificate#client-and-server-certificates) and any that are expired, or within 90 days of expiring, are automatically renewed every time k3s starts. in other words, access to cluster will cease until local `kube-config` certs are updated:

to disable:

1. `sudo systemctl stop k3s.service`
2. `hwclock --verbose`
3. `sudo timedatectl set-ntp 0`
4. `sudo systemctl stop systemd-timesyncd.service`
5. `sudo systemctl status systemd-timesyncd.service`
6. `sudo date $(date "+%m%d%H%M%Y" --date="90 days ago")`
7. `sudo systemctl start k3s.service`

to renable:

1. `sudo systemctl stop k3s.service`
2. `sudo systemctl start systemd-timesyncd.service`
3. `sudo date $(date "+%m%d%H%M%Y" --date="now")`
4. `sudo timedatectl set-ntp 1`

## backups

make a copy of `/var/lib/rancher/k3s/server/`

### uninstall

1. master
    - `sudo /usr/local/bin/k3s-uninstall.sh`
2. workers
    - `sudo /usr/local/bin/k3s-agent-uninstall.sh`

## debugging

- `journalctl -u k3s.service -e` last logs of the server
- `journalctl -u k3s-agent.service -e` last logs of the agent
