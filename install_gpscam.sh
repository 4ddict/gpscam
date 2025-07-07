#!/bin/bash
set -e

# === CONFIG ===
SERVICE_NAME=gpscam

if [ -z "$USERNAME" ]; then
  read -p "Enter your Linux username (e.g., pi): " USERNAME
fi

read -p "Install local MQTT support? (y/n): " INSTALL_MQTT
read -p "Install GPS support? (y/n): " INSTALL_GPS

PROJECT_DIR="/home/$USERNAME/gpscam"
VENV_DIR="$PROJECT_DIR/venv"

# === FUNCTIONS ===
clean_installation() {
  echo "[🧹] Cleaning up previous installation..."
  sudo systemctl stop $SERVICE_NAME.service || true
  sudo systemctl disable $SERVICE_NAME.service || true
  sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
  sudo systemctl daemon-reload
  sudo systemctl reset-failed
  rm -rf "$PROJECT_DIR"
  echo "[✅] Previous installation removed."
}

# === Uninstall ===
if [[ "$1" == "--uninstall" ]]; then
  echo "[🔻] Uninstalling GPSCam..."
  clean_installation
  exit 0
fi

# === Reinstall ===
if [[ "$1" == "--reinstall" ]]; then
  echo "[♻️] Reinstalling GPSCam..."
  clean_installation
fi

# === OS-level packages (minimal) ===
echo "[+] Installing minimal APT packages..."
sudo apt update
sudo apt install --no-install-recommends -y \
  python3 python3-venv python3-pip \
  libcamera-apps libjpeg-dev

if [[ "$INSTALL_GPS" =~ ^[Yy]$ ]]; then
  sudo apt install --no-install-recommends -y gpsd gpsd-clients

  echo "[+] Configuring UART for GPS module..."
  sudo sed -i 's/console=serial0,115200 //g' /boot/cmdline.txt
  sudo sed -i '/^enable_uart=/d' /boot/config.txt
  echo "enable_uart=1" | sudo tee -a /boot/config.txt > /dev/null

  echo "[+] Configuring gpsd..."
  sudo bash -c 'cat > /etc/default/gpsd <<EOF
START_DAEMON="true"
GPSD_OPTIONS="-n"
DEVICES="/dev/serial0"
USBAUTO="false"
GPSD_SOCKET="/var/run/gpsd.sock"
EOF'
  sudo systemctl enable gpsd.socket
  sudo systemctl start gpsd.socket
  sudo systemctl start gpsd
fi

if [[ "$INSTALL_MQTT" =~ ^[Yy]$ ]]; then
  sudo apt install --no-install-recommends -y mosquitto mosquitto-clients
fi

# === Project Setup ===
echo "[+] Setting up project directory at $PROJECT_DIR..."
mkdir -p "$PROJECT_DIR"/{static,templates}
cd "$PROJECT_DIR"

python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install \
  flask==3.0.3 \
  picamera2 \
  gpsd-py3==0.3.0 \
  pynmea2==1.18.0 \
  paho-mqtt==1.6.1 \
  Pillow==10.3.0

# === Runtime settings ===
cat > settings.json << 'EOF'
{
  "resolution": "1920x1080",
  "fps": "15",
  "timezone": "UTC",
  "overlay_text_size": "1"
}
EOF

# === Feature flags ===
cat > config.json << EOF
{
  "use_mqtt": "${INSTALL_MQTT,,}",
  "use_gps": "${INSTALL_GPS,,}"
}
EOF

# === app.py ===
cat > app.py << 'EOF'
#!/usr/bin/env python3
from flask import Flask, render_template, Response, request, redirect
from camera import Camera
from gps import GPSReader
import json

