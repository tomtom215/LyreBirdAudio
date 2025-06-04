# MediaMTX Audio Stream Manager

# Currently this is not in a working state, please issues and bugs until this meesage has been removed. 

Automatic MediaMTX configuration and management for continuous 24/7 RTSP audio streaming from USB audio devices.

## Overview

This script automatically detects USB audio devices and creates MediaMTX configurations with FFmpeg publishers for continuous RTSP audio streams. It includes automatic recovery, device hot-plug support, and comprehensive monitoring capabilities.

### Key Features

- Automatic USB audio device detection and configuration
- Self-healing FFmpeg streams with intelligent restart logic
- Per-device audio parameter customization
- Comprehensive logging and monitoring
- Systemd service integration
- Clean process management with proper signal handling

## Requirements

### System Requirements

- Linux-based operating system with ALSA support
- Root/sudo access for device access and service management
- USB audio devices compatible with ALSA

### Software Dependencies

- MediaMTX v1.12.3 or later (install using provided install_mediamtx.sh script)
- FFmpeg with opus, aac, and mp3 codec support
- Standard utilities: bash, jq, curl, arecord
- Python3 with yaml module (optional, for configuration validation)

### Network Requirements

- Port 8554 (RTSP server)
- Port 9997 (MediaMTX API)
- Port 9998 (MediaMTX metrics)

## Installation

1. Download the script to your desired location:
```bash
wget https://your-repo/mediamtx-audio-stream-manager.sh
chmod +x mediamtx-audio-stream-manager.sh
```

2. Install MediaMTX if not already installed:
```bash
# Use the companion install_mediamtx.sh script or install manually
sudo wget -O /usr/local/bin/mediamtx https://github.com/bluenviron/mediamtx/releases/download/v1.12.3/mediamtx_v1.12.3_linux_amd64.tar.gz
sudo chmod +x /usr/local/bin/mediamtx
```

3. Install required dependencies:
```bash
sudo apt-get update
sudo apt-get install -y ffmpeg jq curl alsa-utils python3-yaml
```

4. Create systemd service (optional):
```bash
sudo ./mediamtx-audio-stream-manager.sh install
```

## Configuration

### Audio Device Configuration

The script creates a configuration file at `/etc/mediamtx/audio-devices.conf` where you can customize per-device audio parameters.

Default parameters:
- Sample Rate: 48000 Hz
- Channels: 2 (stereo)
- Format: s16le
- Codec: opus
- Bitrate: 128k
- ALSA Buffer: 100000 microseconds
- ALSA Period: 20000 microseconds

To override settings for a specific device:
```bash
# Edit /etc/mediamtx/audio-devices.conf
DEVICE_USB_BLUE_YETI_SAMPLE_RATE=44100
DEVICE_USB_BLUE_YETI_CHANNELS=1
DEVICE_USB_BLUE_YETI_ALSA_BUFFER=200000
```

Device names are sanitized to uppercase with underscores. Check the device variable prefix using:
```bash
sudo ./mediamtx-audio-stream-manager.sh config
```

### Stream Path Naming

Stream paths are automatically generated from device names:
- Special characters are replaced with underscores
- Names are converted to lowercase
- Consecutive underscores are collapsed

Example: `usb-Blue_Yeti_Audio-00` becomes `rtsp://localhost:8554/blue_yeti_audio_00`

## Usage

### Basic Commands

```bash
# Start all streams
sudo ./mediamtx-audio-stream-manager.sh start

# Stop all streams
sudo ./mediamtx-audio-stream-manager.sh stop

# Restart all streams
sudo ./mediamtx-audio-stream-manager.sh restart

# Check status
sudo ./mediamtx-audio-stream-manager.sh status

# View configuration
sudo ./mediamtx-audio-stream-manager.sh config

# Monitor streams in real-time
sudo ./mediamtx-audio-stream-manager.sh monitor

# Debug stream issues
sudo ./mediamtx-audio-stream-manager.sh debug
```

### Systemd Service

If installed as a systemd service:
```bash
# Enable automatic startup
sudo systemctl enable mediamtx-audio

# Start service
sudo systemctl start mediamtx-audio

# Check service status
sudo systemctl status mediamtx-audio

# View service logs
sudo journalctl -u mediamtx-audio -f
```

### Accessing Streams

Streams are available via RTSP at:
```
rtsp://localhost:8554/<stream_path>
```

Test stream playback:
```bash
# Using ffplay
ffplay rtsp://localhost:8554/<stream_path>

# Using VLC
vlc rtsp://localhost:8554/<stream_path>

# Using ffmpeg (verify stream)
ffmpeg -i rtsp://localhost:8554/<stream_path> -t 10 -f null -
```

## File Locations

- Main configuration: `/etc/mediamtx/mediamtx.yml`
- Device configuration: `/etc/mediamtx/audio-devices.conf`
- Manager log: `/var/log/mediamtx-audio-manager.log`
- MediaMTX log: `/var/log/mediamtx.log`
- FFmpeg logs: `/var/lib/mediamtx-ffmpeg/<stream_name>.log`
- PID files: `/var/run/mediamtx-audio.pid`, `/var/lib/mediamtx-ffmpeg/*.pid`

