# LyreBirdAudio
**Production-Ready RTSP Audio Streaming Suite for Multiple USB Microphones**

Transform any Linux system into a professional multi-channel RTSP audio streaming server. LyreBirdAudio automatically detects USB microphones and creates individual RTSP streams for each device, perfect for conference rooms, security systems, multi-track recording, and audio distribution applications.

## Project Motivation

This project was born from a simple desire: I wanted to listen to birds in my backyard using a mini PC and multiple USB microphones. What started as a personal project to stream audio from outdoor microphones has evolved into a robust solution for anyone needing to manage multiple USB audio streams.

The name **LyreBirdAudio** pays homage to the Australian Lyrebird, renowned for its extraordinary ability to accurately reproduce and mimic sounds from its environment - much like how this software captures and streams audio from multiple sources simultaneously.

## Quick Start

```bash
# Install dependencies
sudo apt-get update && sudo apt-get install -y ffmpeg curl wget tar jq alsa-utils usbutils

# Clone and launch
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio
chmod +x *.sh
sudo ./lyrebird-wizard.sh
```

## Key Features

- **Automatic USB Audio Detection**: Plug-and-play support for multiple USB microphones
- **Individual RTSP Streams**: Each microphone gets its own dedicated RTSP endpoint
- **Interactive Setup Wizard**: Guided installation with automatic error recovery
- **Persistent Device Naming**: Map USB devices to friendly, persistent names
- **Production-Grade Reliability**: Auto-restart on failures with intelligent backoff
- **Full systemd Integration**: Automatic startup and proper dependency handling
- **Multiple Codec Support**: Opus (default), AAC, MP3, and PCM
- **Hot-Plug Support**: Add or remove USB devices without system restart
- **TCP/UDP Protocol Support**: Both protocols enabled by default (v1.1.0+)

## Hardware Requirements

### System Requirements
- Linux system with systemd (audio group must exist) and root access
- USB audio devices
- MediaMTX v1.12.3 or newer
- Required packages: `ffmpeg`, `curl`/`wget`, `tar`, `jq`, `alsa-utils`, `usbutils`

### Hardware Recommendations
- **Raspberry Pi 4/5**: Maximum 2 USB microphones (USB bandwidth limitation)
- **Intel N100 Mini PC**: 3-8 microphones (recommended for production)
- **Always use powered USB hubs** for multiple devices

## Installation Methods

### Method 1: Setup Wizard (Recommended)

The interactive wizard provides the easiest installation:

```bash
sudo ./lyrebird-wizard.sh
```

**Wizard Features:**
- Quick Setup for first-time users
- MediaMTX management (install/update/uninstall)
- Stream management and monitoring
- USB device mapping to friendly names
- Configuration backup and restore
- Built-in troubleshooting tools

### Method 2: Manual Installation

```bash
# 1. Map USB devices (optional but recommended)
sudo ./usb-audio-mapper.sh
# Follow prompts and reboot after each device

# 2. Install MediaMTX
sudo ./install_mediamtx.sh install

# 3. Configure and start streams
sudo ./mediamtx-stream-manager.sh install
sudo systemctl enable mediamtx-audio
sudo systemctl start mediamtx-audio
```

## Testing Streams

Streams are available at `rtsp://localhost:8554/[device-name]`

```bash
# Test with VLC
vlc rtsp://localhost:8554/conference-mic-1

# Test with ffplay
ffplay rtsp://localhost:8554/card0

# Check all active streams via API (port 9997)
curl http://localhost:9997/v3/paths/list | jq

# Get detailed stream statistics
curl http://localhost:9997/v3/paths/get/[stream-name] | jq
```

## Configuration

### Audio Device Settings

Edit `/etc/mediamtx/audio-devices.conf`:

```bash
# Per-device configuration example
DEVICE_CONFERENCE_MIC_1_SAMPLE_RATE=44100
DEVICE_CONFERENCE_MIC_1_CHANNELS=1
DEVICE_CONFERENCE_MIC_1_CODEC=opus
DEVICE_CONFERENCE_MIC_1_BITRATE=96k
```

### Production Environment Variables

Configure via systemd:

```bash
sudo systemctl edit mediamtx-audio

[Service]
Environment="USB_STABILIZATION_DELAY=10"
Environment="RESTART_STABILIZATION_DELAY=15"
Environment="DEVICE_TEST_ENABLED=false"
Environment="STREAM_STARTUP_DELAY=10"
Environment="PARALLEL_STREAM_START=false"
Environment="ERROR_HANDLING_MODE=fail-safe"
```

## Version 1.1.0 Release Notes

### Security Enhancements
- **Fixed critical eval vulnerability**: Replaced eval with array-based command execution
- **Input validation**: All user inputs and commands now properly validated
- **Atomic operations**: PID file operations prevent race conditions
- **Safe config parsing**: Configuration files parsed without source/eval

