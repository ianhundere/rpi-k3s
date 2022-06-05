# rpi-k3s

Earlier in the year, I built a small Raspberry Pi using a Compute Module 3+ that runs openVPN and Kodi on boot. I figured I ought to start playing with Kubernetes at home since I play with it all day at work. So I built a Kubernetes Raspberry Pi cluster with 4 Raspberry Pi 4s each with 4GB RAM. I learned a lot and managed to get everything up and running without too much hair pulling. I currently have NextCloud and a UniFi Controller configured, but hope to add further applications in the future such as Plex, Bitwarden, and video security software integrated with unlocked Wyze cameras. Some of the lessons I learned were things I've learned at work, but they're always good reminders.

##### Lessons Learned

-   Assume nothing
-   Document everything
-   It often pays to know and understand the why behind something working (or not working) before moving on

## initial setup

1. download latest vers of buster-lite (e.g. https://downloads.raspberrypi.org/raspios_lite_armhf_latest)
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
    - ```
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

## configure nfs storage

1. list all connected devices and find the correct drive:
    - `sudo fdisk -l`
2. create partition
    - `sudo mkfs.ext4 /dev/sda1`
3. mount the disk manually
    - `sudo mkdir /mnt/ssd`
    - `sudo chown -R pi:pi /mnt/ssd/`
    - `sudo mount /dev/sda1 /mnt/ssd`
4. configure disk to automatically mount
    - find the uuid of your mounted drive
        - `sudo blkid`
    - add the following with the correct uuid to `/etc/fstab`
        - `UUID=23e4863c-6568-4dd1-abde-0b128a81b0ba /mnt/ssd ext4 defaults 0 0`
    - reboot and make sure the drive has mount
        - `df -ha /dev/sda1`
5. configure nfs
    - install nfs on master
        - `sudo apt-get install nfs-kernel-server -y`
    - add the following to `/etc/exports`
        - `/mnt/ssd *(rw,no_root_squash,insecure,async,no_subtree_check,anonuid=1000,anongid=1000)`
    - start the nfs server
        - `sudo exportfs -ra`
    - install nfs on workers
        - `sudo apt-get install nfs-common -y`
    - create directory to mount nfs share
        - `sudo mkdir /mnt/ssd`
        - `sudo chown -R pi:pi /mnt/ssd/`
    - configure disk to automatically mount by adding the master's ip etc to `/etc/fstab`
        - `sudo vi /etc/fstab`
        - `<master_ip>:/mnt/ssd /mnt/ssd nfs rw 0 0`

## configure k3s master node

1. ssh to master node
    - `ssh pi@kube-master`
2. if you're not root, you'll want to enable to ability to write to the k3s config file `/etc/rancher/k3s/k3s.yaml`. you'll also want to tell k3s not to deploy its default load balancer, servicelb, and proxy, traefik, since we'll install metalb as load balancer and nginx as proxy manually later on. finally we want to run the k3s installer
    - `export K3S_KUBECONFIG_MODE="644"; export INSTALL_K3S_EXEC="--no-deploy servicelb --no-deploy traefik --kubelet-arg=image-gc-high-threshold=85 --kubelet-arg=image-gc-low-threshold=80"; curl -sfL https://get.k3s.io | sh -`
3. verify the master is up
    - `sudo systemctl status k3s`
    - `kubectl get nodes -o wide`
    - `kubectl get pods -A -o wide`
4. taint the master node to avoid deploying to it / save resources for orchestration
    - `kubectl taint node kube-master node-role.kubernetes.io/master:NoSchedule`
5. save the access token to configure the agents
    - `sudo cat /var/lib/rancher/k3s/server/node-token`

## configure k3s worker nodes

1. ssh to work node
    - `ssh pi@kube-worker1`
2. set permissions on config file, set the endpoint for the agent, set the token saved from configuring the k3s master node, and run the k3s installer
    - `export K3S_KUBECONFIG_MODE="644"; export K3S_URL="https://<master_ip:6443"; export K3S_TOKEN=<master_node_token>; export INSTALL_K3S_EXEC="--kubelet-arg=image-gc-high-threshold=85 --kubelet-arg=image-gc-low-threshold=80"; curl -sfL https://get.k3s.io | sh -`
3. verify agent is up
    - `sudo systemctl status k3s-agent`
    - `kubectl get nodes -o wide`
    - `kubectl get pods -A -o wide`
4. label the worker nodes
    - `kubectl label node <worker_name> node-role.kubernetes.io/node=""`

###### uninstall

1. master
    - `sudo /usr/local/bin/k3s-agent-uninstall.sh`
2. workers
    - `sudo rm -rf /var/lib/rancher`

## connect remotely to cluster

1. install `kubectl` if it's not already installed local computer, [Install Guide](https://kubernetes.io/docs/tasks/tools/install-kubectl/).
2. create the necessary directory and file
    - `mkdir ~/.kube/`
    - `touch ~/.kube/config`
3. copy the file using `scp`
    - `scp pi@<master_ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config`
4. you can either simply edit the `config` file and locate `127.0.0.1` and replace it with the IP address of the master node or use `sed`
    - `sed -i '' 's/127\.0\.0\.1/192\.168\.1\.1/g' ~/.kube/config`

## install metallb - k8s load balancer

1. create the `metallb-system` namespace
    - `kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.11.0/manifests/namespace.yaml`
2. apply the metallb manifest which includes the controller deployment, speaker daemonset and necessary service accounts for the controller and speaker, along with the RBAC permissions that everything need to function
    - `kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.11.0/manifests/metallb.yaml`
3. create the memberlist secret contains the secretkey to encrypt the communication between speakers for the fast dead node detection.
    - `kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)`
4. apply the `ConfigMap` which will indicate what protocol (e.g. `layer2`) and IPs to use.
    - `kubectl apply -f config.yml`

## install nginx - web proxy

1. install helm
    - `brew install helm`
2. add the nginx repo / update repo
    - `helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx; helm repo update`
3. install nginx
    - `helm install nginx-ingress ingress-nginx/ingress-nginx --set defaultBackend.enabled=false -n kube-system`

## install cert-manager

1. create namespace
    - `kubectl create ns cert-manager`
2. add the cert-manager repo / update repo
    - `helm repo add jetstack https://charts.jetstack.io; helm repo update`
3. install cert-manager
    - `helm install cert-manager jetstack/cert-manager -n cert-manager --set installCRDs=true`
4. configure the certificate issuers

###### prod

```
$ cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1alpha2
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

###### staging

```
$ cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1alpha2
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
2. create the NFS directory on the master node
    - `cd /mnt/ssd && sudo mkdir unifi`
3. apply yaml
    - `kubectl apply -f unifi -n unifi`
4. allow internal access by sshing to router
    - `configure`
    - `set system static-host-mapping host-name <sub-domain> inet ${METAL_LB_IP1}`
    - `commit`
    - `save`
5. allow external access by forwarding the following ports on router to LB (e.g. `${METAL_LB_IP1}`)
    - `3478` UDP / STUN
    - `10001` UDP / device discovery
    - `8080` TCP / device and controller communication
    - `8443` TCP / controller GUI/API
    - `8843` TCP / HTTPS portal redirection
    - `8880` TCP / HTTP GUI portal redirection
    - `6789` TCP / throughput test

## install nextcloud

1. create namespace
    - `kubectl create ns nextcloud`
2. create the NFS directory on the master node
    - `cd /mnt/ssd && sudo mkdir nextcloud`
3. apply pv and pvc
    - `kubectl apply -f nextcloud.persistentvolume.yml`
    - `kubectl apply -f nextcloud.persistentvolumeclaim.yml`
4. update values in `nextcloud.values.yml`
    - ```nextcloud:
        host: "<sub-domain>"
        username: <changeme>
        password: <changeme>
      ```
    - ```persistence:
        enabled: true
        existingClaim: "nextcloud-ssd"
        accessMode: ReadWriteOnce
        size: "60Gi"
      ```
5. add repo
    - `helm repo add nextcloud https://nextcloud.github.io/helm/`
6. apply `nextcloud.values.yml`
    - `helm install nextcloud nextcloud/nextcloud --values nextcloud.values.yml -n nextcloud`
7. allow internal access by sshing to router
    - `configure`
    - `set system static-host-mapping host-name <sub-domain> inet ${METAL_LB_IP1}`
    - `commit`
    - `save`
8. allow external access by forwarding the following ports on router
    - TCP `443` / GUI
    - TCP `80` / GUI
9. apply ingress
    - `kubectl apply -f nextcloud.ingress.yml`
10. add files manually via scp / run `occ` to add them to the db:
    - `scp -r <files> pi@kube-master:~`
    - `kubectl exec -it <nextcloud_pod_name> bash -n nextcloud`
    - `sudo -u www-data php /var/www/html/occ files:scan --path "<user_id/files>"`

## install plex

1. create namespace
    - `kubectl create ns media`
2. create the NFS directory on the master node
    - `cd /mnt/ssd && sudo mkdir media`
3. apply pv and pvc
    - `kubectl apply -f media.persistentvolume*.yml`
4. create secret for vpn
    - `kubectl create secret generic openvpn --from-literal='username=<VPN_USERNAME>' --from-literal='password=<VPN_PASSWORD>' -n media`
5. apply transmission resources
    - `kubectl apply -f media/transmission/media.transmission* -n media`
6. create the NFS directory on the master node
    - `mkdir -p /mnt/ssd/media/configs/jackett/openvpn/`
7. create a file called `credentials.conf` in `/mnt/ssd/media/configs/jackett/openvpn/` with:
    - ```
        <VPN_USERNAME>
        <VPN_PASSWORD>
      ```
8. create the NFS directory on the master node
    - `mkdir -p /mnt/ssd/media/configs/jackett/Jackett/`
9. create a file called `ServerConfig.json` with:
    - ```
        {
            "BasePathOverride": "/jackett"
        }
      ```
10. apply jackett resources
    - `kubectl apply -f media/jackett -n media`
11. create the NFS directory on the master node
    - `mkdir -p /mnt/ssd/media/configs/sonarr/`
12. create a file called `config.xml` with:
    - ```
        <Config>
        <UrlBase>/sonarr</UrlBase>
        </Config>
      ```
13. apply sonarr resources
    - `kubectl apply -f media/sonarr -n media`
14. create the NFS directory on the master node
    - `mkdir -p /mnt/ssd/media/configs/radarr/`
15. create a file called `config.xml` with:
    - ```
        <Config>
        <UrlBase>/sonarr</UrlBase>
        </Config>
      ```
16. apply radarr resources
    - `kubectl apply -f media/radarr -n media`
17. get claim token by visiting [plex](plex.tv/claim).
18. apply plex resources
    - `kubectl apply -f media/plex -n media`
19. configuring jackett
    - add indexers to jackett
    - keep notes of the category #s as those are used in radarr and sonarr
20. configuring radarr and sonarr
    - configure the connection to transmission in settings under `Download Client` > `+` (add transmission) using the hostname and port `transmission-transmission-openvpn.media:80`
    - add indexers in settings under `Indexers` > `+` (add indexer)
        - add the URL / `http://media.${METAL_LB_IP1}.nip.io/jackett/api/v2.0/indexers/<name>/results/torznab/`, API key (found in jackett) and categories (e.g. `2000` for movies and `5000` for tv)

## backups

make a copy of `/var/lib/rancher/k3s/server/`

## debugging

-   `journalctl -u k3s.service -e` last logs of the server
-   `journalctl -u k3s-agent.service -e` last logs of the agent

## todos

-   create `CronJob` to backup configs directory
-   create `CronJob` to backup k3s directory
-   add home assistant
