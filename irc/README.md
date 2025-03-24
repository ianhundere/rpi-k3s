# irc

## soju

- Server: soju
- Port: 6667
- Username: admin
- Password: New-Strong-Password-456

### via cmd line

add networks directly from the command line:

```bash
# add network for the admin user
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user run admin network create -addr irc.libera.chat:6697 -name libera

# configure sasl authentication
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user run admin sasl set-plain -network libera YourUsername YourPassword

# check network status
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user run admin network status

# check sasl status
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user run admin sasl status
```

### admin user mgmt

The admin user is automatically created during deployment. To manage users:

```bash
# create a new admin user
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user create -admin -username admin -password "Your-Password"

# update user password
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user update admin -password "New-Password"

# check user status
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user status
```

### bouncer/soju mgmt w/ BouncerServ

Soju provides both IRC commands (via the BouncerServ service) and command-line commands. Commands in IRC can be abbreviated (e.g., "network" as "net" or just "n").

### cmds

send cmds via `/msg BouncerServ <command> [args...]` after connecting:

#### help

```shell
help [command]                       - Show help for all commands or specific command
```

#### channel

```text
channel create <name> [options]       - Create a channel to auto-join
  -detached true|false                - Set whether channel should be auto-joined
  -relay-detached default|none|highlight|message
  -reattach-on default|none|highlight|message
  -detach-after <duration>
  -detach-on default|none|highlight|message
channel delete <channel>              - Remove a channel from auto-join
channel list                          - List all channels
channel update <channel> [options]    - Update channel settings
channel status                        - Show status of all channels
```

Note: When creating channels, they are added to the default network unless specified. To add channels to specific networks, use the network quote command to join them first.

```bash
channel create <network> <channel>               - Add channel to auto-join
channel delete <network> <channel>               - Remove channel from auto-join
channel status                                   - Show channel status
channel update <network> <channel> [options]     - Update channel settings
```

#### sasl authentication

```shell
sasl status [network]                - Show SASL status for all networks or specific one
sasl set-plain <network> <username> <password> - Set SASL PLAIN credentials
sasl reset <network>                 - Clear SASL settings
```

#### cert fingerprint

```shell
certfp fingerprint                   - Show your client certificate fingerprint
certfp generate                      - Generate a client certificate
```

### cli cmds

Run these commands with `kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config <command>`:

#### user mgmt

```bash
user create -username <username> [-admin] [-password <password>] - Create a new user
user update <username> [-password <password>]    - Update a user
user delete <username>                           - Delete a user
user status                                      - Show status of all users
```

#### user cmd exec

```bash
user run <username> <command>                    - Run a command as a user
```

With `user run <username>`, you can access these additional commands:

#### network

```text
network create -addr <addr> [options]  - Connect to a new IRC network
  -name <name>                       - Set a short name for the network
  -username <username>               - Connect with specified username
  -pass <password>                   - Connect with server password
  -realname <realname>               - Connect with specified real name
  -certfp <fingerprint>              - Use certificate fingerprint for TLS
  -nick <nickname>                   - Connect with specified nickname
  -auto-away true|false              - Enable/disable auto-away feature
  -enabled true|false                - Enable/disable the network
  -connect-command <command>         - Send raw command after connecting

network list                         - List all networks
network status [name]                - Show status for all networks or specified one
network update [name] [options]      - Update network settings (same options as create)
network delete <name>                - Delete a network
network connect <name>               - Connect to a network
network disconnect <name>            - Disconnect from a network
network quote <network> <command>                - Send raw IRC command to network
```

#### sasl

```bash
sasl status [network]                            - Show SASL status
sasl set-plain -network <network> <username> <password> - Set SASL credentials
sasl reset -network <network>                    - Clear SASL settings
```

#### Server Commands

```bash
server status                                    - Show server status
server notice <message>                          - Send notice to all connected users
server debug                                     - Show server debug information
```

#### Certificate Management

```text
certfp fingerprint                               - Show certificate fingerprint
certfp generate                                  - Generate client certificate
```

##### examples

create network and connect:

```shell
/msg BouncerServ network create -addr irc.libera.chat:+6697 -name libera -username YourNickname -pass YourPassword
```

```shell
network create -addr ircs://irc.libera.chat:6697 -name LiberaChat -nick YourNickname -enabled true -connect-command "PRIVMSG NickServ :IDENTIFY YourPassword"
```

```shell
network update LiberaChat -nick NewNickname -auto-away false
```

to enable the network and connect:

```shell
/msg BouncerServ network update libera -enabled true
```

configure SASL authentication:

```shell
/msg BouncerServ sasl set-plain libera YourAccount YourPassword
```

adding another network:

```shell
/msg BouncerServ network create -addr irc.esper.net -nick YourNickname
/msg BouncerServ network update irc.esper.net -enabled true
```

to resolve nickname errors:

```shell
connection error: failed to register: registration error (432): Erroneous Nickname
```

update nickname:

```shell
/msg BouncerServ network update irc.esper.net -nick ValidNickname
```

add channels to default network:

```shell
/msg BouncerServ channel create #quixit/irc.libera.chat -detached false
```

`-detached false` makes the channel auto-join when connecting.

check configured channels:

```shell
/msg BouncerServ channel status
```

add channel to non-default network, first join the channel:

```shell
/msg BouncerServ network quote "network-name" "JOIN #channelname"
```

