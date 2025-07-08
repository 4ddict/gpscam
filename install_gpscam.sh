#!/bin/bash

PROJECT_DIR="$HOME/gpscam"
SERVICE_FILE="/etc/systemd/system/gpscam.service"
PYTHON_ENV="$PROJECT_DIR/venv"

print_header() {
  echo "===================================="
  echo " 🚀 GPSCam Setup Script"
  echo "===================================="
}

prompt_yes_no() {
  local prompt="$1"
  local var
  while true; do
    read -rp "$prompt [Y/n]: " var
    case "$var" in
      [Yy]*|"") return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

uninstall_gpscam() {
  echo "🧼 Uninstalling GPSCam..."

  sudo systemctl stop gpscam
  sudo systemctl disable gpscam
  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reexec

  rm -rf "$PROJECT_DIR"

  echo "✅ Uninstalled."
  exit 0
}

reinstall_gpscam() {
  uninstall_gpscam
  sleep 2
  install_gpscam
}

install_gpscam() {
  print_header

  [[ "$1" == "--uninstall" ]] && uninstall_gpscam
  [[ "$1" == "--reinstall" ]] && reinstall_gpscam

  # Prompt user
  UPDATE_SYS=false
  ENABLE_GPS=false
  INSTALL_MQTT=false

  if prompt_yes_no "🔄 Update system packages?"; then UPDATE_SYS=true; fi
  if prompt_yes_no "📡 Enable and use GPS module?"; then ENABLE_GPS=true; fi
  if prompt_yes_no "🏠 Enable MQTT for Home Assistant?"; then INSTALL_MQTT=true; fi

  if $UPDATE_SYS; then
    echo "🔄 Updating system..."
    sudo apt update && sudo apt full-upgrade -y
  fi

  echo "📦 Installing dependencies..."
  sudo apt install -y python3 python3-pip python3-venv libatlas-base-dev \
    libjpeg-dev libtiff5-dev libjasper-dev libpng-dev libavcodec-dev \
    libavformat-dev libswscale-dev libv4l-dev libgtk2.0-dev libcanberra-gtk* \
    gpsd gpsd-clients python3-gps python3-opencv python3-flask fswebcam

  if $ENABLE_GPS; then
    echo "🛠 Enabling serial and GPS..."
    sudo raspi-config nonint do_serial 1
    sudo systemctl enable gpsd
    sudo systemctl start gpsd
  fi

  echo "📁 Setting up project directory at $PROJECT_DIR..."
  mkdir -p "$PROJECT_DIR/app/static"
  mkdir -p "$PROJECT_DIR/app/templates"

  # Write basic files
  cat > "$PROJECT_DIR/app/server.py" <<EOF
from flask import Flask, render_template, Response
import cv2
from datetime import datetime
import threading
import time

app = Flask(__name__)
camera = cv2.VideoCapture(0)

def gen_frames():
    while True:
        success, frame = camera.read()
        if not success:
            break
        else:
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            cv2.putText(frame, timestamp, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, (255,255,255), 2)
            ret, buffer = cv2.imencode('.jpg', frame)
            frame = buffer.tobytes()
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/video_feed')
def video_feed():
    return Response(gen_frames(), mimetype='multipart/x-mixed-replace; boundary=frame')

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=8080)
EOF

  cat > "$PROJECT_DIR/app/templates/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <title>GPSCam Live</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  </head>
  <body>
    <div class="container text-center">
      <h1 class="mt-4">📷 GPSCam Live Feed</h1>
      <img src="{{ url_for('video_feed') }}" class="img-fluid mt-3">
    </div>
  </body>
</html>
EOF

  echo "🔧 Creating virtual environment..."
  python3 -m venv "$PYTHON_ENV"
  source "$PYTHON_ENV/bin/activate"
  pip install --upgrade pip flask opencv-python

  echo "📜 Setting up systemd service..."
  sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=GPSCam Web Service
After=network.target

[Service]
ExecStart=$PYTHON_ENV/bin/python $PROJECT_DIR/app/server.py
WorkingDirectory=$PROJECT_DIR/app
Restart=always
User=$USER
Environment=FLASK_ENV=production

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable gpscam
  sudo systemctl start gpscam

  echo "===================================="
  echo " ✅  GPSCam Installed and Running!"
  echo " 🔄  Reboot recommended to finalise UART/GPS changes."
  echo " 🌐  Web UI: http://$(hostname -I | awk '{print $1}'):8080"
  if $INSTALL_MQTT; then
    echo " 🏠  MQTT / Home-Assistant auto-discovery enabled."
  else
    echo " 📴  MQTT disabled for this installation."
  fi
  echo " 🧹  Uninstall: ./install_gpscam.sh --uninstall"
  echo " ♻️  Reinstall: ./install_gpscam.sh --reinstall"
  echo "===================================="
}

install_gpscam "$@"
