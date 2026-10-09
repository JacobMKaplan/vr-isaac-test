#!/bin/bash
# Bring up the IsaacVR 5 GHz hotspot for the Quest 3.
# The kernel's Wi-Fi country can fall back to "00" (world), which blocks 5 GHz AP mode,
# so set it to US every time before activating the hotspot.
set -e
sudo iw reg set US
sleep 1
nmcli con up quest-hotspot
nmcli -f GENERAL.STATE,IP4.ADDRESS dev show wlx78205150434a