app = Flask(__name__)
camera = Camera()
gps = GPSReader()

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/video_feed')
def video_feed():
    return Response(camera.stream_frames(gps), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    if request.method == 'POST':
        with open("settings.json", "w") as f:
            json.dump(request.form.to_dict(), f)
        camera.reload_settings()
        return redirect("/settings")
    else:
        with open("settings.json") as f:
            settings = json.load(f)
        return render_template("settings.html", settings=settings)

if __name__ == '__main__':
    gps.start()
    camera.start()
    app.run(host='0.0.0.0', port=8080, threaded=True)
EOF

# === camera.py ===
cat > camera.py << 'EOF'
#!/usr/bin/env python3
from picamera2 import Picamera2
from datetime import datetime
from PIL import Image, ImageDraw, ImageFont
import json, io
import numpy as np

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

    def start(self):
        pass

    def stream_frames(self, gps):
        font = ImageFont.load_default()
        while True:
            frame = self.picam.capture_array()
            img = Image.fromarray(frame)
            draw = ImageDraw.Draw(img)
            overlay = (
                f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | "
                f"{gps.last_coords} | {gps.speed_kmh:.1f} km/h"
            )
            draw.text((10, img.height - 20), overlay, font=font, fill=(255, 255, 255))

            with io.BytesIO() as buf:
                img.save(buf, format='JPEG')
                yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' +
                       buf.getvalue() + b'\r\n')
EOF

# === gps.py ===
cat > gps.py << 'EOF'
#!/usr/bin/env python3
import json, threading, time

USE_MQTT = False
USE_GPS = False
try:
    with open("config.json") as f:
        cfg = json.load(f)
        USE_MQTT = cfg.get("use_mqtt", "n").lower() == "y"
        USE_GPS = cfg.get("use_gps", "n").lower() == "y"
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
                self._publish_discovery()
            except Exception as e:
                print("[GPSCam] MQTT disabled:", e)
                self.client = None

    def _publish_discovery(self):
        if not self.client:
            return
        self.client.publish("homeassistant/sensor/gpscam_speed/config", json.dumps({
            "name": "GPSCam Speed",
            "state_topic": "gpscam/speed",
            "unit_of_measurement": "km/h",
            "unique_id": "gpscam_speed",
            "device": {"identifiers": ["gpscam"], "name": "GPSCam"}
        }), retain=True)
        self.client.publish("homeassistant/sensor/gpscam_coords/config", json.dumps({
            "name": "GPSCam Coords",
            "state_topic": "gpscam/coords",
            "unique_id": "gpscam_coords",
            "device": {"identifiers": ["gpscam"], "name": "GPSCam"}
        }), retain=True)

    def run(self):
        while True:
            if USE_GPS:
                try:
                    packet = gpsd.get_current()
                    if packet.mode >= 2:
                        self.last_coords = f"{packet.lat:.5f}, {packet.lon:.5f}"
                        self.speed_kmh = packet.hspeed() * 3.6
                        if self.client:
                            self.client.publish("gpscam/coords", f"{packet.lat},{packet.lon}", retain=True)
                            self.client.publish("gpscam/speed", f"{self.speed_kmh:.2f}", retain=True)
                except Exception:
                    pass
            time.sleep(1)
EOF

# === index.html ===
cat > templates/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>GPSCam Live</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
</head>
<body class="bg-dark text-light">
  <div class="container text-center mt-4">
    <h1>GPSCam Live Feed</h1>
    <img src="/video_feed" class="img-fluid mt-3 border border-light rounded shadow">
    <div class="mt-4">
      <a href="/settings" class="btn btn-outline-light">Settings</a>
    </div>
  </div>
</body>
</html>
EOF

# === settings.html ===
cat > templates/settings.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Settings</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
  <div class="container mt-4">
    <h2>GPSCam Settings</h2>
    <form method="post">
      {% for key, value in settings.items() %}
      <div class="mb-3">
        <label class="form-label">{{ key }}</label>
        <input name="{{ key }}" value="{{ value }}" class="form-control">
      </div>
      {% endfor %}
      <button type="submit" class="btn btn-primary">Save</button>
      <a href="/" class="btn btn-secondary">Back</a>
    </form>
  </div>
</body>
</html>
EOF

# === systemd service ===
cat > $SERVICE_NAME.service << EOF
[Unit]
Description=GPSCam Web UI
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
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl restart $SERVICE_NAME

# === Final Info ===
echo "===================================="
echo " ✅  GPSCam Installed and Running!"
echo " 🌐  Web UI: http://$(hostname -I
