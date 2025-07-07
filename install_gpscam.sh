#!/bin/bash
set -e

# === CONFIG ===
SERVICE_NAME=gpscam
if [ -z "$USERNAME" ]; then
  read -p "Enter your Linux username (e.g., pi): " USERNAME
fi
read -p "Enable MQTT support? (y/n): " INSTALL_MQTT
read -p "Enable GPS support? (y/n): " INSTALL_GPS
PROJECT_DIR="/home/$USERNAME/gpscam"
VENV_DIR="$PROJECT_DIR/venv"

# === OS packages ===
echo "[+] Installing system packages..."
sudo apt update
sudo apt install -y python3 python3-pip python3-venv python3-picamera2
[[ "$INSTALL_GPS" =~ ^[Yy]$ ]] && sudo apt install -y gpsd gpsd-clients
[[ "$INSTALL_MQTT" =~ ^[Yy]$ ]] && sudo apt install -y mosquitto mosquitto-clients

# === Project Setup ===
echo "[+] Setting up project..."
mkdir -p "$PROJECT_DIR/templates"
cd "$PROJECT_DIR"

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask pillow numpy
[[ "$INSTALL_GPS" =~ ^[Yy]$ ]] && pip install gpsd-py3
[[ "$INSTALL_MQTT" =~ ^[Yy]$ ]] && pip install paho-mqtt pynmea2

# === Config files ===
cat > config.json <<EOF
{
  "use_mqtt": "${INSTALL_MQTT,,}",
  "use_gps": "${INSTALL_GPS,,}"
}
EOF

cat > settings.json <<'EOF'
{
  "resolution": "1280x720",
  "fps": "15"
}
EOF

# === Flask app ===
cat > app.py <<'EOF'
from flask import Flask, render_template, Response
from camera import Camera
from gps import GPSReader

app = Flask(__name__)
camera = Camera()
gps = GPSReader()

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/video_feed')
def video_feed():
    return Response(camera.stream_frames(gps), mimetype='multipart/x-mixed-replace; boundary=frame')

if __name__ == '__main__':
    gps.start()
    app.run(host='0.0.0.0', port=8080, threaded=True)
EOF

# === Camera code ===
cat > camera.py <<'EOF'
from picamera2 import Picamera2
from PIL import Image, ImageDraw, ImageFont
import numpy as np
from datetime import datetime
import json
from io import BytesIO

class Camera:
    def __init__(self):
        self.picam = Picamera2()
        self.reload_settings()

    def reload_settings(self):
        with open("settings.json") as f:
            settings = json.load(f)
        res = tuple(map(int, settings["resolution"].split("x")))
        fps = int(settings["fps"])
        self.picam.stop()
        self.config = self.picam.create_video_configuration(
            main={"size": res, "format": "RGB888"},
            controls={"FrameRate": fps}
        )
        self.picam.configure(self.config)
        self.picam.start()

    def stream_frames(self, gps):
        font = ImageFont.load_default()
        while True:
            frame = self.picam.capture_array()
            img = Image.fromarray(frame)
            draw = ImageDraw.Draw(img)
            overlay = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | {gps.last_coords} | {gps.speed_kmh:.1f} km/h"
            draw.text((10, img.height - 30), overlay, font=font, fill=(255,255,255))
            with BytesIO() as output:
                img.save(output, format="JPEG")
                jpeg = output.getvalue()
            yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + jpeg + b'\r\n')
EOF

# === GPS code ===
cat > gps.py <<'EOF'
import json, threading, time

USE_GPS = False
USE_MQTT = False

try:
    with open("config.json") as f:
        cfg = json.load(f)
        USE_GPS = cfg.get("use_gps", "n").lower() == "y"
        USE_MQTT = cfg.get("use_mqtt", "n").lower() == "y"
except Exception:
    pass

if USE_GPS:
    import gpsd
    gpsd.connect()
if USE_MQTT:
    import paho.mqtt.client as mqtt

class GPSReader(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.last_coords = "N/A"
        self.speed_kmh = 0.0
        self.client = None

        if USE_MQTT:
            try:
                self.client = mqtt.Client()
                self.client.connect("localhost", 1883, 60)
                self.client.loop_start()
            except:
                self.client = None

    def run(self):
        while True:
            if not USE_GPS:
                time.sleep(1)
                continue
            try:
                packet = gpsd.get_current()
                if packet.mode >= 2:
                    self.last_coords = f"{packet.lat:.5f}, {packet.lon:.5f}"
                    self.speed_kmh = packet.hspeed() * 3.6
                    if self.client:
                        self.client.publish("gpscam/coords", self.last_coords, retain=True)
                        self.client.publish("gpscam/speed", f"{self.speed_kmh:.2f}", retain=True)
            except:
                pass
            time.sleep(1)
EOF

# === Template ===
cat > templates/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>GPSCam</title>
</head>
<body>
  <h1>GPSCam Live Feed</h1>
  <img src="/video_feed">
</body>
</html>
EOF

# === Systemd ===
cat > $SERVICE_NAME.service <<EOF
[Unit]
Description=GPSCam
After=network.target

[Service]
ExecStart=$VENV_DIR/bin/python $PROJECT_DIR/app.py
WorkingDirectory=$PROJECT_DIR
Restart=always
User=$USERNAME
Environment="PYTHONUNBUFFERED=1"
ExecStartPre=/bin/sleep 5

[Install]
WantedBy=multi-user.target
EOF

sudo cp $SERVICE_NAME.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl restart $SERVICE_NAME

IP=$(hostname -I | awk '{print $1}')
echo "\n✅ GPSCam running at: http://$IP:8080"
[[ "$INSTALL_GPS" =~ ^[Yy]$ ]] && echo "📡 GPS enabled" || echo "❌ GPS disabled"
[[ "$INSTALL_MQTT" =~ ^[Yy]$ ]] && echo "📻 MQTT enabled" || echo "❌ MQTT disabled"
