#!/bin/bash
# Quest 3 -> Isaac Sim 6.1 VR demo: one-shot launcher.
#
#   1. checks the NVIDIA driver is loaded
#   2. brings up the 5 GHz hotspot for the Quest (names and addresses: config.sh)
#   3. makes sure the CloudXR web client is cached and patched
#   4. starts the CloudXR runtime + WSS proxy in the background
#   5. launches Isaac Sim in VR mode and starts XR automatically
#
# Ctrl+C (or closing Isaac Sim) stops CloudXR too. The hotspot is left up.
#
# Usage: ./run-demo.sh [--scene NAME | --stage USD_PATH_OR_URL | --empty] [--list-scenes]
#                     [--no-hotspot] [--no-auto-xr] [--diag] [-- extra Isaac Sim args]
#   --scene NAME   load scenes/NAME.usda (default: demo). Run --list-scenes to see them.
#                  If scenes/NAME.py exists it runs inside Isaac Sim as the scene's behaviour.

set -uo pipefail

DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=config.sh
source "$DIR/config.sh"
CLOUDXR_PY="$DIR/.venv-cloudxr/bin/python"
ISAAC="$ISAAC_DIR/isaac-sim.xr.vr.sh"
LOG_DIR="$DIR/logs"

SCENES_DIR="$DIR/scenes"
SCENE_NAME=demo
LIST_SCENES=0
STAGE=""
USE_HOTSPOT=1
AUTO_XR=1
DIAG=0
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --scene) SCENE_NAME="${2:?--scene needs a name (see --list-scenes)}"; shift 2 ;;
        --list-scenes) LIST_SCENES=1; shift ;;
        --stage) STAGE="${2:?--stage needs a path or URL}"; shift 2 ;;
        --empty) SCENE_NAME=""; STAGE=""; shift ;;
        --no-hotspot) USE_HOTSPOT=0; shift ;;
        --no-auto-xr) AUTO_XR=0; shift ;;
        --diag) DIAG=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        --) shift; EXTRA_ARGS=("$@"); break ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