ex:

```shell
/msg BouncerServ network quote "irc.esper.net" "JOIN #elektronauts"
```

> note: network must be connected before you can send commands to it.

## channel mgmt w/ ChanServ

When you have registered channels on IRC networks like Libera.Chat, you can use ChanServ services to maintain persistent channel settings, particularly useful when using a bouncer like soju.

### persistent topics

To ensure your channel topic persists through network disconnections and bouncer restarts:

```irc
/msg ChanServ SET #channel TOPICLOCK ON
/msg ChanServ TOPIC #channel Your persistent topic here
```

When TOPICLOCK is ON:

- Only users with appropriate channel privileges can change the topic
- The topic persists through server restarts and network splits
- ChanServ automatically restores the topic when reconnecting after disruptions

### common cmds

```irc
# Channel registration (requires network account)
/msg ChanServ REGISTER #channel

# Channel access management
/msg ChanServ FLAGS #channel user +votirsf  # Give full access
/msg ChanServ FLAGS #channel user +AO       # Add as admin and founder
/msg ChanServ FLAGS #channel user +o        # Give operator status

# Channel settings
/msg ChanServ SET #channel GUARD ON         # Make ChanServ join the channel
/msg ChanServ SET #channel SECURE ON        # Only registered users can join
/msg ChanServ SET #channel MLOCK +nt        # Lock channel modes

# View settings
/msg ChanServ INFO #channel                 # Show channel information
/msg ChanServ ACCESS #channel LIST          # List users with access

# Op commands
/msg ChanServ OP #channel                   # Get op status
/msg ChanServ DEOP #channel                 # Remove op status
```

### mode cmds

Common channel modes:

- `+t`: Only ops can change topic
- `+n`: No external messages
- `+s`: Secret channel (not visible in lists)
- `+i`: Invite only
- `+m`: Moderated (only voiced users can speak)
- `+k password`: Set channel password
- `+l limit`: Set user limit

Set modes with:

```irc
/mode #channel +modes
```

Example:

```irc
/mode #channel +nt-s
```

For bans and exceptions:

```irc
/mode #channel +b *!*@hostname    # Ban users from hostname
/mode #channel +e *!*@hostname    # Create exception to ban
/mode #channel +I *!*@hostname    # Allow user to join invite-only channel
```

## the lounge

create first user:

```bash
# admin user
kubectl exec -it -n irc deployment/lounge -- thelounge add <username>
```

manage users:

```bash
# List all users
kubectl exec -it -n irc deployment/lounge -- thelounge list

# check user pw
kubectl exec -it -n irc deployment/lounge -- thelounge reset <username>

# remove user
kubectl exec -it -n irc deployment/lounge -- thelounge remove <username>
```

### halloy client config

To configure Halloy client to connect to multiple networks through the bouncer:

```toml
[servers.libera]
nickname = "YourNick"
username = "admin/irc.libera.chat@desktop"
server = "irc.clusterian.pw"  # Your soju server address
port = 6667
password = "admin"
channels = ["#channel1"]
use_tls = false
chathistory = true

[servers.esper]
nickname = "YourNick"
username = "admin/irc.esper.net@desktop"
server = "irc.clusterian.pw"  # Your soju server address
port = 6667
password = "admin"
channels = ["#elektronauts"]
use_tls = false
chathistory = true
```

## maintenance

### soju backup

sqlite db located at `/var/lib/soju/soju.db`. to backup:

```bash
# db backup
kubectl exec -it -n irc deployment/soju -- sqlite3 /var/lib/soju/soju.db .dump > soju-backup.sql

# or, copy the entire db file
kubectl cp -n irc $(kubectl get pods -n irc -l app=soju -o jsonpath='{.items[0].metadata.name}'):/var/lib/soju/soju.db ./soju.db.backup
```

### restore from backup

```bash
# restore from sql dump
kubectl cp ./soju-backup.sql -n irc $(kubectl get pods -n irc -l app=soju -o jsonpath='{.items[0].metadata.name}'):/tmp/
kubectl exec -it -n irc deployment/soju -- bash -c "cat /tmp/soju-backup.sql | sqlite3 /var/lib/soju/soju.db"

# or, restore the entire db file
kubectl cp ./soju.db.backup -n irc $(kubectl get pods -n irc -l app=soju -o jsonpath='{.items[0].metadata.name}'):/var/lib/soju/soju.db
kubectl rollout restart -n irc deployment/soju
```

#### Database Corruption

```bash
# run integrity check
kubectl exec -it -n irc deployment/soju -- sqlite3 /var/lib/soju/soju.db "PRAGMA integrity_check;"

# if corrupted, restore from backup or create a new one
```

#### connectivity issues

```bash
# check outbound connections
kubectl exec -it -n irc deployment/soju -- ping irc.libera.chat

# check network status
kubectl exec -it -n irc deployment/soju -- sojuctl -config /etc/soju/config user run admin network status
```

#### permission issues

```bash
# if you see "failed to open database: permission denied" errors in logs
kubectl logs -n irc -l app=soju

# fix by ensuring proper fsgroup in deployment spec
securityContext:
  fsGroup: 1000
```

### logs

increase verbosity for troubleshooting:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: soju-config
  namespace: irc
data:
  soju.conf: |
    # Other configuration settings
    log-level = debug
    # Rest of your config
```
