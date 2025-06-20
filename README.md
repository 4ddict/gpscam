# 📸 GPSCam 0.1 by addict

**GPS-enabled camera system for Raspberry Pi**  
Overlay GPS coordinates, speed, and timestamp on a live camera stream — and publish GPS data to Home Assistant via MQTT (optional).

> 🚧 **Still in early development — expect bugs. Contributions welcome!**

---

## 🎯 Project Goals

- Live MJPEG video feed with data overlayed
- Overlay:
  - 🕒 Time & Date
  - 📍 GPS Coordinates
  - 🚗 Speed in km/h
- Web-based UI to change settings (resolution, FPS, overlay size, timezone)
- MQTT integration for Home Assistant auto-discovery

---

## 📦 What You’ll Need

| Component        | Model Tested          |
|------------------|-----------------------|
| Raspberry Pi     | Zero 2 W              |
| Camera Module    | OV5647                |
| GPS Module       | NEO-8M (w/ antenna)   |

Raspberry Pi OS Lite (Bookworm)  
Kernel version: 6.12, Release: May 13, 2025

---

## 🚀 Easy Install (1-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/4ddict/gpscam/main/install_gpscam.sh -o install_gpscam.sh && chmod +x install_gpscam.sh && ./install_gpscam.sh
```

---

## 🛠 Manual Install

```bash
chmod +x install_gpscam.sh
./install_gpscam.sh
```

You’ll be prompted for your username (e.g. `pi`, `addict`, etc.)

---

## 🌐 Web Interface

- Web stream: [http://YOUR_PI_IP:8080](http://YOUR_PI_IP:8080)
- MJPEG URL for Scrypted: `http://YOUR_PI_IP:8080/video_feed`

---

## 🧹 Management

| Action         | Command                        |
|----------------|---------------------------------|
| ✅ Fresh install   | `./install_gpscam.sh`           |
| ♻️ Reinstall       | `./install_gpscam.sh --reinstall` |
| ❌ Uninstall       | `./install_gpscam.sh --uninstall` |

---

## 💬 Home Assistant Integration

GPS data is published to MQTT topics:

- `gpscam/coords`
- `gpscam/speed`

Auto-discovery enabled for Home Assistant MQTT sensors.

---

## 📦 What Gets Installed

- Flask + Picamera2 for MJPEG stream
- GPSD + gpsd-py3 for serial GPS
- OpenCV2 for video overlay
- MQTT for Home Assistant support
- systemd service for auto-start

---

## ✅ Status

- ✅ Tested on Raspberry Pi Zero W 2
- ✅ Fresh Raspbian Lite (Bookworm)
- ✅ Works with Scrypted (via Rebroadcast plugin)

---

## 👨‍💻 Author

Made with ❤️ by **@addict**

Got feedback or ideas? [Open an issue](https://github.com/4ddict/gpscam/issues) or fork away!
