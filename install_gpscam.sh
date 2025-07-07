#!/bin/bash
set -e

# === CONFIG ===
SERVICE_NAME=gpscam
if [ -z "$USERNAME" ]; then
  read -p "Enter your Linux username (e.g., pi): " USERNAME
fi
read -p "Do you want to install local MQTT support? (y/n): " INSTALL_MQTT
read -p "Do you want to enable GPS support? (y/n): " INSTALL_GPS
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
  python3-libcamera python3-picamera2 libcamera-apps

if [[ "$INSTALL_GPS" =~ ^[Yy]$ ]]; then
  sudo apt install --no-install-recommends -y gpsd gpsd-clients
fi

if [[ "$INSTALL_MQTT" =~ ^[Yy]$ ]]; then
  sudo apt install --no-install-recommends -y mosquitto mosquitto-clients
fi

# === UART Config ===
if [[ "$INSTALL_GPS" =~ ^[Yy]$ ]]; then
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
  sudo systemctl stop gpsd.socket gpsd || true
  sudo systemctl enable gpsd.socket
  sudo systemctl start gpsd.socket
  sudo systemctl start gpsd
fi

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
  pillow==10.3.0

if [[ "$INSTALL_GPS" =~ ^[Yy]$ ]]; then pip install gpsd-py3 pynmea2; fi
if [[ "$INSTALL_MQTT" =~ ^[Yy]$ ]]; then pip install paho-mqtt; fi

# === Runtime settings ===
cat > settings.json << 'EOF'
{
  "resolution": "1920x1080",
  "fps": "15",
  "timezone": "UTC",
  "overlay_text_size": "1"
}
EOF

cat > config.json << EOF
{
  "use_mqtt": "${INSTALL_MQTT,,}",
  "use_gps": "${INSTALL_GPS,,}"
}
EOF

# === Add app.py / camera.py / gps.py / templates... ===
# [KEEP using your original app.py, gps.py, and templates, but:
#   -> Replace cv2.putText in `camera.py` with Pillow drawing.]

# Example patch to camera.py:
sed -i 's/import json, cv2/import json\nfrom PIL import Image, ImageDraw, ImageFont/' camera.py
# Replace cv2.putText(...) block with equivalent PIL draw.text

# === systemd setup ===
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
[[ "$INSTALL_MQTT" =~ ^[Yy]$ ]] && echo " 🏠  MQTT / Home-Assistant auto-discovery enabled." || echo " 📴  MQTT disabled."
[[ "$INSTALL_GPS" =~ ^[Yy]$ ]] && echo " 🧭  GPS enabled." || echo " ❌  GPS disabled."
echo " 🧹  Uninstall: ./install_gpscam.sh --uninstall"
echo " ♻️  Reinstall: ./install_gpscam.sh --reinstall"
echo "===================================="
