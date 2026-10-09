# Shared settings for setup.sh and run-demo.sh (sourced, not run).
# Override any of these by exporting it before running either script.

# Isaac Sim install
ISAAC_DIR="${ISAAC_DIR:-/opt/isaac-sim}"

# Hotspot the Quest joins (USB Wi-Fi adapter, 5 GHz, laptop at HOST_IP)
HOTSPOT_IF="${HOTSPOT_IF:-wlx78205150434a}"
HOTSPOT_CON="${HOTSPOT_CON:-quest-hotspot}"
HOTSPOT_SSID="${HOTSPOT_SSID:-IsaacVR}"
HOTSPOT_CHANNEL="${HOTSPOT_CHANNEL:-36}"
HOTSPOT_SUBNET="${HOTSPOT_SUBNET:-10.42.0.0/24}"
HOST_IP="${HOST_IP:-10.42.0.1}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

# Isaac Teleop / CloudXR. Must match the isaacteleop bundled with Isaac Sim 6.1.
TELEOP_VER="${TELEOP_VER:-1.3.131}"
CLIENT_URL="${CLIENT_URL:-https://nvidia.github.io/IsaacCapture/client/v${TELEOP_VER}}"
STATIC_DIR="${STATIC_DIR:-$HOME/.cloudxr/static-client}"

# Ports the Quest's browser client uses (WebRTC media, signalling, HTTPS/WSS proxy)
CLOUDXR_UDP_PORTS="47998"
CLOUDXR_TCP_PORTS="49100,48322"
