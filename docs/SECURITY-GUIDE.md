# LyreBirdAudio Security Guide

This guide covers **optional** security features for LyreBirdAudio deployments. These are recommendations for users who need enhanced security, particularly for:

- Remote/field deployments accessible over networks
- Multi-user environments
- Sensitive wildlife monitoring locations
- Professional or commercial installations

> **Note:** For home users on trusted local networks, the default configuration works well without any security setup. These features are entirely optional.

---

## Table of Contents

1. [Security Model Overview](#security-model-overview)
2. [Quick Security Checklist](#quick-security-checklist)
3. [RTSP Authentication](#rtsp-authentication)
4. [TLS/HTTPS Encryption](#tlshttps-encryption)
5. [API Security](#api-security)
6. [Network Security](#network-security)
7. [File System Security](#file-system-security)
8. [Log Security](#log-security)
9. [Physical Security](#physical-security)
10. [Reporting Vulnerabilities](#reporting-vulnerabilities)

---

## Security Model Overview

LyreBirdAudio's generated MediaMTX configuration has three network listeners:

| Interface | Default Port | Purpose | Default Security |
|-----------|--------------|---------|------------------|
| RTSP | 8554 | Audio streaming | Open: anyone who can reach the port can read **and publish** |
| Control API | 9997 | Stream management; used by the manager's own health checks | The listener accepts connections on all interfaces, but MediaMTX's default policy authorizes API calls from the local machine only (other callers get `401`) |
| Metrics | 9998 | MediaMTX's own Prometheus metrics | Same as the control API |

The stream manager's generated configuration disables WebRTC, HLS, RTMP and SRT
(MediaMTX itself enables WebRTC on 8889 by default). The configuration written by
`install_mediamtx.sh` disables WebRTC, HLS and RTMP but leaves MediaMTX's SRT (and,
on 1.19+, MoQ) listeners at their defaults until the stream manager next
regenerates the file.

**Default behavior:** Suitable for home networks where all devices are trusted.

**Enhanced security:** Recommended when streams may be accessed from untrusted networks.

---

## Quick Security Checklist

### Minimal Security (Home Use)
- [ ] Keep system updated (`sudo apt update && sudo apt upgrade`)
- [ ] Use firewall to block external access if not needed
- [ ] Don't expose ports to the internet unnecessarily

### Standard Security (Remote Access)
- [ ] Enable RTSP authentication
- [ ] Restrict API to localhost or specific IPs
- [ ] Use firewall rules to limit access
- [ ] Enable log rotation

### Enhanced Security (Field Deployment)
- [ ] All of the above, plus:
- [ ] Enable TLS encryption for RTSP (RTSPS)
- [ ] Use VPN for remote access instead of direct exposure
- [ ] Enable audit logging
- [ ] Implement physical security measures
- [ ] Regular security updates schedule

---

## RTSP Authentication

### Option 1: Internal Authentication (Recommended)

This suite's publishers (the FFmpeg processes) and health checks run on the same
machine and connect to MediaMTX at `localhost` **without credentials**. Defining
`authInternalUsers` *replaces* MediaMTX's built-in default users, so the file must
keep a password-less user for the local machine that may publish, read and call
the API. Without it the stream manager's publishers are refused (`401`) and its
readiness and health probes fail. Remote listeners then need passwords.

Edit `/etc/mediamtx/mediamtx.yml`:

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

Checked against MediaMTX 1.21.1 with this file: a local publisher without
credentials works; an anonymous reader or publisher connecting from a
non-loopback address is refused with `401`; `listener` can read; a user that only
has `read` cannot publish; `birdwatcher` is refused on a path outside the regular
expression.

> **Note:** `lyrebird-stream-manager.sh` currently regenerates
> `/etc/mediamtx/mediamtx.yml` on every `start`, which discards these edits
> (finding LB-22 in [`REMEDIATION-2026-11.md`](REMEDIATION-2026-11.md)). Check the
> file after a restart until that is fixed.

### Option 2: Passwords from the Environment (Keeps Secrets Out of the File)

MediaMTX does **not** expand `${VAR}` inside its YAML file: a line such as
`pass: "${MEDIAMTX_ADMIN_PASSWORD}"` makes the literal text
`${MEDIAMTX_ADMIN_PASSWORD}` the password. (Verified on MediaMTX 1.21.1: that
literal string was accepted and the value of the environment variable was
refused.) Never use that form.

MediaMTX instead lets an environment variable named `MTX_` plus the upper-cased
parameter path override any setting. List entries are addressed by their
zero-based position, so the password of the second user in the list above
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

(Verified: with the variable set, the file's placeholder was refused and the
variable's value accepted. That a unit's `Environment=` reaches MediaMTX through
the manager follows from the manager starting MediaMTX as a plain child process;
it was not exercised through systemd.)

### Option 3: Store a Hash Instead of the Password

```bash
printf '%s' 'the_password' | openssl dgst -sha256 -binary | base64
```

Use the output as `pass: sha256:<output>` (verified on MediaMTX 1.21.1: the right
password is accepted, a wrong one is refused with `401`).

### Connecting with Authentication

```bash
# VLC
vlc rtsp://listener:your_password@hostname:8554/stream_name

# FFplay
ffplay rtsp://listener:your_password@hostname:8554/stream_name

# In streaming software, use URL format:
# rtsp://username:password@host:port/path
```

### Testing Authentication

Run these from **another machine**: with the loopback-only `any` user from Option 1,
connections from the recorder itself never need a password.

```bash
# Should fail with 401 Unauthorized (no credentials)
ffprobe rtsp://hostname:8554/mic1

# Should succeed (with credentials)
ffprobe rtsp://listener:your_password@hostname:8554/mic1
```

---

## TLS/HTTPS Encryption

### When to Use TLS

- Streams accessible over the internet
- Sensitive audio content
- Compliance requirements
- When using authentication (protects credentials)

### Generating Self-Signed Certificates

For testing or internal use:

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
    -subj "/C=US/ST=State/L=City/O=Organization/CN=lyrebird.local"

# Set proper permissions
sudo chmod 600 server.key
sudo chmod 644 server.crt
sudo chown root:root server.key server.crt
```

### Using Let's Encrypt (Production)

For publicly accessible deployments with a domain name:

```bash
# Install certbot
sudo apt install certbot

# Generate certificate (requires port 80 access)
sudo certbot certonly --standalone -d your-domain.com

# Certificates will be at:
# /etc/letsencrypt/live/your-domain.com/fullchain.pem
# /etc/letsencrypt/live/your-domain.com/privkey.pem
```

### Configuring MediaMTX for TLS

Edit `/etc/mediamtx/mediamtx.yml`:

```yaml
###############################################
# RTSP server (with TLS)
###############################################

# Encryption mode: no, optional, strict
#   no: TLS disabled
#   optional: clients can connect with or without TLS
#   strict: only TLS connections allowed
encryption: optional

# Path to server certificate (PEM format)
serverCert: /etc/mediamtx/certs/server.crt

# Path to server private key (PEM format)
serverKey: /etc/mediamtx/certs/server.key

###############################################
# WebRTC server (with TLS)
###############################################

# Enable HTTPS for WebRTC
webrtcEncryption: yes
webrtcServerCert: /etc/mediamtx/certs/server.crt
webrtcServerKey: /etc/mediamtx/certs/server.key
```

### Connecting via RTSPS (Encrypted RTSP)

```bash
# Use rtsps:// instead of rtsp://
ffplay rtsps://hostname:8322/stream_name

# VLC
vlc rtsps://hostname:8322/stream_name

# If using self-signed certificates, you may need to disable verification
# (NOT recommended for production)
ffplay -rtsp_transport tcp rtsps://hostname:8322/stream_name
```

---

## API Security

### Restricting API Access

By default, the API listens on all interfaces. Restrict to localhost:

```yaml
###############################################
# API (optional, disabled by default)
###############################################

api: yes
apiAddress: 127.0.0.1:9997  # Localhost only

# Or restrict to specific network
# apiAddress: 192.168.1.100:9997
```

### API Authentication

When API is exposed, add authentication:

```yaml
# In authInternalUsers, add api permission:
authInternalUsers:
  - user: api_admin
    pass: api_password
    permissions:
      - action: api
```

Callers on other machines then require authentication (calls from the recorder
itself keep working without a password through the loopback-only `any` user from
[RTSP Authentication](#rtsp-authentication), which the manager's health checks
rely on):

```bash
# From another machine, without auth (fails with 401)
curl http://hostname:9997/v3/paths/list

# With auth
curl -u api_admin:api_password http://hostname:9997/v3/paths/list
```

---

## Network Security

### Firewall Configuration (UFW)

```bash
# Allow SSH (always do this first!)
sudo ufw allow ssh

# Allow RTSP only from local network
sudo ufw allow from 192.168.1.0/24 to any port 8554 proto tcp

# Allow API only from localhost
# (no rule needed - not allowing external access)

# Enable firewall
sudo ufw enable

# Check status
sudo ufw status verbose
```

### Firewall Configuration (iptables)

```bash
# Allow RTSP from local network only
sudo iptables -A INPUT -p tcp --dport 8554 -s 192.168.1.0/24 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 8554 -j DROP

# Save rules
sudo iptables-save | sudo tee /etc/iptables.rules

# Restore on boot (add to /etc/rc.local or systemd)
sudo iptables-restore < /etc/iptables.rules
```

### VPN for Remote Access (Recommended)

Instead of exposing RTSP directly, use a VPN:

```bash
# WireGuard (modern, fast)
sudo apt install wireguard

# Or OpenVPN
sudo apt install openvpn

# Then access streams through VPN tunnel
# rtsp://10.0.0.1:8554/stream_name (VPN IP)
```

### Fail2Ban for Brute Force Protection

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
failregex = ^.*authentication failed.*client=<HOST>.*$
ignoreregex =
EOF

# Restart fail2ban
sudo systemctl restart fail2ban
```

---

## File System Security

### Configuration File Permissions

```bash
# MediaMTX configuration (readable by service user)
sudo chmod 640 /etc/mediamtx/mediamtx.yml
sudo chown root:mediamtx /etc/mediamtx/mediamtx.yml

# Certificate private key (root only)
sudo chmod 600 /etc/mediamtx/certs/server.key
sudo chown root:root /etc/mediamtx/certs/server.key

# Log directory
sudo chmod 750 /var/log/lyrebird
sudo chown mediamtx:adm /var/log/lyrebird
```

### Read-Only Root Filesystem

For field deployments, consider a read-only root:

```bash
# Add to /etc/fstab:
# / ext4 defaults,ro 0 1

# Writable directories via tmpfs:
tmpfs /var/log tmpfs defaults,noatime,size=50M 0 0
tmpfs /tmp tmpfs defaults,noatime,size=100M 0 0
```

---

## Log Security

### What Gets Logged

By default, logs may contain:
- Stream names and paths
- Client IP addresses
- Device identifiers
- Timestamps of connections

### Log Sanitization

For sensitive deployments, reduce logging verbosity:

```yaml
# In mediamtx.yml
logLevel: warn  # Options: debug, info, warn, error

# Disable client logging
logDestinations: []  # Or just file, not stdout
```

### Secure Log Storage

```bash
# Encrypt log partition
sudo cryptsetup luksFormat /dev/sdX1
sudo cryptsetup luksOpen /dev/sdX1 logs
sudo mkfs.ext4 /dev/mapper/logs
sudo mount /dev/mapper/logs /var/log

# Or use log shipping to secure remote location
# (See monitoring documentation)
```

---

## Physical Security

For remote field deployments:

### Hardware Recommendations

- Use tamper-evident enclosures
- Secure with locks or security screws
- Consider GPS tracking for equipment
- Use weatherproof/rugged enclosures
- Implement power loss detection

### Remote Wipe Capability

For sensitive deployments, implement remote wipe:

```bash
#!/bin/bash
# /usr/local/bin/emergency-wipe.sh
# Triggered by dead man's switch or remote command

# Stop all services
systemctl stop mediamtx mediamtx-audio

# Wipe sensitive data
shred -u /etc/mediamtx/mediamtx.yml
shred -u /etc/mediamtx/certs/*
rm -rf /var/log/lyrebird/*
rm -rf /var/recordings/*

# Log final message
logger "Emergency wipe completed"

# Shutdown
shutdown -h now
```

---

## Reporting Vulnerabilities

If you discover a security vulnerability in LyreBirdAudio:

1. **Do NOT** open a public GitHub issue
2. Email the maintainer directly (see repository)
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We aim to respond within 48 hours and will:
- Acknowledge receipt of your report
- Provide an estimated timeline for a fix
- Credit you in the release notes (unless you prefer anonymity)

---

## Security Maintenance

### Regular Updates

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Update LyreBirdAudio
./lyrebird-updater.sh update

# Check for MediaMTX updates
./lyrebird-updater.sh check
```

### Security Audit

Run periodic security checks:

```bash
# Full diagnostics
sudo ./lyrebird-diagnostics.sh full

# Check for open ports
sudo ss -tlnp | grep -E '8554|9997|8889'

# Check file permissions
ls -la /etc/mediamtx/
ls -la /var/log/lyrebird/
```

---

## Additional Resources

- [MediaMTX Security Documentation](https://github.com/bluenviron/mediamtx#authentication)
- [RTSP Security Best Practices](https://www.ietf.org/rfc/rfc2326.txt)
- [Linux Server Security Guide](https://www.debian.org/doc/manuals/securing-debian-manual/)
