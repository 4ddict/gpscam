----------------------
GPSCAM 0.1 - BY ADDICT
----------------------
GPS enabled camera for Raspberry PI

Still in early development, expect bugs

Goal: 
- Get a live camera feed with GPS information overlayed. 
- Use the GPS data in Home-assistant via MQTT

# What you need
- A pi camera (tested with a OV5647)
- A gps module (tested with NEO-8M)

# Easy install on raspberry PI
curl -fsSL https://raw.githubusercontent.com/4ddict/gpscam/main/install_gpscam.sh -o install_gpscam.sh && chmod +x install_gpscam.sh && ./install_gpscam.sh

# Manual install
1. Copy install_gpscam.sh
2. sudo chmod +x install_gpscam.sh
3. bash /install_gpscam.sh
4. Choose username (usually pi)
5. Wait

  
Webpage: http://YOURIP:8080

# Fresh install
./gpscam.sh
# Clean reinstall
./gpscam.sh --reinstall
# Full uninstall
./gpscam.sh --uninstall

Tested on Pi ZeroW 2 with Raspbian Lite 6.12 (bookworm)
