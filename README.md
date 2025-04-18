# MediaMTX Audio RTSP Streaming System

A production-ready system for automatically creating RTSP audio streams from USB sound cards on Linux. The system detects all available audio capture devices and creates robust, auto-restarting RTSP streams that are accessible over the network.

## Features

- **Automatic Installation**: Simple scripts to install and configure everything
- **Auto-Detection**: Automatically detects and creates streams for all USB audio devices
- **High Reliability**: Services auto-restart on failure and resume after system reboot
- **Production-Ready**: Designed for 24/7 operation with proper logging and monitoring
- **Easy Management**: Helper scripts to check status and troubleshoot issues

## System Components

1. **MediaMTX**: RTSP server for streaming audio
2. **startmic.sh**: Script that creates RTSP streams from connected audio devices
3. **SystemD Services**: Ensures everything starts on boot and auto-restarts on failure

## Installation

### Step 1: Install MediaMTX

```bash
# Download the installer script
wget https://github.com/tomtom215/mediamtx-rtsp-setup/install_mediamtx.sh
# Make it executable
chmod +x install_mediamtx.sh
# Run it
sudo ./install_mediamtx.sh
```

This will:
- Install FFmpeg dependency
- Download the latest MediaMTX release for your architecture
- Install MediaMTX to `/usr/local/mediamtx/`
- Create and enable a systemd service

### Step 2: Install Audio RTSP Streaming Service

```bash
# Download the setup script
wget https://github.com/tomtom215/mediamtx-rtsp-setup/setup_audio_rtsp.sh
# Make it executable
chmod +x setup_audio_rtsp.sh
# Run it
sudo ./setup_audio_rtsp.sh
```

This will:
- Install the startmic.sh script to /usr/local/bin
- Create a systemd service for audio streaming
- Set up log rotation
- Create a status-checking helper script
- Enable and start the service

### Step 3: Verify Installation

Check that everything is working:

```bash
sudo check-audio-rtsp.sh
```

This will show:
- Service status
- Running audio streams
- Available sound cards
- Network access information

## How It Works

### Stream Generation

The system:
1. Detects all sound cards with capture capabilities
2. Skips system audio devices (like bcm2835_headphones and HDMI outputs)
3. Creates uniquely named RTSP streams based on the sound card ID
4. Launches ffmpeg instances to capture audio and stream it via RTSP

### Boot Process

1. System starts
2. MediaMTX service starts automatically
3. Audio RTSP service starts automatically (after MediaMTX)
4. Audio streams are created from all available capture devices

### Failure Recovery

The system is designed to be highly resilient:

- If MediaMTX crashes, its service will restart it automatically
- If the audio streaming service crashes, it will restart automatically
- If individual ffmpeg processes fail, the service will restart all streams
- If the system reboots, everything starts automatically
- Resource limits are set to prevent system overload

## Configuration

### MediaMTX Configuration

The MediaMTX configuration file is located at:
```
/usr/local/mediamtx/mediamtx.yml
```

You can edit this file to change RTSP server settings like port, authentication, etc.

### Audio Stream Configuration

The audio streaming script is located at:
```
/usr/local/bin/startmic.sh
```

You can modify this script to:
- Change audio encoding parameters
- Add additional processing to streams
- Customize stream naming

After modifying, restart the service:
```bash
sudo systemctl restart audio-rtsp
```

## Management

### Checking Status

```bash
# View service status
sudo systemctl status audio-rtsp

# Comprehensive status check
sudo check-audio-rtsp.sh

# View logs
sudo journalctl -u audio-rtsp -f

# See running ffmpeg processes
ps aux | grep ffmpeg
```

### Controlling Services

```bash
# Stop services
sudo systemctl stop audio-rtsp
sudo systemctl stop mediamtx

# Start services
sudo systemctl start mediamtx
sudo systemctl start audio-rtsp

# Restart only the audio streaming
sudo systemctl restart audio-rtsp

# Restart the entire RTSP system
sudo systemctl restart mediamtx audio-rtsp
```

### Logs

Logs are stored in:
- `/var/log/audio-rtsp/audio-streams.log` - For the audio streaming service
- System journal (access with `journalctl -u audio-rtsp` or `journalctl -u mediamtx`)

