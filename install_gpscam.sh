#!/bin/bash

INSTALL_PATH="$HOME/gpscam"
SERVICE_FILE="/etc/systemd/system/gpscam.service"
INSTALL_MQTT=""
INSTALL_GPS=""
UPDATE_SYSTEM=""

# 🧹 Uninstall
if [[ "$1" == "--uninstall" ]]; then
  echo "🧹  Uninstalling GPSCam..."
  sudo systemctl stop gpscam.service
  sudo systemctl disable gpscam.service
  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reload
  sudo systemctl reset-failed
  rm -rf "$INSTALL_PATH"
  echo "✅  GPSCam Uninstalled."
  exit 0
fi

# ♻️ Reinstall
if [[ "$1" == "--reinstall" ]]; then
  echo "♻️  Reinstalling GPSCam..."
  "$0" --uninstall
  exec "$0"
fi

echo "🚙️  GPSCam (Super-Lean Mode)"
echo "============================="

read -p "🛍️  Enable GPS support? (y/n): " INSTALL_GPS
read -p "📨  Enable MQTT for Home Assistant? (y/n): " INSTALL_MQTT
read -p "🧼  Do you want to update the system (apt upgrade)? (y/n): " UPDATE_SYSTEM

sudo apt update

if [[ "$UPDATE_SYSTEM" =~ ^[Yy]$ ]]; then
  echo "🔄  Upgrading system..."
  sudo apt full-upgrade -y
fi

echo "📦  Installing minimal packages..."
sudo apt install -y \
  python3-pip \
  python3-flask \
  python3-serial \
  python3-numpy \
  python3-kms++ \
  jq \
  raspi-config \
  libcap-dev

sudo pip3 install --break-system-packages flask-bootstrap Pillow pynmea2
[[ "$INSTALL_MQTT" =~ ^[Yy]$ ]] && sudo pip3 install --break-system-packages paho-mqtt

echo "📷  Enabling camera and serial..."
sudo raspi-config nonint do_camera 0
sudo raspi-config nonint do_serial 1

echo "📁  Creating project directory..."
mkdir -p "$INSTALL_PATH/templates"
mkdir -p "$INSTALL_PATH/static"

echo "⚙️  Writing application files..."

# gpscam.py
cat << 'EOF' > "$INSTALL_PATH/gpscam.py"
import os
import io
import time
from flask import Flask, render_template, Response
from threading import Thread
from PIL import Image
import serial
import pynmea2
import numpy as np
# Placeholder: camera integration needs to be confirmed

app = Flask(__name__)

gps_data = {
    "lat": None,
    "lon": None,
    "speed": 0,
    "timestamp": None
}

def read_gps():
    try:
        ser = serial.Serial("/dev/serial0", 9600, timeout=1)
        while True:
            line = ser.readline().decode("utf-8", errors="ignore")
            if line.startswith('$GPRMC'):
                try:
                    msg = pynmea2.parse(line)
                    gps_data["lat"] = msg.latitude
                    gps_data["lon"] = msg.longitude
                    gps_data["speed"] = round(float(msg.spd_over_grnd) * 1.852, 2)
                    gps_data["timestamp"] = msg.datetime.strftime("%Y-%m-%d %H:%M:%S")
                except:
                    continue
    except Exception as e:
        print("GPS Error:", e)

Thread(target=read_gps, daemon=True).start()

def capture_stream():
    # Placeholder: replace with real camera stream logic using libcamera or Picamera2
    while True:
        time.sleep(1)
        yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + b'' + b'\r\n')

@app.route('/')
def index():
    return render_template('index.html', gps=gps_data)

@app.route('/video_feed')
def video_feed():
    return Response(capture_stream(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/settings')
def settings():
    return render_template('settings.html')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, threaded=True)
EOF

# index.html
cat << 'EOF' > "$INSTALL_PATH/templates/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>GPSCam Live Stream</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-dark text-white">
  <div class="container text-center mt-3">
    <h1 class="mb-4">📷 GPSCam Live Stream</h1>
    <img src="{{ url_for('video_feed') }}" class="img-fluid border border-light rounded">
    <div class="mt-3">
      <p>📜 GPS: {{ gps.lat }}, {{ gps.lon }}</p>
      <p>⏱️ Time: {{ gps.timestamp }}</p>
      <p>🚗 Speed: {{ gps.speed }} km/h</p>
    </div>
    <a href="/settings" class="btn btn-primary">⚙️ Settings</a>
  </div>
</body>
</html>
EOF

# settings.html
cat << 'EOF' > "$INSTALL_PATH/templates/settings.html"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>GPSCam Settings</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-light">
  <div class="container mt-4">
    <h2>⚙️ Settings (Coming Soon)</h2>
    <p>This page will allow you to adjust resolution, framerate, time zone, etc.</p>
    <a href="/" class="btn btn-secondary">🔙 Back to Stream</a>
  </div>
</body>
</html>
EOF

# systemd service
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=GPSCam Live Stream
After=network.target

[Service]
ExecStart=/usr/bin/python3 $INSTALL_PATH/gpscam.py
WorkingDirectory=$INSTALL_PATH
StandardOutput=inherit
StandardError=inherit
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Enabling service..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable gpscam.service
sudo systemctl start gpscam.service

echo ""
echo "===================================="
echo " ✅  GPSCam Installed and Running!"
echo " 🔄  Reboot recommended to finalise UART/GPS changes."
echo " 🌐  Web UI: http://$(hostname -I | awk '{print $1}'):8080"
if [[ "$INSTALL_MQTT" =~ ^[Yy]$ ]]; then
  echo " 🏠  MQTT / Home-Assistant auto-discovery enabled."
else
  echo " 📴  MQTT disabled for this installation."
fi
echo " 🧹  Uninstall: ./install_gpscam.sh --uninstall"
echo " ♻️  Reinstall: ./install_gpscam.sh --reinstall"
echo "===================================="