## Troubleshooting

### No Audio Devices Detected

1. Verify USB devices are connected:
```bash
lsusb
arecord -l
```

2. Check device permissions:
```bash
ls -la /dev/snd/
```

3. Ensure user is in audio group:
```bash
sudo usermod -a -G audio $USER
```

### Stream Not Starting

1. Check device accessibility:
```bash
sudo ./mediamtx-audio-stream-manager.sh debug
```

2. Review FFmpeg logs:
```bash
sudo tail -50 /var/lib/mediamtx-ffmpeg/*.log
```

3. Verify MediaMTX is running:
```bash
sudo ./mediamtx-audio-stream-manager.sh status
ps aux | grep mediamtx
```

### Audio Quality Issues

1. Increase ALSA buffer size in device configuration:
```bash
DEVICE_<NAME>_ALSA_BUFFER=200000
```

2. Try different audio formats if device supports them:
```bash
DEVICE_<NAME>_FORMAT=s24le
```

3. Adjust thread queue size for stability:
```bash
DEVICE_<NAME>_THREAD_QUEUE=16384
```

### High CPU Usage

1. Avoid PCM codec for network streams (uses excessive bandwidth)
2. Use compressed codecs: opus (recommended), aac, or mp3
3. Check for multiple FFmpeg instances:
```bash
ps aux | grep ffmpeg
```

### Port Conflicts

1. Check if ports are in use:
```bash
sudo lsof -i :8554
sudo lsof -i :9997
sudo lsof -i :9998
```

2. Stop conflicting services or change MediaMTX ports in configuration

## Monitoring

### API Endpoints

- Stream list: `http://localhost:9997/v3/paths/list`
- Stream details: `http://localhost:9997/v3/paths/get/<stream_path>`
- Metrics: `http://localhost:9998/metrics`

### Log Monitoring

```bash
# Manager logs
tail -f /var/log/mediamtx-audio-manager.log

# MediaMTX logs
tail -f /var/log/mediamtx.log

# FFmpeg logs
tail -f /var/lib/mediamtx-ffmpeg/*.log

# All logs
sudo ./mediamtx-audio-stream-manager.sh debug
```

## Uninstallation

### Complete Removal

1. Stop all services:
```bash
sudo ./mediamtx-audio-stream-manager.sh stop
sudo systemctl stop mediamtx-audio
sudo systemctl disable mediamtx-audio
```

2. Remove systemd service:
```bash
sudo rm /etc/systemd/system/mediamtx-audio.service
sudo systemctl daemon-reload
```

3. Remove configuration and logs:
```bash
sudo rm -rf /etc/mediamtx
sudo rm -f /var/log/mediamtx*
sudo rm -rf /var/lib/mediamtx-ffmpeg
```

4. Remove PID files:
```bash
sudo rm -f /var/run/mediamtx-audio.pid
```

5. Remove the script:
```bash
rm mediamtx-audio-stream-manager.sh
```

### Partial Cleanup

To remove only stream data while preserving configuration:
```bash
sudo ./mediamtx-audio-stream-manager.sh stop
sudo rm -rf /var/lib/mediamtx-ffmpeg/*
sudo rm -f /var/log/mediamtx*.log
```

## Technical Details

### Architecture

The system consists of three main components:

1. **MediaMTX Server**: RTSP server that handles client connections
2. **FFmpeg Publishers**: One per audio device, publishes audio to MediaMTX
3. **Wrapper Scripts**: Monitor and restart FFmpeg processes as needed

### Recovery Mechanism

- Wrapper scripts monitor FFmpeg processes and restart on failure
- Smart backoff delays prevent rapid restart loops
- Device removal detection stops unnecessary restart attempts
- Extended delays after multiple short runs indicate persistent issues

### Signal Handling

- Proper signal propagation ensures clean shutdown
- Lock files prevent concurrent operations
- PID tracking enables precise process management

## Known Limitations

1. USB audio devices must be ALSA-compatible
2. Device hot-plug requires manual restart to detect new devices
3. Maximum path name length restrictions apply
4. Some USB devices may require specific ALSA parameters for stability

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review logs for error messages
3. Verify all dependencies are installed
4. Ensure devices are properly connected and recognized by the system

## License

[Specify your license here]

## Version History

- 7.3.0: Fixed syntax errors, improved MediaMTX v1.12.3 compatibility
- 7.2.0: Complete rewrite for MediaMTX official schema
- Earlier versions: Legacy implementations

## License and Contributors

This software is released under the Apache 2.0 License.

### Contributors

- Main project development and maintenance
- Based on original concept by Cberge908 [GitHub gist](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)

### Acknowledgments

- [MediaMTX](https://github.com/bluenviron/mediamtx) for the excellent RTSP server
- All testers and users who provided feedback

### Disclaimer

This project is not officially affiliated with the MediaMTX project.

Always review scripts before running them with sudo privileges.
