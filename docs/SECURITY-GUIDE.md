# LyreBirdAudio Security Guide

A default LyreBirdAudio node is **open on the network**: anyone who can reach TCP
port 8554 can listen to every microphone and publish streams. This guide says what a
node exposes, what each kind of attacker can do with that, and how to close it. On a
network where every device is trusted you may need none of it; on any other network
you need at least the firewall rule or the authentication mode below.

**What this guide was checked against.** Every YAML snippet was loaded by real
MediaMTX binaries (1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3), and every
claim about what a node exposes or refuses was observed on those binaries with the
real stream manager, installer and renderer, in a private network namespace
(a second address on the loopback interface stands in for a remote client).
**Not checked:** real USB hardware, a real systemd manager (units were checked with
`systemd-analyze verify` only), ARM boards, UFW, fail2ban as a running service,
WireGuard, certbot, LUKS and VLC. Commands for those are standard usage and were not
run for this guide; where this guide says "measured" or "verified" it means the
checks above.

---

## Table of Contents

1. [Security Model Overview](#security-model-overview)
2. [Quick Security Checklist](#quick-security-checklist)
3. [RTSP Authentication](#rtsp-authentication)
4. [TLS/HTTPS Encryption](#tlshttps-encryption)
5. [API Security](#api-security)
6. [Network Security](#network-security)
7. [Metrics and Alerts](#metrics-and-alerts)
8. [File System Security](#file-system-security)
9. [Log Security](#log-security)
10. [Physical Security](#physical-security)
11. [Reporting Vulnerabilities](#reporting-vulnerabilities)
12. [Security Maintenance](#security-maintenance)

---

## Security Model Overview

### What a default node listens on

The configuration the stream manager and the installer generate opens exactly these
sockets (checked on all six MediaMTX versions):

| What | Address and port | Who can use it by default |
|------|------------------|---------------------------|
| RTSP | every interface, TCP 8554 | **Anyone who can connect**: read every stream, publish to any path name made of letters, digits, `_` and `-` |
| RTSP over UDP | every interface, UDP 8000 (RTP) and 8001 (RTCP) | Same as RTSP (opened because the generated file lists `udp` among the transports) |
| Control API | `127.0.0.1`, TCP 9997 | Programs on this machine, no password. Other machines: connection refused |
| MediaMTX metrics | `127.0.0.1`, TCP 9998 | Programs on this machine, no password. Other machines: connection refused |

SRT (UDP 8890), MoQ (TCP and UDP 8892, UDP 8893, MediaMTX 1.19.0 and later), RTMP
(1935), HLS (8888) and WebRTC (8889) are switched off in the generated file, and no
stream manager or installer option turns them on. MediaMTX starts all of them by
default (read from the default configuration file of each release). The ports above are
the defaults; `MEDIAMTX_RTSP_PORT`, `MEDIAMTX_API_PORT` and `MEDIAMTX_METRICS_PORT`
change the three TCP ports.

The addresses of the API and the metrics endpoint come from
`MEDIAMTX_API_BIND` and `MEDIAMTX_METRICS_BIND` (default `127.0.0.1`; an IPv4 or
IPv6 address; empty means every interface). With an empty value MediaMTX still
answers `401` to a caller that is not on this machine, because its default policy
only authorizes the API and metrics for loopback callers. RTSP always listens on
every interface: neither the stream manager nor the installer has an option for that.

The service and the cron monitor do not inherit your shell's environment: give the
ports and the bind addresses to `lyrebird-stream-manager.sh install`, which writes them
into the unit and the cron file (`sudo env MEDIAMTX_API_PORT=19997 ./lyrebird-stream-manager.sh install`,
then restart the service). The authentication section below has the details.

`lyrebird-metrics.sh serve` is a separate listener, only while you run it (see
[Metrics and Alerts](#metrics-and-alerts)).

### Check what your node exposes

```bash
sudo ss -tulpn | grep mediamtx
```

On a node with the current configuration that prints five sockets: `0.0.0.0:8554`
(tcp), `127.0.0.1:9997` (tcp), `127.0.0.1:9998` (tcp), `0.0.0.0:8000` (udp) and
`0.0.0.0:8001` (udp); `ss` shows `*` instead of `0.0.0.0` on a host with IPv6 (not
checked here: the test machine had none). Anything else, or `9997` or `9998` on
`0.0.0.0` or `*`, means the node runs a configuration written by an earlier release; see
[Nodes set up by an earlier release](#nodes-set-up-by-an-earlier-release).
(`ss` is in the `iproute2` package.)

### What each kind of attacker can do on a default node

| Who | What they can do (observed on MediaMTX 1.15.0 and 1.21.3) |
|-----|------------------------------------------------------------|
| **A machine on the network** that can reach TCP 8554 | Listen to every stream. Publish a new stream under any name that matches the pattern above. Publish to a name that is in use: MediaMTX disconnects the current publisher and takes the path (MediaMTX's default `overridePublisher`), so the stream manager's own FFmpeg is cut off. It cannot reach the API or the metrics endpoint. |
| **Any local account** on the node | Everything above through `127.0.0.1`, **and the control API without a password**: list streams and change MediaMTX's configuration, including a path setting that makes MediaMTX run a command. MediaMTX runs it as its own user: **root** under `mediamtx-audio.service` (the stream manager), the `mediamtx` account under `mediamtx.service`. In the check, a command started by an unprivileged account (uid 65534) ran as uid 0. |
| **A publisher** (any network client in the default mode, or a compromised process on the node) | Controls the audio the node reads back. The monitor decodes every published stream with FFmpeg, as root, to measure its level (`AUDIO_LEVEL_CHECK_ENABLED`, default `true`; every `AUDIO_LEVEL_CHECK_INTERVAL` seconds). Whether a hostile stream can exploit FFmpeg was not tested. |

What closes each:

- Network attacker: [authentication](#rtsp-authentication) and a
  [firewall or VPN](#network-security). Passwords on plain RTSP cross the network
  readable, so add [TLS](#tlshttps-encryption) or a VPN.
- Local account: do not give untrusted people accounts on the node, or
  [protect the API](#api-security) (it costs health checks, see there). Even then any
  local account can still listen to and replace streams, because the manager's own
  publishers and readers use no credentials.
- Publisher: `RTSP_AUTH_MODE=local-only-publish` removes remote publishers.
  `AUDIO_LEVEL_CHECK_ENABLED=false` stops the decoding.

### Nodes set up by an earlier release

A configuration written by an earlier release keeps its old, exposed settings until
it is replaced. Check the first line and the addresses:

```bash
head -n 1 /etc/mediamtx/mediamtx.yml
grep -E '^(apiAddress|metricsAddress|srt|moq):' /etc/mediamtx/mediamtx.yml
```

| First line | Written by | What it exposes |
|------------|-----------|-----------------|
| `# Managed by LyreBirdAudio` | the current stream manager or installer | nothing beyond the table above |
| `# MediaMTX Configuration - Audio Streams` | an earlier stream manager | API (`:9997`) and metrics (`:9998`) on every interface (MediaMTX still answers `401` to other machines) |
| a row of `#`, then `# MediaMTX Configuration` | an earlier installer | the same, plus SRT (UDP 8890) and, on MediaMTX 1.19.0 and later, MoQ (TCP and UDP 8892, UDP 8893); and `paths: {}`, which makes MediaMTX refuse every publisher |
| anything else | you | whatever you wrote |

To fix it:

- **Stream manager nodes.** The first start that launches MediaMTX with the current
  release replaces the file after saving the old one (see
  [Who owns the file](#who-owns-etcmediamtxmediamtxyml)). The updater restarts the
  service, so this normally happens on update. A node that keeps running across the
  upgrade keeps its old settings; `start` on a running node changes nothing, but
  this applies the new file without restarting the manager's processes:

  ```bash
  sudo ./lyrebird-stream-manager.sh reload
  ```

  Observed: the file was replaced, a backup `mediamtx.yml.<UTC time>.00.bak` was
  saved, and the API refused connections from other addresses afterwards.
- **Installer nodes** (`mediamtx.service`). The installer never rewrites a file that
  has no `# Managed by LyreBirdAudio` first line, unless you pass `--force`:

  ```bash
  sudo ./install_mediamtx.sh --force install
  ```

  This replaces the file after saving `mediamtx.yml.backup.<date>-<time>` next to it,
  **and also** reinstalls the MediaMTX binary (the latest release; add
  `-V vX.Y.Z` to keep the version you run) and rewrites the systemd unit. To change
  only the file, make three edits by hand: set `apiAddress` and `metricsAddress` to
  `127.0.0.1:<port>`, add `srt: no`, and add `moq: no` only when
  `mediamtx --version` is 1.19.0 or later (older versions refuse to start with that
  key). MediaMTX applies the change by itself; restart it if `ss` still shows the old
  addresses. Checked: the edited file loads on 1.18.0 and 1.21.3 and opens only the
  sockets in the table above.

---

## Quick Security Checklist

### Minimal Security (Home Use)
- [ ] Keep the system updated (`sudo apt update && sudo apt upgrade`)
- [ ] Do not forward port 8554 from the internet to the node
- [ ] Know that everyone on your network can listen to the microphones and can cut a
      stream off by publishing to its name
- [ ] Run the [exposure check](#check-what-your-node-exposes) after every upgrade

### Standard Security (Remote Access or an Untrusted Network)
- [ ] Turn on [RTSP authentication](#rtsp-authentication)
- [ ] Limit TCP 8554 to the networks that need it with a [firewall](#network-security)
- [ ] Keep the API and metrics on `127.0.0.1` (the default)
- [ ] Give nobody an account on the node that you would not trust with root, or
      [protect the API](#api-security)
- [ ] Keep log rotation working (`install` writes `/etc/logrotate.d/mediamtx`)

### Enhanced Security (Field Deployment)
- [ ] All of the above, plus:
- [ ] Reach the node through a [VPN](#vpn-for-remote-access-recommended) instead of
      exposing port 8554
- [ ] Enable [TLS](#tlshttps-encryption) if passwords or audio cross a network you do
      not control and you have no VPN
- [ ] Protect [webhook URLs](#alerts) and the files in
      [File System Security](#file-system-security)
- [ ] Plan for [physical access](#physical-security)
- [ ] Schedule [updates](#security-maintenance)

---

## RTSP Authentication

The default mode is open: authentication is off until you give MediaMTX users.
Defining `authInternalUsers` **replaces** MediaMTX's built-in default users, so every
setup below keeps a password-less user for this machine: the stream manager's
publishers, health checks and the metrics exporter connect to `localhost` without
credentials and are refused (`401`) without it.

### Quick way: `RTSP_AUTH_MODE=local-only-publish`

The stream manager can write the hardened configuration for you. It renders:

- a user `any` that only `127.0.0.1` and `::1` can use, with no password, that may
  publish, read, play back and call the API and metrics (the user the manager
  itself needs);
- one read-only user (read and playback) for every line of the users file.

Everyone else gets `401`. Observed with the real manager on MediaMTX 1.21.3 (the
repository's live tests cover all six versions; they were not run for this guide): a
local publisher and reader need no credentials; a remote anonymous reader or publisher is refused; a listed user can
read; a listed user cannot publish; a wrong password is refused; the API still
answers only on this machine.

**It needs:**

1. **A users file**, `/etc/mediamtx/rtsp-users.conf` (change the path with
   `RTSP_USERS_FILE`). One line per user, `user:sha256:<hash>`, where the hash is
   the base64 of the raw SHA-256 digest of the password:

   ```bash
   printf '%s' 'the password' | openssl dgst -sha256 -binary | base64
   ```

   User names are 1 to 64 characters from `A-Z a-z 0-9 . _ @ -`; `any` is
   reserved; blank lines and lines starting with `#` are ignored. A plaintext
   password or a malformed line stops the start with an error that names the file
   and line number but does not print the line. A missing file is a warning and
   leaves only this machine with access. SHA-256 here has no salt: use long random
   passwords, and keep the file readable by root only
   (`sudo chmod 600 /etc/mediamtx/rtsp-users.conf`). The generated
   `mediamtx.yml` also holds the hashes, so the manager gives it mode 0640.
2. **`MEDIAMTX_HOST` must be a loopback name** (the default is `localhost`). With any
   other host the publishers connect from a non-loopback address and are refused;
   the manager warns.
3. **The variable must reach every process that can start MediaMTX.** That is the
   service, and also the cron monitor, which starts MediaMTX again when it has
   died by rendering the configuration again. `install` writes this setting into
   both the unit (`Environment=`) and the cron file (a `NAME=value` line), so give
   it to `install`:

   ```bash
   sudo env RTSP_AUTH_MODE=local-only-publish ./lyrebird-stream-manager.sh install
   # add -m, -f and -n on a multiplex node
   sudo systemctl restart mediamtx-audio
   ```

   Check that both files carry it:

   ```bash
   grep -n RTSP_AUTH_MODE /etc/systemd/system/mediamtx-audio.service /etc/cron.d/mediamtx-monitor
   ```

   **`install` writes what it is given and the defaults for the rest.** Run it
   again without the variable and both files silently go back to `open`: give it the
   options and settings every time. The updater's service reinstall reads them from
   the installed unit (or the cron file) and passes them on. A node installed before
   this release has the setting in neither file: run the command above once. A
   value other than `open` or `local-only-publish` stops `install` with exit 4 and
   nothing is written. Without the variable in the cron file the monitor renders an
   open configuration when it restarts MediaMTX, and the managed file silently loses
   its users (that was the behaviour before `install` carried the setting: after
   `kill -9` of MediaMTX the file had no `authInternalUsers` and anonymous remote
   publishing worked again). The tests start the monitor with only the cron file's
   assignments against a dead MediaMTX (a stand-in starts the process) and check that
   the rendered file keeps `authInternalUsers` and the node's RTSP port; the `kill -9`
   against a live MediaMTX was not repeated with `install` carrying the setting. Check
   after a restart:

   ```bash
   grep -c authInternalUsers /etc/mediamtx/mediamtx.yml     # 1 = users are in the file
   ```

   The same applies to the ports and bind addresses (`MEDIAMTX_RTSP_PORT`,
   `MEDIAMTX_API_PORT`, `MEDIAMTX_METRICS_PORT`, `MEDIAMTX_API_BIND`,
   `MEDIAMTX_METRICS_BIND`), `RTSP_USERS_FILE`, `MEDIAMTX_HOST` and
   `MEDIAMTX_BINARY`: `install` carries these nine settings and no others.
   If you would rather not depend on this, write the users into a file you own
   (Option 1 below): a file you own is never rewritten, whatever the environment says.

The mode applies at the next `start`, `restart` or `reload`. It has no effect on a
file you own (the manager warns), and the installer has no such option: a
`mediamtx.service` node needs Option 1.

### Who owns `/etc/mediamtx/mediamtx.yml`

The first line of a generated file is `# Managed by LyreBirdAudio`. It decides who
may change the file:

- **With that line the file is generated.** The stream manager renders it again at
  every start that launches MediaMTX and on `reload`. When the rendering differs
  from the file, the old file is saved next to it as
  `mediamtx.yml.<UTC time>.<nn>.bak` (same mode and owner; the newest five are
  kept, `MEDIAMTX_CONFIG_BACKUPS` changes that) and replaced atomically. **An edit
  to a generated file is lost at the next start**; it survives only in the backup.
- **Without that line the file is yours.** The manager uses it as it is, never
  writes it, and warns once per start. MediaMTX's own `--validate-conf` checks it
  first where the binary has the flag (1.21.1 and later); older binaries get a
  structural check only, so a wrong key is found when MediaMTX itself refuses to
  start.
- **To keep hand edits, delete the first line.** Observed: after deleting it and
  editing `logLevel`, a restart kept the edit and only warned.
- **To hand a file back**, run `sudo ./lyrebird-stream-manager.sh --regenerate-config
  restart`; the file you had is saved first.
- **The installer follows the same rule.** `install` replaces a file that has the
  line, leaves one that has not, and replaces it after a backup only with `--force`.

Every edit in the options below is therefore made in a file you own: delete the first
line first.

### Option 1: Your own `authInternalUsers`

Delete the first line of `/etc/mediamtx/mediamtx.yml`, then add this before the
`paths:` line. The first user is the machine itself; the two others are remote users.
Replace every `change_me` before you use it: it is a public example value.

```yaml
###############################################
# Authentication
###############################################

# Authentication method. Available values:
# - internal: use internal users
# - http: use an external HTTP server
# - jwt: use JWT tokens
authMethod: internal

# Internal users (used when authMethod is "internal")
authInternalUsers:
  # This machine: publishers, health checks, API. No password, loopback only.
  - user: any
    pass:
    ips: ['127.0.0.1', '::1']
    permissions:
      - action: publish
      - action: read
      - action: playback
      - action: api
      - action: metrics
      - action: pprof

  # Remote listener - can view every stream
  - user: listener
    pass: change_me
    permissions:
      - action: read
      - action: playback

  # Remote listener limited to two streams.
  # A path that starts with '~' is a regular expression; without it, the
  # value is a literal path name.
  - user: birdwatcher
    pass: change_me_too
    permissions:
      - action: read
        path: '~^(mic1|mic2)$'
```

Checked on all six MediaMTX versions with this block: a local publisher without
credentials works; an anonymous reader or publisher connecting from a non-loopback
address is refused with `401`; `listener` can read; a user that only has `read`
cannot publish; `birdwatcher` is refused on a path outside the regular expression.
Apply it with `sudo systemctl restart mediamtx-audio` (MediaMTX also re-reads a
changed file by itself).

### Option 2: Passwords from the Environment (Keeps Secrets Out of the File)

MediaMTX does **not** expand `${VAR}` inside its YAML file: a line such as
`pass: "${MEDIAMTX_ADMIN_PASSWORD}"` makes the literal text
`${MEDIAMTX_ADMIN_PASSWORD}` the password. (Verified: that literal string was
accepted and the value of the environment variable was refused.) Never use that form.

MediaMTX instead lets an environment variable named `MTX_` plus the upper-cased
parameter path override any setting. List entries are addressed by their
zero-based position, so the password of the second user in the Option 1 list
(`listener`, index 1) is `MTX_AUTHINTERNALUSERS_1_PASS`. Keep a placeholder in the
file and put the real value in the environment of the process that starts
MediaMTX:

```bash
# stand-alone MediaMTX installs
sudo systemctl edit mediamtx
# stream-manager installs (the manager starts MediaMTX as its child process)
sudo systemctl edit mediamtx-audio
```

Add:
```ini
[Service]
Environment="MTX_AUTHINTERNALUSERS_1_PASS=your_secure_password"
```

(Verified on MediaMTX 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3: with the variable set,
the file's placeholder was refused and the variable's value accepted. **MediaMTX 1.15.0
ignores the variable for list entries**: the placeholder stayed the valid password. 1.16 and
1.17 were not available to check. That a unit's `Environment=` reaches MediaMTX through the
manager follows from the manager starting MediaMTX as a plain child process; it was not
exercised through systemd.)

**Two traps.**

- **The placeholder must not be a usable password.** The cron monitor starts MediaMTX
  again when it has died, and cron does not see the unit's `Environment=`. Observed
  (1.21.3): with the placeholder `change_me` in the file, the password silently became
  `change_me` after such a restart; on 1.15.0 it was `change_me` from the start. Use a
  hash nobody can match instead, so a missing or ignored variable locks the account
  instead of opening it:

  ```yaml
    pass: sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  ```

  Observed with that placeholder: before the restart the variable's value worked
  and the placeholder did not; after it, neither worked.
- After such a restart the account is locked until the variable is also in the cron
  file (`NAME=value` lines before the job line of `/etc/cron.d/mediamtx-monitor`,
  which every `install` rewrites without carrying `MTX_` variables). Option 3 has no
  such dependency.

### Option 3: Store a Hash Instead of the Password

```bash
printf '%s' 'the_password' | openssl dgst -sha256 -binary | base64
```

Use the output as `pass: sha256:<output>` (verified on all six versions: the right
password is accepted, a wrong one is refused with `401`). The file then holds only
hashes, which have no salt: keep it readable by root only
(`sudo chmod 640 /etc/mediamtx/mediamtx.yml`; a generated or owned file keeps its
mode when the manager starts).

### Passwords cross the network readable on plain RTSP

MediaMTX's default `rtspAuthMethods` is `[basic]`. Measured with a capture on the
loopback interface: a plain RTSP read with credentials sent
`Authorization: Basic bGlzdGVuZXI6bGlzdGVuZXJwdw==` (base64 of `listener:listenerpw`);
the same read over RTSPS showed neither the header nor the password. Anyone who can
capture the traffic between a client and the node can read the password. Use
[RTSPS](#tlshttps-encryption) or a [VPN](#vpn-for-remote-access-recommended).

### Connecting with Authentication

```bash
# VLC
vlc rtsp://listener:your_password@hostname:8554/stream_name

# FFplay
ffplay rtsp://listener:your_password@hostname:8554/stream_name

# In streaming software, use URL format:
# rtsp://username:password@host:port/path
```

A password in a URL is visible in the process list of the machine that runs the
player.

### Testing Authentication

Run these from **another machine**: with the loopback-only `any` user, connections
from the recorder itself never need a password.

```bash
# Should fail with 401 Unauthorized (no credentials)
ffprobe rtsp://hostname:8554/mic1

# Should succeed (with credentials)
ffprobe rtsp://listener:your_password@hostname:8554/mic1
```

---

## TLS/HTTPS Encryption

### When to Use TLS

- Passwords cross a network you do not control (plain RTSP sends them readable)
- Sensitive audio content crosses such a network
- Compliance requirements

A [VPN](#vpn-for-remote-access-recommended) covers the same need without certificates.

### What it does and does not protect

RTSPS hides the password and the audio from someone who can capture the traffic.
It does **not**, with FFmpeg as the client, prove which server you reached. Measured
with FFmpeg 6.1.1 (GnuTLS): an `rtsps://` read succeeded against a self-signed
certificate, and also against an address the certificate does not name, even with
`-tls_verify 1`, `-ca_file` or `-verifyhost` on the command line; the same options do
work for `https://` in that FFmpeg. So RTSPS from FFmpeg protects against
eavesdropping, not against someone who impersonates the node. A VPN does both.

### Generating Self-Signed Certificates

For testing or internal use (OpenSSL 1.1.1 or newer for `-addext`; current clients
want the name in `subjectAltName`):

```bash
# Create directory for certificates
sudo mkdir -p /etc/mediamtx/certs
cd /etc/mediamtx/certs

# Generate private key
sudo openssl genrsa -out server.key 2048

# Generate self-signed certificate (valid for 365 days)
sudo openssl req -new -x509 -sha256 \
    -key server.key \
    -out server.crt \
    -days 365 \
    -subj "/CN=lyrebird.local" \
    -addext "subjectAltName=DNS:lyrebird.local,IP:192.168.1.100"

# Set permissions: see the next paragraph for who must be able to read the key
sudo chmod 640 server.key
sudo chmod 644 server.crt
sudo chown root:root server.crt
```

Who must read the key depends on who runs MediaMTX. The stream manager runs it as
root: `sudo chown root:root server.key`. The standalone `mediamtx.service` runs it as
the `mediamtx` account: `sudo chown root:mediamtx server.key`. Observed: with the key
at mode 600 owned by root, MediaMTX started as another account stopped with
`permission denied`; with mode 640 and the account's group it started.

### Using Let's Encrypt (Production)

For publicly accessible deployments with a domain name (these commands were not run
for this guide):

```bash
# Install certbot
sudo apt install certbot

# Generate certificate (requires port 80 access)
sudo certbot certonly --standalone -d your-domain.com

# Certificates will be at:
# /etc/letsencrypt/live/your-domain.com/fullchain.pem
# /etc/letsencrypt/live/your-domain.com/privkey.pem
```

Point `rtspServerCert` and `rtspServerKey` at those files.

### Configuring MediaMTX for TLS

The generator has no TLS option: delete the first line of
`/etc/mediamtx/mediamtx.yml` (see
[Who owns the file](#who-owns-etcmediamtxmediamtxyml)) and add:

```yaml
###############################################
# RTSP server (with TLS)
###############################################

# Encryption mode: "no", "optional" or "strict"
#   no: TLS disabled
#   optional: clients can connect with or without TLS
#   strict: only TLS connections allowed
rtspEncryption: optional

# Path to server certificate (PEM format)
rtspServerCert: /etc/mediamtx/certs/server.crt

# Path to server private key (PEM format)
rtspServerKey: /etc/mediamtx/certs/server.key
```

**Use `optional`, not `strict`.** The stream manager's publishers and health probes
connect to plain RTSP on `localhost:8554`. Observed (1.21.3) with `strict`:
MediaMTX closed TCP 8554 and UDP 8000 and 8001, and nothing could publish. With
`optional` it kept plain RTSP and added RTSPS on TCP 8322 (plus UDP 8004 and 8005 for
encrypted RTP).
To accept only encrypted connections from the network, keep `optional` and
[block TCP 8554 for everything but this machine](#firewall-configuration-iptables).

The older key names `encryption`, `serverCert` and `serverKey` were still accepted, with a
deprecation warning in the log, by MediaMTX 1.15.0, 1.21.1 and 1.21.3 (the versions
checked for this); use the names above.
WebRTC is switched off in the generated file and nothing in LyreBirdAudio uses it,
so there is no WebRTC TLS setup here.

### Connecting via RTSPS (Encrypted RTSP)

```bash
# Use rtsps:// instead of rtsp:// (ffprobe was run for this guide; ffplay and VLC were not)
ffplay rtsps://hostname:8322/stream_name

vlc rtsps://hostname:8322/stream_name
```

---

## API Security

### What protects the API

By default the API listens on `127.0.0.1` only (`MEDIAMTX_API_BIND`), so other
machines get a refused connection. **Every program on the node itself can use it
without a password.** The stream manager's readiness check, stream probes and the
metrics exporter rely on that. With MediaMTX's default policy, an empty
`MEDIAMTX_API_BIND` (every interface) still gives other machines `401`; it is
unnecessary, because nothing in LyreBirdAudio needs the API from another machine.

### Protecting the API from other local accounts

Any local account can use the API and, through it, make MediaMTX run commands as its
own user (see [the table](#what-each-kind-of-attacker-can-do-on-a-default-node)). If
other people have accounts on the node, give the API a password. In a file you own,
give the password-less `any` user only what the manager needs to publish and read,
and put the API and metrics under a second user:

```yaml
authMethod: internal
authInternalUsers:
  # The stream manager's own publishers and readers: this machine, no password.
  - user: any
    pass:
    ips: ['127.0.0.1', '::1']
    permissions:
      - action: publish
      - action: read
      - action: playback
  # The control API and the metrics endpoint: this machine, with a password.
  # The hash below is a placeholder nobody can match: replace it with the output
  # of the command in Option 3 (as it stands, nobody can use this account).
  - user: operator
    pass: sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    ips: ['127.0.0.1', '::1']
    permissions:
      - action: api
      - action: metrics
```

Add your remote users from Option 1 to the same list. Observed with the real manager
on 1.21.3: another local account got `401` from the API, with and without trying to
add a path that runs a command, and `200` with the operator's credentials; local
publishing without credentials still worked.

**What it costs.** The manager's own API calls carry no credentials:

- `start` continues with one warning (`MediaMTX is up (HTTP 401 ...) but its API
  requires credentials: stream health cannot be checked through it`);
- the monitor's deep health check cannot ask the API whether a stream is ready: it
  reports *unknown*, and unknown never restarts a stream (the stream manager's tests
  check that; it was not run for this guide);
- `lyrebird-metrics.sh` has no credential setting: `lyrebird_api_up` reads `0` and the
  API metrics are missing.

What this does **not** stop: any local account can still read and publish streams
through `127.0.0.1`, because the manager's own FFmpeg processes do the same without
credentials.

### API from another machine

Nothing in LyreBirdAudio needs it. If you want it anyway, run `install` with
`MEDIAMTX_API_BIND=` (empty) or an address, and in a file you own give a user with the `api` permission a
password and the networks it may come from:

```yaml
  - user: admin
    pass: sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=    # replace, see Option 3
    ips: ['127.0.0.1', '::1', '192.168.1.0/24']
    permissions:
      - action: api
```

```bash
# From another machine, without credentials (fails with 401)
curl http://hostname:9997/v3/paths/list

# With credentials
curl -u admin:the_password http://hostname:9997/v3/paths/list
```

Checked: from a second address, the password gave `200`, no password and a wrong
password gave `401`. The API is plain HTTP: the password and everything the API
returns cross the network readable.

---

## Network Security

### Do not bind RTSP to one interface

The generator listens on every interface and cannot change that. Setting
`rtspAddress: 192.168.1.100:8554` by hand also makes MediaMTX refuse connections to
`127.0.0.1`, which is where the stream manager's publishers and probes connect (observed:
publishing through `127.0.0.1` was refused, through the LAN address it worked). Use a
firewall to limit who can connect.

### Firewall Configuration (UFW)

UFW's shipped rules accept loopback traffic and its default policy drops other incoming
connections (read from UFW 0.36.2's `before.rules` and `/etc/default/ufw`; UFW was not
run for this guide):

```bash
# Allow SSH (always do this first!)
sudo ufw allow ssh

# Allow RTSP only from the local network
sudo ufw allow from 192.168.1.0/24 to any port 8554 proto tcp

# The API and metrics listen on 127.0.0.1 only: no rule needed

# Enable firewall
sudo ufw enable

# Check status
sudo ufw status verbose
```

RTSP over UDP also uses 8000 and 8001. Clients that read with TCP
(`-rtsp_transport tcp`) need only 8554.

### Firewall Configuration (iptables)

Accept loopback **first**. Without it the drop rule also blocks the stream manager's
own connections to `127.0.0.1:8554`: measured with a second host, the allow/drop pair
alone refused both the other host and the machine itself; with the loopback rule
first, the machine itself worked and a host outside the allowed network was dropped.

```bash
# The stream manager's publishers and probes connect to 127.0.0.1
sudo iptables -A INPUT -i lo -j ACCEPT

# Allow RTSP from the local network only
sudo iptables -A INPUT -p tcp --dport 8554 -s 192.168.1.0/24 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 8554 -j DROP

# Save rules
sudo iptables-save | sudo tee /etc/iptables.rules

# Restore on boot (add to /etc/rc.local or systemd)
sudo iptables-restore < /etc/iptables.rules
```

These are appended to the end of the `INPUT` chain: if the chain already has rules that
accept the traffic earlier, insert these before them (`iptables -I INPUT <position> ...`).
Saving and restoring at boot was not run for this guide and differs between
distributions.

### VPN for Remote Access (Recommended)

Instead of exposing RTSP directly, use a VPN (these commands were not run for this
guide):

```bash
# WireGuard (modern, fast)
sudo apt install wireguard

# Or OpenVPN
sudo apt install openvpn

# Then access streams through VPN tunnel
# rtsp://10.0.0.1:8554/stream_name (VPN IP)
```

### Fail2Ban for Brute Force Protection

MediaMTX writes a line for every failed login. The text depends on the version, so the
filter has two patterns (checked with `fail2ban-regex` 1.0.2 against the real logs of all
six versions: three wrong passwords gave three matches on each; the earlier filter
(`client=<HOST>`) matched nothing):

| Version | Line |
|---------|------|
| 1.15.0 | `INF [RTSP] [conn 10.0.0.5:57952] closed: authentication error` |
| 1.18.0, 1.19.0 | `INF [RTSP] [conn 10.0.0.5:49050] closed: authentication failed: authentication failed` |
| 1.21.1 and later | `WAR [RTSP] [conn 10.0.0.5:36752] failed to authenticate: authentication failed` |

```bash
# Install fail2ban
sudo apt install fail2ban

# Create MediaMTX jail
sudo tee /etc/fail2ban/jail.d/mediamtx.local << 'EOF'
[mediamtx]
enabled = true
port = 8554
filter = mediamtx
logpath = /var/log/mediamtx.out
maxretry = 5
bantime = 3600
findtime = 600
EOF

# Create filter
sudo tee /etc/fail2ban/filter.d/mediamtx.conf << 'EOF'
[Definition]
failregex = ^\s*WAR \[RTSP\] \[conn <HOST>:\d+\] failed to authenticate: authentication failed$
            ^\s*INF \[RTSP\] \[conn <HOST>:\d+\] closed: authentication (?:error|failed: authentication failed)$
ignoreregex =
EOF

# Restart fail2ban
sudo systemctl restart fail2ban
```

`/var/log/mediamtx.out` is where both the stream manager and `mediamtx.service` write
MediaMTX's output. An anonymous request is only challenged and not logged as a failed login:
the filter sees wrong passwords. MediaMTX 1.15.0 to 1.19.0 write the failed login at the
`info` level, so keep `logLevel: info` there (see [Log Security](#log-security)).
Fail2ban was not run as a service for this guide.

---

## Metrics and Alerts

### The metrics exporter

`lyrebird-metrics.sh serve` is a small HTTP server for a poller such as Prometheus. It
listens on `127.0.0.1:9100` by default (`--port`, `--bind`), has
**no authentication and no TLS**, and serves one connection at a time. Checked: from a
second address the default bind refused connections; with `--bind 0.0.0.0` the metrics
came back without credentials, and the script logged a warning that they are served
without authentication or TLS.

The document lists stream names, MediaMTX and script versions, process memory and CPU,
device counts and disk usage per mount. Treat it as information about your deployment.
Bind it to a non-loopback address only on a network you trust and behind a firewall rule.
For several scrapers or any exposure beyond the machine, write a file with
`lyrebird-metrics.sh --file PATH` for node_exporter's textfile collector instead. Run the
exporter as root: another account cannot inspect root's processes, so it reports a
degraded scrape.

MediaMTX's own metrics endpoint (`127.0.0.1:9998`) is separate and is covered by
[API Security](#api-security).

### Alerts

`lyrebird-alerts.sh` is off until you enable it (`LYREBIRD_ALERT_ENABLED`, default
`false`). Its settings live in `/etc/lyrebird/alerts.conf`, which `lyrebird-alerts.sh
config` writes with mode 0600. The file is read as data (only `LYREBIRD_*` names; it is
never run as shell).

- **The webhook URL is a secret.** For Discord, Slack and similar services, anyone who
  has the URL can post to your channel. The same goes for the Pushover token and user key
  and for an ntfy topic.
- **Local accounts can see it while an alert is sent.** The URL (and the Pushover token and
  user key) are passed to `curl` as command-line arguments. Measured: while a delivery
  was running, an unprivileged account read the full URL, and the token and user key, from
  `/proc/<pid>/cmdline`. The window is the length of a delivery: up to twice
  `LYREBIRD_ALERT_TIMEOUT` seconds per attempt, three attempts by default
  (`LYREBIRD_ALERT_RETRIES`). If you do not trust the accounts on the node, treat the URL
  as known to them and replace it if you suspect misuse. A `/proc` mounted with `hidepid=2`
  hides other accounts' command lines (not tested here).
- **`http://` URLs are accepted.** There is no scheme check: a plain `http://` webhook
  received the alert. Use `https://`.
- **What leaves the node.** The message text, the alert type, the host name
  (`LYREBIRD_HOSTNAME`), the location (`LYREBIRD_LOCATION`) and the time go to the
  destination. The default ntfy server is `https://ntfy.sh`, a third party.
- **What stays on the node.** `/var/log/lyrebird/alerts.log` records the message text, not
  the URL. A failed delivery is logged with the URL cut after 30 characters.
- **Rate limit.** An identical alert is not sent again to a destination that confirmed it
  within `LYREBIRD_ALERT_RATE_LIMIT` seconds (default 300). The sender signs nothing: there
  is no webhook signature to verify.

---

## File System Security

### What the suite creates, and with which mode

Observed after a first `start` of the stream manager as root (`alerts.conf` is written by
`lyrebird-alerts.sh config`, see its code):

| File | Mode | Holds |
|------|------|-------|
| `/etc/mediamtx/mediamtx.yml` | 0644 (0640 when it contains password hashes) | MediaMTX configuration |
| `/etc/mediamtx/mediamtx.yml.<time>.<nn>.bak` | same as the file it replaced | previous configurations |
| `/etc/mediamtx/audio-devices.conf` | 0644 | device names and per-device settings |
| `/etc/mediamtx/rtsp-users.conf` | yours | password hashes |
| `/var/log/lyrebird-stream-manager.log`, `/var/log/mediamtx.out` | 0644 | stream names, device names, client IP addresses |
| `/run/mediamtx-audio.pid`, `/run/lyrebird/status.json` | 0644 | process IDs, per-stream state |
| `/var/lib/mediamtx-ffmpeg/` | 0755 | wrapper scripts, FFmpeg logs |
| `/etc/lyrebird/alerts.conf` | 0600 | webhook URLs and tokens |

Everything except the alert settings is readable by every local account. None of it is a
secret except the hashes and the alert settings.

### Configuration File Permissions

```bash
# MediaMTX configuration. The manager runs MediaMTX as root, so root-only is enough:
sudo chmod 640 /etc/mediamtx/mediamtx.yml
sudo chown root:root /etc/mediamtx/mediamtx.yml
# A standalone mediamtx.service runs MediaMTX as the 'mediamtx' account instead:
#   sudo chown root:mediamtx /etc/mediamtx/mediamtx.yml

# Users file and certificate key
sudo chmod 600 /etc/mediamtx/rtsp-users.conf
sudo chmod 640 /etc/mediamtx/certs/server.key      # group: see the TLS section

# Logs of the stream manager: the manager keeps the mode of an existing file
sudo chmod 640 /var/log/lyrebird-stream-manager.log /var/log/mediamtx.out
sudo chmod 750 /var/log/lyrebird        # created by the alert and diagnostics scripts
```

The manager keeps the mode you give `mediamtx.yml` when it replaces it, and logrotate
(`copytruncate`) keeps the mode of the logs.

### Read-Only Root Filesystem

For field deployments, consider a read-only root. The stream manager and the service unit
need `/etc/mediamtx`, `/var/log`, `/run`, `/var/lib/mediamtx-ffmpeg` and `/var/lib/lyrebird`
writable; this was not tested on a read-only root:

```bash
# Add to /etc/fstab:
# / ext4 defaults,ro 0 1

# Writable directories via tmpfs:
tmpfs /var/log tmpfs defaults,noatime,size=50M 0 0
tmpfs /tmp tmpfs defaults,noatime,size=100M 0 0
```

### Library Integrity Check

`lyrebird-stream-manager.sh` can check `lyrebird-common.sh` before it uses it. Set the
hash in the environment of the service (`systemctl edit mediamtx-audio`):

```bash
sha256sum lyrebird-common.sh | cut -d' ' -f1
# Environment="LYREBIRD_COMMON_EXPECTED_HASH=<that value>"
```

Checked: a wrong value stopped the manager with `lyrebird-common.sh integrity check
failed!` and exit 1, the right value ran it. Only the stream manager has this check; the
other scripts source the library without one. Update the value after every update of the
library. The check also runs when the script is started by its bare name from its own
directory (`bash lyrebird-stream-manager.sh status`).

---

## Log Security

### What Gets Logged

By default, logs contain:
- Stream names and paths
- Client IP addresses and the times of their connections
- Device identifiers
- The text of alerts (`/var/log/lyrebird/alerts.log`)

### Reducing the log

The stream manager renders `logLevel: info`. In a file you own you can set `logLevel`:

```yaml
logLevel: warn  # Options: debug, info, warn, error
```

Measured at `warn`: MediaMTX 1.15.0 and 1.18.0 wrote nothing at all for connections or
failed logins, so fail2ban sees nothing; 1.21.3 still wrote one line per failed login
with the client address. The level alone does not keep addresses out of the log on
current versions. `logDestinations: []` switches MediaMTX's logging off entirely.

### Secure Log Storage

```bash
# Encrypt log partition (destroys the data on /dev/sdX1; not run for this guide)
sudo cryptsetup luksFormat /dev/sdX1
sudo cryptsetup luksOpen /dev/sdX1 logs
sudo mkfs.ext4 /dev/mapper/logs
sudo mount /dev/mapper/logs /var/log

# Or use log shipping to secure remote location
# (See monitoring documentation)
```

### Log rotation

`lyrebird-stream-manager.sh install` writes `/etc/logrotate.d/mediamtx` for the manager's
log, MediaMTX's output and the FFmpeg logs in `/var/lib/mediamtx-ffmpeg` (when `logrotate`
is installed). The file `config/lyrebird-logrotate.conf` covers the other logs:
`/var/log/lyrebird/*.log` (the alert log) and the orchestrator, updater, diagnostics and USB
mapper logs. It lists none of the logs of the first file, so you can copy it to
`/etc/logrotate.d/lyrebird` and each log still has one owner (the tests check that the two
files name no log in common; `logrotate` itself was not run). logrotate refuses a log that two
files list: checked with logrotate 3.21.0 on the earlier shipped file, both files together gave
`duplicate log entry for /var/log/mediamtx.out` and logrotate skipped the file `install` wrote,
so those logs were no longer rotated. Keep that in mind if you add stanzas of your own.

---

## Physical Security

For remote field deployments:

### Hardware Recommendations

- Use tamper-evident enclosures
- Secure with locks or security screws
- Consider GPS tracking for equipment
- Use weatherproof/rugged enclosures
- Implement power loss detection

USB port tamper detection is not built in.

### Remote Wipe Capability

For sensitive deployments, implement remote wipe. This removes the configuration, the
password hashes, the certificates, the alert settings, the logs and the default recording
buffer. `shred` is not reliable on SD cards and other flash storage with wear leveling:
full-disk encryption protects better than deleting afterwards. Checked in a private
filesystem overlay with `systemctl` and `shutdown` replaced by stand-ins:

```bash
#!/bin/bash
# /usr/local/bin/emergency-wipe.sh
# Triggered by dead man's switch or remote command

# Where recordings go (AUDIO_RECORDING_PATH; the default is RAM)
RECORDING_DIR="${AUDIO_RECORDING_PATH:-/dev/shm/lyrebird-buffer}"

# Stop all services
systemctl stop mediamtx-audio mediamtx

# Wipe sensitive data
shred -u /etc/mediamtx/mediamtx.yml /etc/mediamtx/mediamtx.yml.*.bak /etc/mediamtx/rtsp-users.conf
shred -u /etc/mediamtx/certs/* /etc/lyrebird/alerts.conf
rm -rf /var/log/lyrebird/* /var/log/mediamtx.out /var/log/lyrebird-stream-manager.log
rm -rf "${RECORDING_DIR:?}"/*

# Log final message
logger "Emergency wipe completed"

# Shutdown
shutdown -h now
```

---

## Reporting Vulnerabilities

Do **not** open a public GitHub issue for a security problem. See
[SECURITY.md](../SECURITY.md) for how to report one, which versions receive fixes, and
what is not covered.

---

## Security Maintenance

### Regular Updates

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Update LyreBirdAudio: opens a menu; --help describes it
./lyrebird-updater.sh

# Update MediaMTX (checksum-verified download; -n shows what it would do first)
sudo ./install_mediamtx.sh -n update
sudo ./install_mediamtx.sh update
```

Which release the updater offers matters: see [SECURITY.md](../SECURITY.md#supported-versions).
Run the [exposure check](#check-what-your-node-exposes) after every update.

### Security Audit

Run periodic security checks:

```bash
# What listens, and on which address
sudo ss -tulpn | grep -E '"(mediamtx|nc)"'

# Are the users still in the file? (1 = yes; if you use RTSP_AUTH_MODE or Option 1)
grep -c authInternalUsers /etc/mediamtx/mediamtx.yml

# File permissions
ls -la /etc/mediamtx/ /etc/lyrebird/ /var/log/lyrebird/
```

`sudo ./lyrebird-diagnostics.sh full` reports the health of the stack; it checks that RTSP is
listening, not who can reach it.

---

## Additional Resources

- [MediaMTX: authentication](https://mediamtx.org/docs/features/authentication)
- [MediaMTX: control API](https://mediamtx.org/docs/features/control-api)
- [RTSP 1.0 specification (RFC 2326)](https://www.rfc-editor.org/rfc/rfc2326.txt), the protocol MediaMTX speaks
- [Debian hardening guide](https://wiki.debian.org/Hardening)