list_scenes() {
    echo "Scenes in $SCENES_DIR:"
    for f in "$SCENES_DIR"/*.usd "$SCENES_DIR"/*.usda; do
        [ -e "$f" ] || continue
        n=$(basename "${f%.*}")
        # first comment line in the scene file is its description
        d=$(grep -m1 -E '^# ' "$f" | sed 's/^# //')
        extra=""; [ -f "$SCENES_DIR/$n.py" ] && extra=" [behaviour: $n.py]"
        printf "  %-12s %s%s\n" "$n" "$d" "$extra"
    done
}
if [ "$LIST_SCENES" = 1 ]; then list_scenes; exit 0; fi
if [ -z "$STAGE" ] && [ -n "$SCENE_NAME" ]; then
    for ext in usda usd; do
        [ -f "$SCENES_DIR/$SCENE_NAME.$ext" ] && STAGE="$SCENES_DIR/$SCENE_NAME.$ext" && break
    done
    if [ -z "$STAGE" ]; then
        echo "Unknown scene: $SCENE_NAME" >&2; list_scenes >&2; exit 2
    fi
fi
# Optional behaviour script next to the stage file (same name, .py)
SCENE_SCRIPT=""
case "$STAGE" in *.usd|*.usda) [ -f "${STAGE%.*}.py" ] && SCENE_SCRIPT="${STAGE%.*}.py" ;; esac

step() { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m✓\033[0m $*"; }
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*" >&2; exit 1; }
port_listening() { ss -lnt "( sport = :$1 )" 2>/dev/null | grep -q LISTEN; }

CLOUDXR_PID=""
cleanup() {
    if [ -n "$CLOUDXR_PID" ] && kill -0 "$CLOUDXR_PID" 2>/dev/null; then
        step "Stopping CloudXR"
        kill -INT -- "-$CLOUDXR_PID" 2>/dev/null
        for _ in $(seq 20); do kill -0 "$CLOUDXR_PID" 2>/dev/null || break; sleep 0.5; done
        kill -TERM -- "-$CLOUDXR_PID" 2>/dev/null
        ok "CloudXR stopped"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$LOG_DIR"

# 1. GPU -------------------------------------------------------------------
step "Checking NVIDIA driver"
if ! GPU=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null); then
    die "NVIDIA driver is not loaded on kernel $(uname -r).
       Fix: sudo apt install linux-modules-nvidia-580-open-generic-hwe-24.04 nvidia-driver-580-open && sudo reboot"
fi
ok "$GPU"

# 2. Hotspot ---------------------------------------------------------------
if [ "$USE_HOTSPOT" = 1 ]; then
    step "Bringing up the $HOTSPOT_SSID hotspot"
    if ! iw reg get 2>/dev/null | sed -n '/^global/,/^$/p' | grep -q "country $WIFI_COUNTRY"; then
        echo "    Setting Wi-Fi country to $WIFI_COUNTRY (needed for 5 GHz hotspot) - sudo may ask for your password"
        sudo iw reg set "$WIFI_COUNTRY" || die "could not set the Wi-Fi country"
        sleep 1
    fi
    if ! nmcli -t -f GENERAL.STATE dev show "$HOTSPOT_IF" 2>/dev/null | grep -q '^GENERAL.STATE:100'; then
        nmcli con up "$HOTSPOT_CON" >/dev/null || die "hotspot failed to start (USB Wi-Fi adapter plugged in? profile created by ./setup.sh?)"
    fi
    nmcli -t -f IP4.ADDRESS dev show "$HOTSPOT_IF" | grep -q "$HOST_IP/" || die "hotspot is up but does not have $HOST_IP"
    ok "$HOTSPOT_SSID is up at $HOST_IP"
fi

# 3. Web client ------------------------------------------------------------
step "Checking the CloudXR web client"
"$DIR/scripts/ensure-web-client.sh" || die "could not prepare the web client (see above)"
ok "web client ready"

# 4. CloudXR ---------------------------------------------------------------
step "Starting the CloudXR runtime"
[ -x "$CLOUDXR_PY" ] || die "missing $CLOUDXR_PY - run ./setup.sh first"
if port_listening 48322 && port_listening 49100; then
    ok "CloudXR is already running - reusing it"
else
    CLOUDXR_LOG="$LOG_DIR/cloudxr-$(date +%Y%m%d-%H%M%S).log"
    TELEOP_PROXY_HOST=$HOST_IP TELEOP_STREAM_SERVER_IP=$HOST_IP \
        setsid "$CLOUDXR_PY" -m isaacteleop.cloudxr --accept-eula --host-client >"$CLOUDXR_LOG" 2>&1 &
    CLOUDXR_PID=$!
    for _ in $(seq 90); do
        port_listening 48322 && port_listening 49100 && break
        kill -0 "$CLOUDXR_PID" 2>/dev/null || break
        sleep 1
    done
    if ! kill -0 "$CLOUDXR_PID" 2>/dev/null || ! port_listening 48322 || ! port_listening 49100; then
        tail -25 "$CLOUDXR_LOG" >&2
        die "CloudXR did not start (full log: $CLOUDXR_LOG, runtime log: ~/.cloudxr/logs/)"
    fi
    ok "CloudXR running (log: $CLOUDXR_LOG)"
fi
[ -f "$HOME/.cloudxr/run/cloudxr.env" ] || die "~/.cloudxr/run/cloudxr.env was not created"
# shellcheck disable=SC1091
source "$HOME/.cloudxr/run/cloudxr.env"
ok "OpenXR runtime: $XR_RUNTIME_JSON"

# 5. Isaac Sim -------------------------------------------------------------
step "Launching Isaac Sim (VR)"
ISAAC_ARGS=(
    "--/persistent/xr/system/display=OpenXR"
    "--/persistent/xr/system/openxr/runtime=system"
    "--/persistent/xr/activeProfile=vr"
    # The 6.1 VR app omits Kit's XR stage tools (teleport, navigation, grab, menu),
    # so controller buttons arrive but nothing acts on them. Enable them explicitly.
    --enable omni.kit.xr.ui.stage
)
if [ "$AUTO_XR" = 1 ]; then
    ISAAC_ARGS+=(--exec "$DIR/scripts/xr_autostart.py")
fi
if [ "$DIAG" = 1 ]; then
    ISAAC_ARGS+=(--exec "$DIR/scripts/xr_input_diag.py")
    echo "    Controller diagnostics on: see $LOG_DIR/xr-diag.log"
fi
if [ -n "$SCENE_SCRIPT" ]; then
    ISAAC_ARGS+=(--exec "$SCENE_SCRIPT")
    echo "    Scene behaviour: $(basename "$SCENE_SCRIPT") (log: $LOG_DIR/scene.log)"
    if grep -q '^# vrdemo: physics-grab' "$SCENE_SCRIPT"; then
        # Swap Kit's transform-only grab for our physics grab: action map without the grab tool
        ISAAC_ARGS+=(--ext-folder "$DIR/exts" --enable vrdemo.xr)
        echo "    Grip button: physics grab (Kit's built-in grab tool disabled for this scene)"
    fi
fi
export DEMO_STAGE="$STAGE"
export DEMO_DIR="$DIR"

cat <<EOF

  ── On the Quest 3 ──────────────────────────────────────────────
   1. Wi-Fi → join $HOTSPOT_SSID
   2. Quest Browser → your bookmark, or
      https://$HOST_IP:48322/client/?serverIP=$HOST_IP&port=48322&immersiveMode=vr
   3. Wait for "...for Simulation" and a green CONNECT, then tap CONNECT

   Isaac Sim takes a minute or two to load. Connect once the terminal
   says "[run-demo] XR started" (or the XR panel shows
   "Waiting for connection").
  ────────────────────────────────────────────────────────────────

EOF

"$ISAAC" "${ISAAC_ARGS[@]}" "${EXTRA_ARGS[@]}"
