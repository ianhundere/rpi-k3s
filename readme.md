- initial setup
1. download latest vers of buster-lite (e.g. https://downloads.raspberrypi.org/raspios_lite_armhf_latest)
2. flash to sd card
3. create empty ssh file under `/boot/`
    - `touch ssh`
4. connect via ssh 
    - `ssh pi@192.168.3.229`
5. configure static ip via router; you'll also want to do this via `/etc/dhcpcd.conf` file.
6. set password
    - `passwd`
7. set hostname
    - `sudo vi /etc/hostname`
8. upgrade / reboot
    - `sudo apt-get update && sudo apt-get -y dist-upgrade && sudo reboot`
9. enable container features by adding the following to `/boot/cmdline.txt`:
    - `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory`
10. edit `/etc/dhcpcd.conf`
    - ```interface eth0
         static ip_address=192.168.3.103/24
         static routers=192.168.3.1
         static domain_name_servers=192.168.3.1```
11. switch firewall to legacy config:
    - `sudo update-alternatives --set iptables /usr/sbin/iptables-legacy`
    - `sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy`
- configure nfs storage
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
    - configure disk to automatically mount
        - `sudo mkdir /mnt/ssd`
        - `sudo chown -R pi:pi /mnt/ssd/`
    - add the following to `/etc/exports`
        - `sudo vi /etc/fstab`
    - add the master's ip etc to `/etc/fstab`
        - `192.168.3.100:/mnt/ssd   /mnt/ssd   nfs    rw  0  0`
6. configure k3s master node
    - ssh to master node
        - `ssh pi@kube-master`
    - if you're not root, you'll want to enable to ability to write to the k3s config file `/etc/rancher/k3s/k3s.yaml`
        - `export K3S_KUBECONFIG_MODE="644"`
    - tell k3s not to deploy its default load balancer, servicelb, and proxy, traefik, since we'll install metalb as load balancer and nginx as proxy manually later on.
        - `export INSTALL_K3S_EXEC=" --no-deploy servicelb --no-deploy traefik"`
    - run the k3s installer
        - `curl -sfL https://get.k3s.io | sh -`
    - verify the master is up
        - `sudo systemctl status k3s`
        - `kubectl get nodes -o wide`
        - `kubectl get pods -A -o wide`
    - save the access token to configure the agents
        - `sudo cat /var/lib/rancher/k3s/server/node-token`
7. configure k3s worker nodes
    - ssh to work node
        - `ssh pi@kube-worker1`
    - set permissions on config file.
        - `export K3S_KUBECONFIG_MODE="644"`
    - set the endpoint for the agent
        - `export K3S_URL="https://192.168.3.100:6443"`
    - set the token saved from configuring the k3s master node
        - `export K3S_TOKEN="`
    - kun the k3s installer
        - `curl -sfL https://get.k3s.io | sh -`
    - verify agent is up
        - `sudo systemctl status k3s-agent`
        - `kubectl get nodes -o wide`
        - `kubectl get pods -A -o wide`
8. connect remotely to cluster
    - 