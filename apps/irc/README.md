# irc

[soju](https://soju.im/) IRC bouncer — maintains persistent connections to upstream networks (Libera, etc.) so clients can drop in and out without missing history.

## access

Public TLS only: `ircs://irc.clusterian.pw:443` (Let's Encrypt cert via envoy TLS passthrough — non-standard port because the envoy LB only exposes 80/443; SNI routes the hostname to soju).

Pair with any IRC client — [senpai](https://sr.ht/~taiite/senpai/), weechat, irssi.

## architecture

- **soju** — bouncer, SQLite DB + filesystem message store on a PVC
- **TLS** — cert-manager issues `irc.clusterian.pw` into the irc namespace (Certificate `soju-cert`, Secret `soju-tls`), envoy passes 443 through by SNI without terminating it, soju terminates with the mounted cert on 6697, and a busybox sidecar SIGHUPs soju on renewal
- deployed via flux; see root [README](../../README.md)

## client config (senpai)

`~/.config/senpai/senpai.scfg`:

```scfg
address irc.clusterian.pw:443
tls true
nickname YourNick
username admin@laptop
password YourSojuPassword
```

Multi-network — append the network to username: `admin/libera@laptop`.

## admin (sojuctl)

Run inside the pod — `sojuctl` writes directly to soju's control socket.

```bash
alias sojuctl='kubectl exec -it -n irc deployment/soju -c soju -- sojuctl -config /etc/soju/config'

# bootstrap the first admin
sojuctl user create -admin -username admin -password "..."

# add / manage users
sojuctl user create -username USER -password "..."
sojuctl user update USER -password "..."
sojuctl user status

# add a network for a user
sojuctl user run admin network create -addr irc.libera.chat:6697 -name libera
sojuctl user run admin sasl set-plain -network libera Nick Password
sojuctl user run admin network status
```

## user-side (BouncerServ)

Once connected via an IRC client, `/msg BouncerServ` controls your own networks and channels:

```irc
network create -addr irc.libera.chat:6697 -name libera
network update libera -nick NewNick -enabled true
network status
channel create #channel/libera -detached false
sasl set-plain libera Nick Password
help [command]
```

## channel management (ChanServ)

For networks like Libera, ChanServ handles registered-channel ops:

```irc
/msg ChanServ REGISTER #channel
/msg ChanServ SET #channel TOPICLOCK ON
/msg ChanServ SET #channel GUARD ON         # ChanServ joins the channel
/msg ChanServ SET #channel SECURE ON        # only registered users
/msg ChanServ FLAGS #channel user +votirsf  # full access
/msg ChanServ INFO #channel
```

## backup & restore

the image has no shell of its own and no sqlite3. soju's db, message logs and log file live on the pvc, which is the nas dir `/volume3/rpi-k3s/irc/soju/` (`soju.db`, `logs/`, `soju.log`) — back up and restore there, not through the pod. the nas-side backup of `/volume3/rpi-k3s` includes it (see the root readme).

to restore: set `replicas: 0` on the deployment in git and push (flux owns the replica count, so `kubectl scale` gets reverted), copy `soju.db` back on the nas, revert the commit.

## troubleshooting

```bash
kubectl logs -n irc -l app=soju -c soju --tail=100 -f
kubectl delete pod -n irc -l app=soju        # not rollout restart — flux double-bounces
kubectl exec -n irc deployment/soju -c soju -- sojuctl -config /etc/soju/config user status
kubectl exec -it -n irc deployment/soju -c soju -- /tools/busybox sh   # staged busybox; still no sqlite3
```

## references

- [soju docs](https://soju.im/)
- [senpai docs](https://git.sr.ht/~taiite/senpai)
- [modern IRC spec](https://modern.ircdocs.horse/)
