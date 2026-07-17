# kubeconfig-refresh

keeps the local `~/.kube/config` admin cert in sync with the master.

k3s client certs are valid for 365 days. any cert that is expired, or within
90 days of expiring, is renewed automatically whenever the k3s service
restarts — the master's `/etc/rancher/k3s/k3s.yaml` stays valid, but the
copy on your workstation goes stale and `kubectl` starts failing with:

```text
error: You must be logged in to the server (the server has asked for the client to provide credentials)
```

`refresh-k3s-kubeconfig` pulls `client-certificate-data`/`client-key-data`
from the master's `k3s.yaml` over ssh, validates that the pair matches, and
rewrites the `default` user in `~/.kube/config` only when the cert actually
changed (a timestamped backup is taken first). if the master's cert is
itself within 30 days of expiry — i.e. k3s needs a restart to rotate it —
the script logs a warning instead of silently syncing a soon-to-die cert.

## requirements

- passwordless ssh to `kube-master` that works without an ssh-agent
  (systemd user services don't inherit `SSH_AUTH_SOCK`)
- passwordless sudo on the master (to read `/etc/rancher/k3s/k3s.yaml`)

## install

```bash
ln -sf "$(pwd)/refresh-k3s-kubeconfig" ~/bin/refresh-k3s-kubeconfig
cp refresh-k3s-kubeconfig.service refresh-k3s-kubeconfig.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now refresh-k3s-kubeconfig.timer
```

the timer runs monthly with `Persistent=true`, so a run missed while the
machine was off fires on next boot. rotation only happens when the k3s
service restarts, so monthly is plenty.

## check on it

```bash
systemctl --user list-timers refresh-k3s-kubeconfig.timer
journalctl --user -u refresh-k3s-kubeconfig.service
```

## manual one-off refresh

```bash
~/bin/refresh-k3s-kubeconfig
```
