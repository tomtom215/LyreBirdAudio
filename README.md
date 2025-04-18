# MediaMTX Installer Script

This script automates the process of installing the latest MediaMTX release on Linux systems. It detects your system's CPU architecture and downloads the appropriate version for your machine.

## Features

- Automatically installs FFmpeg dependency
- Detects system architecture (x86_64, arm64, armv6)
- Downloads the latest MediaMTX release from GitHub
- Extracts MediaMTX to `/usr/local/mediamtx`
- Creates and configures a systemd service for automatic startup

## Supported Architectures

The script supports the following CPU architectures:
- x86_64 (64-bit Intel/AMD processors) → downloads the `amd64` version
- aarch64/arm64 (64-bit ARM processors) → downloads the `arm64v8` version
- armv6 (32-bit ARM processors) → downloads the `armv6` version

## Prerequisites

- A Linux system with systemd
- sudo access
- The following tools installed:
  - curl
  - wget
  - tar
  - grep
  - sed

## Installation

1. Download the script
```bash
wget https://example.com/path/to/install_mediamtx.sh
```

2. Make the script executable
```bash
chmod +x install_mediamtx.sh
```

3. Run the script with sudo
```bash
sudo ./install_mediamtx.sh
```

## What the Script Does

1. Updates package lists and installs FFmpeg
2. Determines your CPU architecture
3. Fetches the latest MediaMTX release version from GitHub
4. Downloads and extracts the appropriate MediaMTX package to `/usr/local/mediamtx`
5. Creates a systemd service for MediaMTX
6. Enables and starts the MediaMTX service

## After Installation

After installation, MediaMTX will be:
- Installed in `/usr/local/mediamtx/`
- Running as a systemd service named `mediamtx`
- Configured to start automatically on system boot

## Managing the MediaMTX Service

To check the status of the MediaMTX service:
```bash
sudo systemctl status mediamtx
```

To stop the service:
```bash
sudo systemctl stop mediamtx
```

To start the service:
```bash
sudo systemctl start mediamtx
```

To disable automatic startup:
```bash
sudo systemctl disable mediamtx
```

## Configuration

MediaMTX configuration is located at `/usr/local/mediamtx/mediamtx.yml`. Edit this file to modify MediaMTX settings.

After changing the configuration, restart the service:
```bash
sudo systemctl restart mediamtx
```

## Troubleshooting

If you encounter issues:

1. Check the service status:
```bash
sudo systemctl status mediamtx
```

2. Check the logs:
```bash
sudo journalctl -u mediamtx
```

3. Verify the architecture detection:
```bash
uname -m
```

4. Ensure the MediaMTX binary exists:
```bash
ls -l /usr/local/mediamtx/mediamtx
```

## License

This installer script is provided under the Apache 2.0 License.

## Disclaimer

This script is not officially affiliated with the MediaMTX project. Always review scripts before running them with sudo privileges.
