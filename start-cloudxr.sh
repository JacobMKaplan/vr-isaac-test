#!/bin/bash
# Start the CloudXR runtime + WSS proxy + local web client for the Quest 3 over the IsaacVR hotspot.
# Uses the PyPI isaacteleop 1.3.131 in .venv-cloudxr because Isaac Sim 6.1's bundled libPoco.so
# has a misaligned ELF load segment and fails to load.
DIR=$(dirname "$(readlink -f "$0")")
export TELEOP_PROXY_HOST=10.42.0.1
export TELEOP_STREAM_SERVER_IP=10.42.0.1
exec "$DIR/.venv-cloudxr/bin/python" -m isaacteleop.cloudxr --accept-eula --host-client "$@"
