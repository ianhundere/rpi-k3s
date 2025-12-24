# IRC

## Overview

This deploys [soju](https://soju.im/), a user-friendly IRC bouncer that connects to upstream IRC servers on behalf of users. Soju provides features like:

- Multi-user support with individual IRC connections
- IRCv3 extensions support
- Chat history playback
- Detached channels

Users can connect to soju using IRC clients like [senpai](https://sr.ht/~taiite/senpai/) (TUI client).

**Note**: This setup is configured for Tailscale-only access without TLS. Tailscale provides encryption, so no additional TLS is needed.

## Architecture

- **Soju bouncer**: Runs in the cluster, manages persistent IRC connections
- **IRC clients**: Run locally (e.g., senpai, weechat, irssi) and connect to soju
- **Storage**: Persistent volume for IRC logs and database
- **Access**: Exposed via Tailscale (hostname: `soju`) for secure remote access
- **Encryption**: Provided by Tailscale, no additional TLS needed

## Deployment

Resources are managed by Flux GitOps. Changes to manifests in `apps/irc/` are automatically reconciled by Flux.

### Manual Operations

#### Create Admin User

After initial deployment, create an admin user:

```bash
kubectl exec -it -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user create \
  -admin -username admin -password "YourSecurePassword"
```

#### Add IRC Networks

Add networks via command line:

```bash
# Add Libera.Chat network
kubectl exec -it -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user run admin \
  network create -addr irc.libera.chat:6697 -name libera

# Configure SASL authentication
kubectl exec -it -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user run admin \
  sasl set-plain -network libera YourNick YourPassword

# Check network status
kubectl exec -it -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user run admin network status
```

## Client Configuration

### Senpai (TUI Client)

Connect via Tailscale. Create `~/.config/senpai/senpai.scfg`:

```scfg
address soju:6667
nickname YourNick
username admin@laptop
password YourSojuPassword
tls false

# Optional: Specify network
# username admin/libera@laptop
```

### Multi-Network Setup

To connect to multiple networks, specify the network in your username:

```scfg
# For Libera.Chat
username admin/libera@laptop

# For another network
username admin/irc.esper.net@laptop
```

**Note**: Make sure your device is connected to Tailscale to access the `soju` hostname.

## Management

### User Management

```bash
# Create user
kubectl exec -it -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user create \
  -username USERNAME -password "PASSWORD"

# Update password
kubectl exec -it -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user update USERNAME \
  -password "NEW_PASSWORD"

# List users
kubectl exec -it -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user status
```

### Network Management via BouncerServ

After connecting to soju with your IRC client, use BouncerServ commands:

```irc
# Add a network
/msg BouncerServ network create -addr irc.libera.chat:6697 -name libera

# Update network settings
/msg BouncerServ network update libera -nick NewNickname

# Enable/connect to network
/msg BouncerServ network update libera -enabled true

# List networks
/msg BouncerServ network status

# Configure SASL
/msg BouncerServ sasl set-plain libera YourNick YourPassword

# Add channels
/msg BouncerServ channel create #channel/irc.libera.chat -detached false

# List channels
/msg BouncerServ channel status
```

### Common BouncerServ Commands

```irc
help [command]                       - Show help
network create -addr <host:port>     - Add network
network update <name> [options]      - Update network
network delete <name>                - Remove network
network status                       - Show all networks
channel create <name>                - Add channel
channel update <name> [options]      - Update channel
channel delete <name>                - Remove channel
sasl set-plain <network> <user> <pw> - Configure SASL
sasl status                          - Show SASL status
```

## Maintenance

### Backup Database

```bash
# Backup SQLite database
kubectl exec -n irc deployment/soju -- \
  sqlite3 /var/lib/soju/soju.db .dump > soju-backup.sql

# Or copy entire database file
kubectl cp -n irc \
  $(kubectl get pods -n irc -l app=soju -o jsonpath='{.items[0].metadata.name}'):/var/lib/soju/soju.db \
  ./soju.db.backup
```

### Restore from Backup

```bash
# Restore from SQL dump
kubectl cp ./soju-backup.sql -n irc \
  $(kubectl get pods -n irc -l app=soju -o jsonpath='{.items[0].metadata.name}'):/tmp/
kubectl exec -n irc deployment/soju -- \
  bash -c "cat /tmp/soju-backup.sql | sqlite3 /var/lib/soju/soju.db"

# Restart deployment
kubectl rollout restart -n irc deployment/soju
```

### Check Logs

```bash
# View soju logs
kubectl logs -n irc -l app=soju --tail=100 -f

# Check database integrity
kubectl exec -n irc deployment/soju -- \
  sqlite3 /var/lib/soju/soju.db "PRAGMA integrity_check;"
```

### Troubleshooting

#### Connection Issues

```bash
# Check pod status
kubectl get pods -n irc

# Check service endpoints
kubectl get endpoints -n irc

# Test connectivity
kubectl exec -n irc deployment/soju -- ping irc.libera.chat

# Check network status
kubectl exec -n irc deployment/soju -- \
  sojuctl -config /etc/soju/config user run admin network status
```


## Channel Management with ChanServ

For networks like Libera.Chat, use ChanServ to manage registered channels:

```irc
# Register channel (requires network account)
/msg ChanServ REGISTER #channel

# Persistent topics
/msg ChanServ SET #channel TOPICLOCK ON
/msg ChanServ TOPIC #channel Your persistent topic

# Channel settings
/msg ChanServ SET #channel GUARD ON    # Make ChanServ join
/msg ChanServ SET #channel SECURE ON   # Only registered users

# View channel info
/msg ChanServ INFO #channel

# Access management
/msg ChanServ FLAGS #channel user +votirsf  # Full access
/msg ChanServ ACCESS #channel LIST          # List access
```

## Access via Tailscale

The soju service is exposed via Tailscale with hostname `soju`. You can connect from any device on your Tailnet:

```bash
# From any Tailscale-connected device
irc://soju:6667          # IRC (encrypted by Tailscale)
```

No TLS configuration needed - Tailscale provides the encryption layer.

## References

- [Soju Documentation](https://soju.im/)
- [Senpai Documentation](https://git.sr.ht/~taiite/senpai)
- [IRC Protocol](https://modern.ircdocs.horse/)