### Stability Improvements
- **Fixed parallel processing bugs**: Resolved double-wait issues in stream startup
- **Race condition fixes**: Wrapper script startup and PID handling improvements
- **Enhanced error handling**: Configurable fail-safe/fail-fast modes
- **TCP/UDP support**: Both protocols now enabled by default for compatibility

### Component Updates
- **mediamtx-stream-manager.sh v1.1.2**: Enhanced FFmpeg process management
- **lyrebird-wizard.sh v1.1.0**: Improved directory detection and safety
- **install_mediamtx.sh v1.0.0**: Better stream preservation during updates
- **usb-audio-mapper.sh v1.1.0**: Deterministic device identification

**Important**: All v1.1.0 changes maintain full backward compatibility with v1.0.0 configurations. No configuration changes required when upgrading.

## Upgrading to v1.1.0

**No breaking changes** - v1.1.0 is a drop-in replacement for v1.0.0.

```bash
# Stop services
sudo systemctl stop mediamtx-audio

# Backup configuration (recommended but optional)
sudo cp -r /etc/mediamtx /etc/mediamtx.backup-$(date +%Y%m%d)

# Update scripts
git pull origin main
chmod +x *.sh

# Restart services
sudo systemctl start mediamtx-audio

# Verify operation
sudo ./mediamtx-stream-manager.sh status
```

## Troubleshooting

### Important File Locations
- **Main log**: `/var/log/mediamtx-audio-manager.log`
- **MediaMTX log**: `/var/log/mediamtx.log`
- **FFmpeg logs**: `/var/lib/mediamtx-ffmpeg/*.log`
- **Service file**: `/etc/systemd/system/mediamtx-audio.service`
- **Configuration**: `/etc/mediamtx/audio-devices.conf`
- **PID files**: `/var/run/mediamtx-audio.pid`, `/var/lib/mediamtx-ffmpeg/*.pid`

### Using the Wizard
```bash
sudo ./lyrebird-wizard.sh
# Select: Troubleshooting
```

### Common Issues

**Streams not starting:**
- Check USB devices: `arecord -l`
- Verify service: `sudo systemctl status mediamtx-audio`
- Check logs: `sudo journalctl -u mediamtx-audio -f`
- Ensure audio group exists: `getent group audio || sudo groupadd audio`

**Audio quality issues:**
- Reduce sample rate to 44100 or 22050
- Use mono for voice applications
- Check USB bandwidth limitations

**Device naming issues:**
- Reboot after mapping each device
- Verify udev rules: `cat /etc/udev/rules.d/99-usb-soundcards.rules`

**Force cleanup stuck processes:**
```bash
# Nuclear option if normal stop fails
sudo pkill -9 mediamtx ffmpeg
sudo rm -f /var/run/mediamtx* /var/lib/mediamtx-ffmpeg/*.pid
sudo alsactl init  # Reset ALSA if devices not responding
```

## Best Practices

1. **Use appropriate hardware** - Mini PCs for 3+ microphones
2. **Map all devices** - Use friendly names for easier management
3. **Use compressed codecs** - Opus or AAC instead of PCM
4. **Sequential startup** - Keep `PARALLEL_STREAM_START=false`
5. **Monitor regularly** - Check logs and stream health
6. **Test failover** - Verify stream recovery after device disconnections

## Uninstallation

```bash
# Using the wizard
sudo ./lyrebird-wizard.sh
# Select: MediaMTX Management → Uninstall

# Or manually
sudo systemctl stop mediamtx-audio
sudo systemctl disable mediamtx-audio
sudo ./install_mediamtx.sh uninstall
sudo rm -rf /etc/mediamtx /var/lib/mediamtx-ffmpeg
```

## Known Limitations

- No built-in RTSP authentication/encryption
- Audio-only (no video support)
- Limited to USB audio devices
- Manual device mapping required for friendly names
- No built-in recording functionality

## Network Ports

LyreBirdAudio uses the following ports (ensure firewall allows them):
- **8554/tcp & udp**: RTSP streaming
- **9997/tcp**: MediaMTX API
- **9998/tcp**: Prometheus metrics (optional)

## Support

For issues and feature requests: [GitHub Issues](https://github.com/tomtom215/LyreBirdAudio/issues)

## Contributors

- **Main development**: [Tom F](https://github.com/tomtom215)
- **Original concept**: [cberge908](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112) - GitHub Gist that inspired this project
- **MediaMTX**: [bluenviron/mediamtx](https://github.com/bluenviron/mediamtx) - The excellent RTSP server this project builds upon

## License

Apache 2.0 License - See LICENSE file for details

---

**Note**: This project is not officially affiliated with the MediaMTX project. Always review scripts before running with sudo privileges.