Log rotation is configured to prevent logs from filling up disk space.

## Updating

### Updating MediaMTX

To update MediaMTX to the latest version:

```bash
# Re-run the installer script
sudo ./install_mediamtx.sh
```

The script will download the latest version and install it.

### Updating Audio RTSP Service

To update the audio RTSP service:

```bash
# Stop the service
sudo systemctl stop audio-rtsp

# Update the script
# (Place your updated startmic.sh in the current directory)
sudo cp startmic.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/startmic.sh

# Restart the service
sudo systemctl restart audio-rtsp
```

### Full System Update

To update the entire system:

1. Stop the services:
   ```bash
   sudo systemctl stop audio-rtsp mediamtx
   ```

2. Run the installers again:
   ```bash
   sudo ./install_mediamtx.sh
   sudo ./setup_audio_rtsp.sh
   ```

## Troubleshooting

### No Streams Found

If no streams are visible:

1. Check if sound cards are detected:
   ```bash
   cat /proc/asound/cards
   ```

2. Verify capture capabilities:
   ```bash
   arecord -l
   ```

3. Check service status:
   ```bash
   sudo systemctl status audio-rtsp
   ```

4. Check logs:
   ```bash
   sudo journalctl -u audio-rtsp -n 100
   ```

### Stream Issues

If streams start but have problems:

1. Check ffmpeg processes:
   ```bash
   ps aux | grep ffmpeg
   ```

2. Try manually starting a stream to see error output:
   ```bash
   ffmpeg -f alsa -ac 1 -i plughw:CARD=soundcard1,DEV=0 -acodec libmp3lame -b:a 160k -ac 2 -f rtsp rtsp://localhost:8554/test
   ```

3. Verify MediaMTX is running:
   ```bash
   sudo systemctl status mediamtx
   ```

### USB Device Issues

If USB devices aren't being recognized correctly:

1. Check USB device connections
   ```bash
   lsusb
   ```

2. List all sound devices with capture capability:
   ```bash
   arecord -l
   ```

3. Check if udev rules are working:
   ```bash
   ls -la /dev/snd/
   ```

4. Try restarting the udev service:
   ```bash
   sudo service udev restart
   ```

5. Replug the USB devices and check logs:
   ```bash
   dmesg | tail
   ```

### Network Access Issues

If you can't access streams from other devices:

1. Check firewall settings:
   ```bash
   sudo iptables -L
   ```

2. Ensure port 8554 (RTSP) is open:
   ```bash
   sudo ufw status
   # If using UFW, add a rule if needed:
   sudo ufw allow 8554/tcp
   ```

3. Verify the server's IP address:
   ```bash
   hostname -I
   ```

4. Test local access first:
   ```bash
   ffplay rtsp://localhost:8554/streamname
   ```

## Advanced Configuration

### Custom Stream Names

To customize stream names based on USB port or device, edit the udev rules with the help of my other project - https://github.com/tomtom215/udev-audio-mapper

or Manually do it yourself with an example below:

```bash
sudo nano /etc/udev/rules.d/99-usb-soundcards.rules
```

Add rules like:
```
SUBSYSTEM=="sound", KERNELS=="1-1.3*", ATTRS{idVendor}=="2e88", ATTRS{idProduct}=="4610", ATTR{id}="frontmic"
```

Then restart the udev service and the audio-rtsp service.

### Stream Quality Settings

To change audio quality settings, edit `/usr/local/bin/startmic.sh` and modify the ffmpeg parameters:

```bash
ffmpeg -nostdin -f alsa -ac 1 -i "plughw:CARD=$CARD_ID,DEV=0" \
       -acodec libmp3lame -b:a 320k -ac 2 -content_type 'audio/mpeg' \
       -f rtsp "$RTSP_URL" -rtsp_transport tcp &
```

Adjust `-b:a 320k` for higher bitrate, or change `-acodec` for different encoding.

## License

This installer script and associated software are provided under the Apache 2.0 License.

## Disclaimer

This script is not officially affiliated with the MediaMTX project. Always review scripts before running them with sudo privileges.
