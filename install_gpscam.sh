#!/bin/bash
set -e

# === CONFIG ===
SERVICE_NAME=gpscam
if [ -z "$USERNAME" ]; then
  read -p "Enter your Linux username (e.g., pi): " USERNAME
fi
read -p "Do you want to install local MQTT support? (y/n): " INSTALL_MQTT
PROJECT_DIR="/home/$USERNAME/gpscam"
VENV_DIR="$PROJECT_DIR/venv"
# ===

# === Uninstall ===
if [[ "$1" == "--uninstall" ]]; then
  echo "[🔻] Uninstalling GPSCam..."
  sudo systemctl stop $SERVICE_NAME.service || true
  sudo systemctl disable $SERVICE_NAME.service || true
  sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
  sudo systemctl daemon-reload
  sudo systemctl reset-failed
  rm -rf "$PROJECT_DIR"
  echo "[✅] GPSCam removed."
  exit 0
fi

# === Reinstall (wipe + fresh install) ===
if [[ "$1" == "--reinstall" ]]; then
  echo "[♻️] Reinstalling GPSCam..."
  sudo systemctl stop $SERVICE_NAME.service || true
  sudo systemctl disable $SERVICE_NAME.service || true
  sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
  sudo systemctl daemon-reload
  sudo systemctl reset-failed
  rm -rf "$PROJECT_DIR"
  echo "[✅] Cleaned old installation."
  sleep 2
fi

# === OS-level packages ===
echo "[+] Installing APT dependencies..."
sudo apt update && sudo apt install --no-install-recommends -y \
  python3 python3-venv python3-pip \
  python3-libcamera python3-picamera2 libcamera-apps \
  gpsd gpsd-clients

if [[ "$INSTALL_MQTT" =~ ^[Yy]$ ]]; then
  sudo apt install --no-install-recommends -y mosquitto mosquitto-clients
fi

# === Enable UART (for most HAT GPS modules) ===
echo "[+] Configuring UART for GPS module..."
sudo sed -i 's/console=serial0,115200 //g' /boot/cmdline.txt
sudo sed -i '/^enable_uart=/d' /boot/config.txt
echo "enable_uart=1" | sudo tee -a /boot/config.txt > /dev/null

# === gpsd setup ===
echo "[+] Configuring gpsd..."
sudo bash -c 'cat > /etc/default/gpsd <<EOF
START_DAEMON="true"
GPSD_OPTIONS="-n"
DEVICES="/dev/serial0"
USBAUTO="false"
GPSD_SOCKET="/var/run/gpsd.sock"
EOF'
sudo systemctl stop gpsd.socket gpsd || true
sudo systemctl enable gpsd.socket
sudo systemctl start gpsd.socket
sudo systemctl start gpsd

# === Project skeleton ===
echo "[+] Setting up project directory..."
mkdir -p "$PROJECT_DIR"/{static,templates}
cd "$PROJECT_DIR"

python3 -m venv --system-site-packages venv
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install \
  flask==3.0.3 \
  picamera2==0.3.16 \
  gpsd-py3==0.3.0 \
  pynmea2==1.18.0 \
  paho-mqtt==1.6.1 \
  opencv-python-headless==4.9.0.80

# === Runtime settings ===
cat > settings.json << 'EOF'
{
  "resolution": "1920x1080",
  "fps": "15",
  "timezone": "UTC",
  "overlay_text_size": "1"
}
EOF

# === store the MQTT preference for gps.py ===
cat > config.json << EOF
{
  "use_mqtt": "${INSTALL_MQTT,,}"
}
EOF
# ----------------------------------------------------------------------

