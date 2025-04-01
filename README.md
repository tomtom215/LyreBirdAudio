# MediaMTX RTSP Microphone Installer

A bash script that automates the installation and configuration of [MediaMTX](https://github.com/bluenviron/mediamtx) for streaming audio from USB microphones over RTSP.

## Overview

This project provides an installer script that simplifies the setup of MediaMTX for streaming audio from connected USB microphones or sound cards. It's particularly useful for:

- Home automation systems that need to integrate microphone audio
- DIY security or monitoring systems
- Networked audio distribution
- Remote audio monitoring solutions

The script handles:
- Installing MediaMTX with proper architecture detection
- Detecting connected USB sound cards with microphone inputs
- Creating RTSP streams for each detected microphone
- Setting up automatic startup on system boot
- Providing proper backup and version management for updates

## Requirements

- A Linux system (Debian/Ubuntu, RedHat/CentOS, Fedora, or Arch-based)
- Sudo privileges
- Internet connection for downloading MediaMTX
- One or more USB sound cards/microphones (optional at install time)

## Quick Start

1. Download the installer script:
   ```bash
   wget https://raw.githubusercontent.com/yourusername/mediamtx-mic-installer/main/install_mediamtx.sh
   ```

2. Make it executable:
   ```bash
   chmod +x install_mediamtx.sh
   ```

3. Run the installer:
   ```bash
   ./install_mediamtx.sh
   ```

4. After installation, your microphones will be available as RTSP streams:
   ```
   rtsp://your-ip-address:8554/mic1
   rtsp://your-ip-address:8554/mic2
   ...
   ```

## Usage Options

The installer has several command-line options for customization:

```
Usage: ./install_mediamtx.sh [options]

Options:
  --help, -h             Show this help message and exit
  --version VERSION      Specify MediaMTX version to install (default: v1.11.3)
  --no-upgrade           Skip system updates (useful for limited bandwidth)
  --install-dir DIR      Custom installation directory (default: $HOME/mediamtx)
  --skip-autostart       Don't set up crontab autostart entry
```

### Examples

Install a specific version:
```bash
./install_mediamtx.sh --version v1.12.0
```

Install to a custom location without system upgrades:
```bash
./install_mediamtx.sh --install-dir /opt/mediamtx --no-upgrade
```

## How It Works

1. **Detection Phase**: The script checks your system architecture and detects connected USB sound cards.

2. **Installation Phase**: 
   - Downloads the appropriate MediaMTX binary for your system
   - Installs required dependencies (ffmpeg and alsa-utils)
   - Creates a backup if updating an existing installation

3. **Configuration Phase**:
   - Creates a startup script that automatically configures streams for each detected microphone
   - Sets up systemd service or crontab entry for automatic startup
   - Creates an uninstall script for easy removal

4. **Service Phase**:
   - When the system boots, MediaMTX starts and creates RTSP streams
   - Each microphone is available on a separate RTSP URL

## Accessing Streams

After installation, your microphone streams are available at:
```
rtsp://YOUR_IP_ADDRESS:8554/mic1  (first microphone)
rtsp://YOUR_IP_ADDRESS:8554/mic2  (second microphone)
...
```

These streams can be accessed by any RTSP-compatible player or software:
- VLC media player
- FFmpeg
- GStreamer
- Home Assistant
- Most IP camera viewing software

## Troubleshooting

### No Sound Cards Detected

If the script doesn't detect your USB microphone:

1. Connect your microphone and verify it appears in the system:
   ```bash
   arecord -l
   ```

2. If it shows up, edit the `startmic.sh` script in your MediaMTX installation directory to add the device manually:
   ```bash
   nano ~/mediamtx/startmic.sh
   ```

3. Add a line like the following (adjust the card number based on `arecord -l` output):
   ```bash
   ffmpeg -nostdin -f alsa -ac 1 -i plughw:1,0 -acodec libmp3lame -b:a 160k -ac 2 -content_type 'audio/mpeg' -f rtsp rtsp://localhost:8554/mic1 -rtsp_transport tcp &
   ```

### Service Doesn't Start

If MediaMTX doesn't start automatically on boot:

1. Check the status of the systemd service:
   ```bash
   sudo systemctl status mediamtx
   ```

2. Check the service logs:
   ```bash
   journalctl -u mediamtx
   ```

3. Try starting it manually:
   ```bash
   ~/mediamtx/startmic.sh
   ```

### Reinstalling or Upgrading

To reinstall or upgrade MediaMTX, simply run the installer script again:
```bash
./install_mediamtx.sh
```

The script will detect your existing installation and offer to update it.

### Uninstalling

An uninstall script is created during installation:
```bash
sudo ~/mediamtx/uninstall_mediamtx.sh
```

This will remove MediaMTX, its services, and optionally its configuration files.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.

## Acknowledgments

- [MediaMTX](https://github.com/bluenviron/mediamtx) - The excellent RTSP server this installer is built for.
