#!/bin/bash
# One-time (and re-runnable) setup for the Quest 3 -> Isaac Sim VR demo.
#
# Recreates everything run-demo.sh needs that lives outside this folder:
#   - system packages (iw, curl, python3-venv, Vulkan/BSD libs)
#   - persistent Wi-Fi country (needed to host a 5 GHz hotspot)
#   - the NetworkManager hotspot profile the Quest joins
#   - firewall rules for CloudXR + internet sharing for the hotspot
#   - the CloudXR Python environment (.venv-cloudxr)
#   - the cached, patched CloudXR web client (~/.cloudxr/static-client)
# and checks things it can't fix for you (Isaac Sim install, NVIDIA driver, Wi-Fi adapter).
#
# Every step checks first and only changes what is missing. Names/addresses come from config.sh.
#
# Usage: ./setup.sh            check and fix (asks for sudo when needed)
#        ./setup.sh --check    report only, change nothing
# Env:   HOTSPOT_PASSWORD=...  hotspot password to use if the profile has to be created

set -uo pipefail
DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=config.sh
source "$DIR/config.sh"
VENV="$DIR/.venv-cloudxr"

CHECK_ONLY=0
case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

step() { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m✓\033[0m $*"; }
warn() { echo -e "    \033[33m!\033[0m $*"; }
bad()  { echo -e "    \033[31m✗\033[0m $*"; PROBLEMS=$((PROBLEMS + 1)); }
PROBLEMS=0

# fix "description" command... : runs the command unless --check (then just counts it as a problem)
fix() {
    local what=$1; shift
    if [ "$CHECK_ONLY" = 1 ]; then
        bad "$what (run ./setup.sh to fix)"
        return 1
    fi
    echo "    → $what"
    if "$@"; then ok "done"; else bad "failed: $what"; return 1; fi
}

# 1. Isaac Sim ---------------------------------------------------------------
step "Isaac Sim"
if [ -x "$ISAAC_DIR/isaac-sim.xr.vr.sh" ]; then
    ok "found $ISAAC_DIR ($(cat "$ISAAC_DIR/VERSION" 2>/dev/null | cut -d+ -f1))"
else
    bad "Isaac Sim 6.1 not found at $ISAAC_DIR (install it, or export ISAAC_DIR=/path/to/isaac-sim)"
fi

# 2. Packages ----------------------------------------------------------------
step "System packages"
PKGS=(iw curl python3-venv libvulkan1 libbsd0 network-manager)
MISSING=()
for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
if [ ${#MISSING[@]} -eq 0 ]; then
    ok "${PKGS[*]}"
else
    fix "install ${MISSING[*]}" sudo apt-get install -y "${MISSING[@]}"
fi

# 3. NVIDIA driver -------------------------------------------------------------
step "NVIDIA driver"
if GPU=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null); then
    ok "$GPU"
else
    bad "NVIDIA driver not loaded on kernel $(uname -r). Typical fix on Ubuntu 24.04 HWE kernels:
         sudo apt install linux-modules-nvidia-580-open-generic-hwe-24.04 nvidia-driver-580-open && sudo reboot"
fi

# 4. Wi-Fi adapter -----------------------------------------------------------
step "Hotspot Wi-Fi adapter ($HOTSPOT_IF)"
if ip link show "$HOTSPOT_IF" >/dev/null 2>&1; then
    PROPS=$(nmcli -t -f WIFI-PROPERTIES dev show "$HOTSPOT_IF" 2>/dev/null)
    if grep -q 'WIFI-PROPERTIES.AP:yes' <<<"$PROPS" && grep -q 'WIFI-PROPERTIES.5GHZ:yes' <<<"$PROPS"; then
        ok "present, supports hotspot (AP) mode on 5 GHz"
    else
        bad "$HOTSPOT_IF does not report AP + 5 GHz support"
    fi
else
    bad "$HOTSPOT_IF not found - plug in the USB Wi-Fi adapter, or export HOTSPOT_IF=<interface> (see: nmcli dev)"
fi

# 5. Wi-Fi country -----------------------------------------------------------
step "Wi-Fi country ($WIFI_COUNTRY)"
MODPROBE_CONF=/etc/modprobe.d/cfg80211.conf
WANT="options cfg80211 ieee80211_regdom=$WIFI_COUNTRY"
if grep -qxF "$WANT" "$MODPROBE_CONF" 2>/dev/null; then
    ok "persistent setting in $MODPROBE_CONF"
else
    write_regdom() {
        echo "$WANT" | sudo tee "$MODPROBE_CONF" >/dev/null && sudo update-initramfs -u >/dev/null
    }
    fix "persist Wi-Fi country in $MODPROBE_CONF (takes effect next boot; run-demo.sh also sets it live)" write_regdom
fi

# 6. Hotspot profile ---------------------------------------------------------
step "Hotspot profile '$HOTSPOT_CON'"
if nmcli -t -f NAME con show | grep -qxF "$HOTSPOT_CON"; then
    GOT=$(nmcli -g 802-11-wireless.ssid,802-11-wireless.mode,802-11-wireless.band,connection.interface-name,ipv4.method con show "$HOTSPOT_CON" | tr '\n' ' ')
    ok "exists: $GOT"
    case "$GOT" in
        "$HOTSPOT_SSID ap a $HOTSPOT_IF shared "*) ;;
        *) warn "differs from config.sh (want: $HOTSPOT_SSID ap a $HOTSPOT_IF shared); delete it with 'nmcli con delete $HOTSPOT_CON' and re-run to recreate" ;;
    esac
else
    create_hotspot() {
        local pw="${HOTSPOT_PASSWORD:-}"
        while [ ${#pw} -lt 8 ]; do
            read -r -s -p "    Hotspot password for $HOTSPOT_SSID (8+ characters): " pw; echo
        done
        nmcli con add type wifi ifname "$HOTSPOT_IF" con-name "$HOTSPOT_CON" autoconnect no ssid "$HOTSPOT_SSID" \
            802-11-wireless.mode ap 802-11-wireless.band a 802-11-wireless.channel "$HOTSPOT_CHANNEL" \
            ipv4.method shared ipv4.addresses "$HOST_IP/24" ipv6.method disabled \
            wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
            wifi-sec.psk "$pw" >/dev/null
    }
    fix "create hotspot profile (SSID $HOTSPOT_SSID, 5 GHz ch $HOTSPOT_CHANNEL, $HOST_IP)" create_hotspot
fi

# 7. Firewall ----------------------------------------------------------------
step "Firewall (ufw)"
if ! systemctl is-active --quiet ufw; then
    ok "ufw is not active - nothing to open"
else
    UPLINK=$(ip route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}' | grep -vx "$HOTSPOT_IF" | head -1)
    if UFW=$(sudo -n ufw status verbose 2>/dev/null); then
        # ufw prints multi-port rules with the ports sorted, e.g. "48322,49100/tcp"
        TCP_SORTED=$(tr ',' '\n' <<<"$CLOUDXR_TCP_PORTS" | sort -n | paste -sd,)
        SUBNET_RE=${HOTSPOT_SUBNET//./\\.}
        need=0
        grep -qE "^${CLOUDXR_UDP_PORTS}/udp +ALLOW IN +${SUBNET_RE}" <<<"$UFW" || need=1
        grep -qE "^${TCP_SORTED}/tcp +ALLOW IN +${SUBNET_RE}" <<<"$UFW" || need=1
        [ -z "$UPLINK" ] || grep -qE "on $UPLINK +ALLOW FWD +Anywhere on $HOTSPOT_IF" <<<"$UFW" || need=1
        [ "$need" = 0 ] && ok "CloudXR ports open to $HOTSPOT_SUBNET; hotspot routed out via ${UPLINK:-?}"
    elif [ "$CHECK_ONLY" = 1 ]; then
        need=0
        warn "can't read ufw rules without sudo - unknown (./setup.sh re-applies them; existing rules are skipped)"
    else
        need=1
    fi
    if [ "$need" = 1 ]; then
        open_ports() {
            sudo ufw allow from "$HOTSPOT_SUBNET" to any port "$CLOUDXR_UDP_PORTS" proto udp >/dev/null &&
            sudo ufw allow from "$HOTSPOT_SUBNET" to any port "$CLOUDXR_TCP_PORTS" proto tcp >/dev/null &&
            if [ -n "$UPLINK" ]; then sudo ufw route allow in on "$HOTSPOT_IF" out on "$UPLINK" >/dev/null; fi
        }
        fix "allow CloudXR ports from $HOTSPOT_SUBNET and route hotspot traffic out via ${UPLINK:-<no uplink found>}" open_ports
    fi
fi

# 8. CloudXR Python environment --------------------------------------------
step "CloudXR runtime environment (.venv-cloudxr)"
# Isaac Sim 6.1's bundled isaacteleop ships a libPoco.so that fails to load
# ("ELF load command address/offset not page-aligned"), so CloudXR runs from this venv instead.
HAVE=$("$VENV/bin/python" -I -c "import importlib.metadata as m; print(m.version('isaacteleop'))" 2>/dev/null || true)
if [ "$HAVE" = "$TELEOP_VER" ]; then
    ok "isaacteleop $HAVE"
else
    make_venv() {
        [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV" || return 1
        "$VENV/bin/pip" install -q --upgrade pip &&
        "$VENV/bin/pip" install -q "isaacteleop[cloudxr]==$TELEOP_VER"
    }
    fix "install isaacteleop[cloudxr]==$TELEOP_VER into .venv-cloudxr${HAVE:+ (found $HAVE)}" make_venv
fi

# 9. Web client --------------------------------------------------------------
step "CloudXR web client ($STATIC_DIR)"
if [ -s "$STATIC_DIR/index.html" ] && [ -s "$STATIC_DIR/bundle.js" ] && grep -q '<base href="/client/">' "$STATIC_DIR/index.html"; then
    ok "cached and patched"
else
    fix "download v$TELEOP_VER and patch it" "$DIR/scripts/ensure-web-client.sh"
fi

# Summary --------------------------------------------------------------------
echo
if [ "$PROBLEMS" = 0 ]; then
    echo -e "\033[1;32mAll set.\033[0m Start the demo with:  ./run-demo.sh   (scenes: ./run-demo.sh --list-scenes)"
    echo "On the Quest: join $HOTSPOT_SSID, then bookmark"
    echo "  https://$HOST_IP:48322/client/?serverIP=$HOST_IP&port=48322&immersiveMode=vr"
    echo "(first visit: open https://$HOST_IP:48322/ once and accept the certificate warning)"
else
    echo -e "\033[1;31m$PROBLEMS problem(s)\033[0m - see ✗ above."
    exit 1
fi
