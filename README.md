# 📸 GPSCam 0.1 by @addict

**GPS-enabled camera system for Raspberry Pi**  
Overlay GPS coordinates, speed, and timestamp on a live camera stream — and publish GPS data to Home Assistant via MQTT.

> 🚧 **Still in early development — expect bugs. Contributions welcome!**

---

## 🎯 Project Goals

- Live MJPEG video feed (1920x1080 @ 15fps)
- Overlay:
  - 🕒 Time & Date
  - 📍 GPS Coordinates
  - 🚗 Speed in km/h
- Web-based UI to change settings (resolution, FPS, overlay size, timezone)
- MQTT integration for Home Assistant auto-discovery
- Optional Scrypted RTSP support (via Rebroadcast plugin)

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