# === app.py ===
cat > app.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
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
# -*- coding: utf-8 -*-
from picamera2 import Picamera2
import json, cv2
from datetime import datetime

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
        pass  # kept for symmetry

    def stream_frames(self, gps):
        while True:
            frame = self.picam.capture_array()
            overlay = (
                f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | "
                f"{gps.last_coords} | {gps.speed_kmh:.1f} km/h"
            )
            cv2.putText(
                frame, overlay, (10, frame.shape[0]-10),
                cv2.FONT_HERSHEY_SIMPLEX, 1, (255,255,255), 2
            )
            _, jpeg = cv2.imencode('.jpg', frame)
            yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n'
                   + jpeg.tobytes() + b'\r\n')
EOF

# === gps.py ===
cat > gps.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gps.py  – reads GPS via gpsd and *optionally* publishes to MQTT.

If config.json contains `"use_mqtt": "y"` or `"use_mqtt": "Y"`,
MQTT is enabled; otherwise all MQTT code is skipped gracefully.
"""
import json, os, threading, time
import gpsd                # pip install gpsd-py3

# ----------------------------------------------------------------------
# Read user preference --------------------------------------------------
USE_MQTT = False
try:
    with open("config.json") as f:
        cfg = json.load(f)
        USE_MQTT = cfg.get("use_mqtt", "n").lower() == "y"
except Exception:
    # Missing/invalid config → fall back to False
    pass

if USE_MQTT:
    import paho.mqtt.client as mqtt
# ----------------------------------------------------------------------

class GPSReader(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        gpsd.connect()
        self.last_coords = "N/A"
        self.speed_kmh   = 0.0

        # === MQTT init only if requested ===
        self.client = None
        if USE_MQTT:
            try:
                self.client = mqtt.Client()
                self.client.connect("localhost", 1883, 60)
                self.client.loop_start()
                self._publish_discovery()
            except Exception as e:
                # Connection failed → disable MQTT for this run
                print("[GPSCam] MQTT disabled:", e)
                self.client = None

    # === Home-Assistant discovery ===
    def _publish_discovery(self):
        if not self.client:
            return
        self.client.publish(
            "homeassistant/sensor/gpscam_speed/config",
            json.dumps({
                "name": "GPSCam Speed",
                "state_topic": "gpscam/speed",
                "unit_of_measurement": "km/h",
                "unique_id": "gpscam_speed",
                "device": {"identifiers": ["gpscam"], "name": "GPSCam"},
            }),
            retain=True
        )
        self.client.publish(
            "homeassistant/sensor/gpscam_coords/config",
            json.dumps({
                "name": "GPSCam Coords",
                "state_topic": "gpscam/coords",
                "unique_id": "gpscam_coords",
                "device": {"identifiers": ["gpscam"], "name": "GPSCam"},
            }),
            retain=True
        )

    # === Main thread loop ===
    def run(self):
        while True:
            try:
                packet = gpsd.get_current()
                if packet.mode >= 2:                  # 2-D fix or better
                    self.last_coords = (
                        f"{packet.lat:.5f}, {packet.lon:.5f}"
                    )
                    self.speed_kmh = packet.hspeed() * 3.6

                    if self.client:  # publish only when MQTT enabled
                        self.client.publish(
                            "gpscam/coords",
                            f"{packet.lat},{packet.lon}",
                            retain=True
                        )
                        self.client.publish(
                            "gpscam/speed",
                            f"{self.speed_kmh:.2f}",
                            retain=True
                        )
            except Exception:
                pass
            time.sleep(1)
EOF

# === HTML templates ===
cat > templates/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>GPSCam Live</title>
  <link rel="stylesheet"
        href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
</head>
<body class="bg-dark text-light">
  <div class="container text-center mt-4">
    <h1>GPSCam Live Feed</h1>
    <img src="/video_feed"
         class="img-fluid mt-3 border border-light rounded shadow">
    <div class="mt-4">
      <a href="/settings" class="btn btn-outline-light">Settings</a>
    </div>
  </div>
</body>
</html>
EOF

cat > templates/settings.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Settings</title>
  <link rel="stylesheet"
        href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
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

# === systemd service file ===
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
