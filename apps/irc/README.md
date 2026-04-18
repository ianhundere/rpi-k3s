# irc

[soju](https://soju.im/) IRC bouncer — maintains persistent connections to upstream networks (Libera, etc.) so clients can drop in and out without missing history.

## access

| method    | address                      | notes                                   |
|-----------|------------------------------|-----------------------------------------|
| public    | `ircs://irc.clusterian.pw:6697` | Let's Encrypt via envoy TLS passthrough |
| tailscale | `irc://soju:6667`            | plaintext, encrypted by the tailnet     |

Pair with any IRC client — [senpai](https://sr.ht/~taiite/senpai/), weechat, irssi.

## architecture

- **soju** — bouncer, SQLite DB + filesystem message store on a PVC
- **TLS** — cert-manager issues for `irc.clusterian.pw`; envoy-gateway terminates at the edge via passthrough
- **Tailscale** — service annotated for tailnet exposure as hostname `soju`
- deployed via flux; see root [README](../../README.md)

## client config (senpai)

`~/.config/senpai/senpai.scfg`:

```scfg
address irc.clusterian.pw:6697
nickname YourNick
username admin@laptop
password YourSojuPassword
tls true
```

Multi-network — append the network to username: `admin/libera@laptop`.

## admin (sojuctl)

Run inside the pod — `sojuctl` writes directly to soju's control socket.

```bash
alias sojuctl='kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config'

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

```bash
# dump
kubectl exec -n irc deployment/soju -- \
  sqlite3 /var/lib/soju/soju.db .dump > soju-backup.sql

# restore
kubectl cp ./soju-backup.sql irc/$(kubectl get pod -n irc -l app=soju -o name | cut -d/ -f2):/tmp/
kubectl exec -n irc deployment/soju -- \
  sh -c 'sqlite3 /var/lib/soju/soju.db < /tmp/soju-backup.sql'
kubectl rollout restart -n irc deployment/soju
```

## troubleshooting

```bash
kubectl logs -n irc -l app=soju --tail=100 -f
kubectl exec -n irc deployment/soju -- sqlite3 /var/lib/soju/soju.db "PRAGMA integrity_check;"
kubectl exec -n irc deployment/soju -- ping irc.libera.chat
```

## references

- [soju docs](https://soju.im/)
- [senpai docs](https://git.sr.ht/~taiite/senpai)
- [modern IRC spec](https://modern.ircdocs.horse/)
