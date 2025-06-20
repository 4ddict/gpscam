#!/bin/bash
set -e

echo "===================================="
echo "  GPSCam Installer"
echo "===================================="
read -p "Enter your Linux username (e.g., pi): " USERNAME
PROJECT_DIR="/home/$USERNAME/gpscam"

echo "[+] Updating system..."
sudo apt update && sudo apt upgrade -y

echo "[+] Installing dependencies..."
sudo apt install -y libcamera-apps libcap-dev python3-flask python3-picamera2 gpsd gpsd-clients \
 python3-pip v4l2loopback-dkms ffmpeg mosquitto mosquitto-clients
pip3 install flask picamera2 gpsd-py3 pynmea2 paho-mqtt

echo "[+] Enabling camera and serial interfaces..."
sudo raspi-config nonint do_camera 0
sudo raspi-config nonint do_serial 1
sudo raspi-config nonint do_serial_hw 0

echo "[+] Creating project directory..."
mkdir -p "$PROJECT_DIR"/{static,templates}
cd "$PROJECT_DIR"

echo "[+] Installing Python packages..."
pip3 install flask picamera2 gpsd-py3 pynmea2 paho-mqtt

echo "[+] Writing Python files..."

cat > app.py << 'EOF'
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
        return redirect("/settings")
    else:
        with open("settings.json") as f:
            settings = json.load(f)
        return render_template("settings.html", settings=settings)

if __name__ == '__main__':
    gps.start()
    camera.start()
    app.run(host='0.0.0.0', port=777, threaded=True)
EOF

cat > camera.py << 'EOF'
from picamera2 import Picamera2
import cv2
from datetime import datetime

class Camera:
    def __init__(self):
        self.picam = Picamera2()
        self.config = self.picam.create_video_configuration(main={"size": (1920, 1080), "format": "RGB888"})
        self.picam.configure(self.config)
        self.picam.start()

    def start(self):
        pass

    def stream_frames(self, gps):
        while True:
            frame = self.picam.capture_array()
            overlay_text = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | {gps.last_coords} | {gps.speed_kmh:.1f} km/h"
            cv2.putText(frame, overlay_text, (10, 1050), cv2.FONT_HERSHEY_SIMPLEX, 1, (255,255,255), 2)
            _, jpeg = cv2.imencode('.jpg', frame)
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n')
EOF

cat > gps.py << 'EOF'
import threading
import gpsd
import time
import paho.mqtt.client as mqtt

class GPSReader(threading.Thread):
    def __init__(self):
        super().__init__()
        gpsd.connect()
        self.last_coords = "N/A"
        self.speed_kmh = 0.0
        self.mqtt = mqtt.Client()
        try:
            self.mqtt.connect("localhost", 1883, 60)
        except:
            print("[!] Could not connect to MQTT broker.")

    def run(self):
        while True:
            try:
                packet = gpsd.get_current()
                if packet.mode >= 2:
                    self.last_coords = f"{packet.lat:.5f}, {packet.lon:.5f}"
                    self.speed_kmh = packet.hspeed() * 3.6
                    self.mqtt.publish("gpscam/coords", f"{packet.lat},{packet.lon}")
                    self.mqtt.publish("gpscam/speed", str(self.speed_kmh))
            except:
                pass
            time.sleep(1)
EOF

cat > settings.json << 'EOF'
{
    "resolution": "1920x1080",
    "fps": "15",
    "timezone": "UTC",
    "overlay_text_size": "1"
}
EOF

echo "[+] Creating HTML templates..."

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

cat > templates/settings.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>GPSCam Settings</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
</head>
<body class="bg-light">
    <div class="container mt-4">
        <h2>Settings</h2>
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

echo "[+] Creating systemd service..."

cat > gpscam.service << EOF
[Unit]
Description=GPSCam Web Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 $PROJECT_DIR/app.py
WorkingDirectory=$PROJECT_DIR
Restart=always
User=$USERNAME

[Install]
WantedBy=multi-user.target
EOF

sudo cp gpscam.service /etc/systemd/system/gpscam.service
sudo systemctl daemon-reexec
sudo systemctl enable gpscam.service
sudo systemctl start gpscam.service

echo "===================================="
echo "   Installation Complete!"
echo "   Access the web UI at:"
echo "   http://<your-pi-ip>:777"
echo "===================================="
