# rpi-k3s

These manifests are supported by 4 Raspberry Pi 4s with 4GB RAM and a Beelink Mini S with a N5095 CPU and 8GB RAM (dedicated to Plex).

## initial setup

1. download latest vers of buster-lite (e.g. <https://downloads.raspberrypi.org/raspios_lite_armhf_latest>)
2. flash sd card
3. create empty ssh file under `/boot/`
    - `touch ssh`
4. connect via ssh
    - `ssh pi@<pi_ip>`
5. configure static ip via router; you'll also want to do this via `/etc/dhcpcd.conf` file.
6. set password
    - `passwd`
7. set hostname
    - `sudo vi /etc/hostname`
8. upgrade / reboot
    - `sudo apt-get update && sudo apt-get -y dist-upgrade && sudo reboot`
9. enable container features by adding the following to `/boot/cmdline.txt`:
    - `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory`
10. enable arm64 cpu architecture by adding the following to `/boot/config.txt` under `[pi4]`:

    - ```bash
        arm_64bit=1
      ```

11. edit `/etc/dhcpcd.conf`

    - ```interface eth0
         static ip_address=<pi_ip>/24
         static routers=<router_ip>
         static domain_name_servers=<router_ip>
      ```

12. switch firewall to legacy config:
    - `sudo update-alternatives --set iptables /usr/sbin/iptables-legacy`
    - `sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy`
13. configure poe hat fan control via `/boot/config.txt` and use `/opt/vc/bin/vcgencmd measure_temp` to check temp (the config may be diff depending on poe hat used):
    - `dtoverlay=i2c-fan,emc2301`

## configure nfs storage

no matter what, the `nfs-common` package must be installed on all nodes unless a node acts as the primary, otherwise the `nfs-kernel-server` package must be installed.

### recommended

#### synology nas

1. enable the folowing on the synology nas:
    - (nfs service)[https://kb.synology.com/en-us/DSM/tutorial/How_to_access_files_on_Synology_NAS_within_the_local_network_NFS#7MrLJcRf6d]
    - (nfs file permissions)[https://kb.synology.com/en-us/DSM/tutorial/How_to_access_files_on_Synology_NAS_within_the_local_network_NFS#sZtk71ItBX]
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
    - `export K3S_KUBECONFIG_MODE="644"; export INSTALL_K3S_EXEC="--disable servicelb --disable traefik --kubelet-arg=container-log-max-files=5 --kubelet-arg=container-log-max-size=50Mi --kubelet-arg=image-gc-high-threshold=85 --kubelet-arg=image-gc-low-threshold=80"; curl -sfL https://get.k3s.io | sh -`
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

-   `apt-get install apparmor apparmor-utils`</sub>

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
5. if mixing architectures, make sure to include `nodeSelector` or `nodeAffinity` to ensure your workloads get deployed to their relevant node (e.g. the plex deployment is tagged specifically for an `x86` node) especially if your images aren't tagged specific to the arch:

    - ```yaml
      nodeSelector:
          kubernetes.io/arch: amd64
      ```

    - ```yaml
      nodeSelector:
          kubernetes.io/arch: arm64
      ```

### uninstall

1. master
    - `sudo /usr/local/bin/k3s-uninstall.sh`
2. workers
    - `sudo /usr/local/bin/k3s-agent-uninstall.sh`

## connect remotely to cluster

1. install `kubectl` if it's not already installed local computer, [Install Guide](https://kubernetes.io/docs/tasks/tools/install-kubectl/).
2. create the necessary directory and file
    - `mkdir ~/.kube/`
    - `touch ~/.kube/config`
3. copy the file using `scp`
    - `scp pi@<master_ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config`
4. you can either simply edit the `config` file and locate `127.0.0.1` and replace it with the IP address of the master node or use `sed`
    - `sed -i '' 's/127\.0\.0\.1/192\.168\.1\.1/g' ~/.kube/config`

## install envsubst / create .env file

1. install envsubst; check your local os and follow accordingly
2. create `.env`
    - `touch .env` / copy the below with the correct values:

```bash
# hosts
NINJAM_HOST="blah"
export UNIFI_HOST="blah"
export FILEBROWSER_HOST="blah"
export SOULSEEK_HOST="blah"

# internal ips
export METAL_LB_IP1="blah"
export METAL_LB_IP2="blah"
export METAL_LB_IP11="blah"
export NFS_IP="blah"

# secrets
export NINJAM_USER="blah"
export NINJAM_PASSWORD="blah"
export FILEBROWSER_USER="blah"
export FILEBROWSER_PW="blah"
export PLEX_CLAIM="blah"
export VPN_USERNAME=$(echo -n "blah" | base64)
export VPN_PASSWORD=$(echo -n "blah" | base64)
export VPN_KEY=$(echo -n "blah" | base64)
export MONGO_PASS="blah"
```

3. make sure to source `.env` when a k8s resource needs creds:
    - `source .env`
4. example cmds:
    - `envsubst < media/unifi/unifi.statefulset.yml | kubectl apply -f -`

## install metallb - k8s load balancer

1. apply the metallb manifest which includes the namespace, controller deployment, speaker daemonset and necessary service accounts for the controller and speaker, along with the RBAC permissions that everything need to function
    - `kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v<latest_vers>/config/manifests/metallb-native.yaml`
2. apply the `CRDs` which will indicate what protocol (e.g. `layer2`) and IPs to use.
    - `envsubst < metallb/config.yml | kubectl apply -f -`

## install nginx - web proxy

1. install helm
    - `brew install helm`
2. add the nginx repo / update repo
    - `helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx; helm repo update`
3. install nginx
    - `helm install nginx-ingress ingress-nginx/ingress-nginx --set defaultBackend.enabled=false -n kube-system`

## install cert-manager

1. add the cert-manager repo / update repo
    - `helm repo add jetstack https://charts.jetstack.io; helm repo update`
2. install cert-manager
    - `helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version <latest_vers> --set startupapicheck.timeout=5m --set installCRDs=true --set webhook.hostNetwork=true --set webhook.securePort=10260`
3. configure the certificate issuers
   <sub>be sure to forward port 80 for the cert challenge</sub>

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
          class: nginx
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
          class: nginx
EOF
```

## install unifi-controller

1. create namespace
    - `kubectl create ns unifi`
2. apply pv and pvc
    - `kubectl apply -f unifi/unifi.pv.yml`
    - `kubectl apply -f unifi/unifi.pvc.yml`
3. apply service, statefulset and ingress resources
    - `envsubst < unifi/unifi.service.yml | kubectl apply -f -`
    - `kubectl apply -f unifi/unifi.statefulset.yml`
    - `envsubst < unifi/unifi.ingress.yml | kubectl apply -f -`
4. allow internal access by sshing to router (e.g. edgerouterx example below)
    - `configure`
    - `set system static-host-mapping host-name <sub-domain> inet ${METAL_LB_IP1}`
    - `commit`
    - `save`
5. allow external access by forwarding `443` for nginx on router
    - TCP `443` / GUI

## install filebrowser

1. create namespace
    - `kubectl create ns filebrowser`
2. apply pvc
    - `kubectl apply -f filebrowser.pvc.yml`
3. apply service, deployment and ingress resources
    - `envsubst < filebrowser/filebrowser.service.yml | kubectl apply -f -`
    - `kubectl apply -f filebrowser/filebrowser.deployment.yml`
    - `envsubst < filebrowser/filebrowser.ingress.yml | kubectl apply -f -`
4. allow internal access by sshing to router
    - `configure`
    - `set system static-host-mapping host-name <sub-domain> inet ${METAL_LB_IP1}`
    - `commit`
    - `save`

## install media apps

1. create namespace
    - `kubectl create ns media`
2. apply pvc(s)
    - `kubectl apply -f media/media-config.pvc.yml`
    - `kubectl apply -f media/media-data.pvc.yml`
3. apply ingress
    - `envsubst < media/media.ingress.yml | kubectl apply -f -`
4. create secret for vpn
    - `envsubst < media/vpn_secret.yml | kubectl apply -f -`
5. apply transmission resources
    - `kubectl apply -f media/transmission/media.transmission.service.yml`
    - `kubectl apply -f media/transmission/media.transmission.deployment.yml`
6. create a file called `ServerConfig.json` with the following in `<nfs_path>/jackett/Jackett`:

    - ```bash
        {
            "BasePathOverride": "/jackett"
        }
      ```

7. apply jackett resources

    - `kubectl apply -f media/jackett/media.jackett.service.yml`
    - `envsubst < media/jackett/media.jackett.deployment.yml | kubectl apply -f -`

8. create a file called `config.xml` with the following in `<nfs_path>/sonarr/`:

    - ```bash
        <Config>
        <UrlBase>/sonarr</UrlBase>
        </Config>
      ```

9. apply sonarr resources

    - `kubectl apply -f media/sonarr/media.sonarr.service.yml -n media`
    - `kubectl apply -f media/sonarr/media.sonarr.deployment.yml -n media`

10. create a file called `config.xml` with the following in `<nfs_path>/radarr/`:

    - ```bash
        <Config>
        <UrlBase>/radarr</UrlBase>
        </Config>
      ```

11. apply radarr resources
    - `kubectl apply -f media/radarr/media.radarr.service.yml -n media`
    - `kubectl apply -f media/radarr/media.radarr.deployment -n media`
12. get claim token by visiting [plex](plex.tv/claim).
13. apply plex resources
    - `envsubst < media/plex/media.plex.service.yml | kubectl apply -f -`
    - `envsubst < media/plex/media.plex.deployment.yml | kubectl apply -f -`
14. configuring jackett
    - add indexers to jackett
    - keep notes of the category #s as those are used in radarr and sonarr
15. configuring radarr and sonarr
    - configure the connection to transmission in settings under `Download Client` > `+` (add transmission) using the hostname and port `transmission.media:80`
    - add indexers in settings under `Indexers` > `+` (add indexer)
        - add the URL / `http://media.${METAL_LB_IP1}.nip.io/jackett/api/v2.0/indexers/<name>/results/torznab/`, API key (found in jackett) and categories (e.g. `2000` for movies and `5000` for tv)

## install nfs-provisioner

<sub>this is an optional step if you'd like the creation of persistent volume claims to be automated.</sub>

1. add the nfs-provisioner repo
    - `helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner`
2. ensure the correct values are present in the `nfs-provisioner/*.values.yml` file(s)
3. install nfs-provisioner for each respective nfs path:
    - `envsubst < nfs-provisioner/media.storage.values.yml | helm install nfs-subdir-external-provisioner-media nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --namespace nfs-provisioner --values -`
    - `nfs-provisioner/rpik3s-config.storage.values.yml | helm install nfs-subdir-external-provisioner-rpik3s nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --namespace nfs-provisioner --values -`
4. finally, apply pvcs w/ the appropriate `storageClass` (e.g. `nfs-rpik3s` / `nfs-media`) and watch them provision automatically

## install [system-upgrade-controller](https://docs.k3s.io/upgrades/automated)

1. apply system-upgrade-controller

-   `kubectl apply -f system-upgrade/system-upgrade-controller.yml`

2. taint the master node to allow the controller to run:

-   `kubectl taint node kube-master CriticalAddonsOnly=true:NoExecute`

3. confirm taint(s): - `kubectl get node kube-master -o=jsonpath='{.spec.taints}'`

4. when ready to update the images used in the `system-upgrade/config.yml` file and then apply:

-   `kubectl apply -f system-upgrade/config.yml`

## install ninjam-server

1. apply ninjam-server
    - `kubectl apply -f ninjam-server/ninjam.pv.yml`
    - `kubectl apply -f ninjam-server/ninjam.pvc.yml`
    - `envsubst < ninjam-server/ninjam.service.yml | kubectl apply -f -`
    - `envsubst < ninjam-server/ninjam.ingress.yml | kubectl apply -f -`
    - `envsubst < ninjam-server/ninjam.configmap.yml | kubectl apply -f -`
    - `kubectl apply -f ninjam-server/ninjam.deployment.yml`
    - `kubectl apply -f ninjam-server/ninjam.cronjob.yml`

## install soulseek

1. apply soulseek
    - `kubectl apply -f soulseek/soulseek-config.pvc.yml`
    - `kubectl apply -f soulseek/soulseek-data.pvc.yml`
    - `envsubst < soulseek/soulseek.service.yml | kubectl apply -f -`
    - `kubectl apply -f soulseek/soulseek.deployment.yml`

## install changedetection

1. apply changedetection
    - `kubectl apply -f changedetection/change.pv.yml`
    - `kubectl create namespace changedetection`
    - `kubectl apply -f changedetection/change.pvc.yml`
    - `envsubst < changedetection/change.service.yml | kubectl apply -f -`
    - `kubectl apply -f changedetection/selenium.service.yml`
    - `kubectl apply -f changedetection/selenium.deployment.yml`
    - `kubectl apply -f changedetection/change.deployment.yml`

## backups

make a copy of `/var/lib/rancher/k3s/server/`

## debugging

-   `journalctl -u k3s.service -e` last logs of the server
-   `journalctl -u k3s-agent.service -e` last logs of the agent

## todos

-   implement:
    -   [flux](https://fluxcd.io/) / [argocd](https://argoproj.github.io/cd/)
    -   [home assistant](https://www.home-assistant.io/)
