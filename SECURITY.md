# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 2.x.x   | Yes       |
| 1.x.x   | No        |

## Reporting a Vulnerability

We take security seriously. If you discover a security vulnerability in LyreBirdAudio, please report it responsibly.

### How to Report

1. **Do NOT** open a public GitHub issue for security vulnerabilities
2. Email security concerns to the maintainer (see GitHub profile)
3. Include as much detail as possible:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

### What to Expect

- **Acknowledgment**: Within 48 hours of your report
- **Initial Assessment**: Within 7 days
- **Resolution Timeline**: Depends on severity
  - Critical: 24-48 hours
  - High: 7 days
  - Medium: 30 days
  - Low: Next release

### Security Best Practices

When deploying LyreBirdAudio, follow these security recommendations:

#### Network Security

- Run MediaMTX behind a reverse proxy with TLS termination
- Restrict API access to localhost or trusted networks
- Use firewall rules to limit RTSP port exposure
- Consider VPN for remote stream access

#### File System Security

- Run scripts with minimal required privileges
- Avoid running as root when possible
- Use appropriate file permissions (640 for configs, 750 for scripts)
- Store recordings in a dedicated partition

#### Configuration Security

- Never commit webhook URLs or API keys to version control
- Use environment variables for sensitive configuration
- Rotate credentials regularly
- Monitor logs for unauthorized access attempts

#### Webhook Security

- Use HTTPS endpoints for webhook delivery
- Verify webhook signatures when possible
- Implement rate limiting
- Monitor for failed delivery attempts

## Security Features

LyreBirdAudio includes several security-conscious features:

1. **SHA256 Verification**: All MediaMTX downloads are verified against checksums
2. **Secure Temp Files**: Uses `mktemp` for temporary file creation
3. **Input Sanitization**: RTSP paths and user inputs are validated
4. **No Hardcoded Credentials**: Configuration is environment-driven
5. **Atomic Operations**: File operations use atomic patterns where possible
6. **Signal Handling**: Graceful shutdown and cleanup on termination
7. **Path Validation**: Dangerous operations validate path safety

## Disclosure Policy

We follow a coordinated disclosure process:

1. Reporter contacts maintainers privately
2. Issue is confirmed and assessed
3. Fix is developed and tested
4. Security advisory is prepared
5. Patch is released
6. Advisory is published after users have time to update

## Acknowledgments

We appreciate security researchers who help keep LyreBirdAudio secure. Responsible disclosures will be acknowledged in release notes (with permission).
