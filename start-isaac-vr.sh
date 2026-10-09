#!/bin/bash
# Launch Isaac Sim 6.1 in VR mode, pointed at the CloudXR OpenXR runtime.
# Run start-cloudxr.sh first (in another terminal) so ~/.cloudxr/run/cloudxr.env exists.
set -e
if [ ! -f ~/.cloudxr/run/cloudxr.env ]; then
    echo "CloudXR env not found — start ~/vr-test/start-cloudxr.sh first." >&2
    exit 1
fi
source ~/.cloudxr/run/cloudxr.env
echo "OpenXR runtime: $XR_RUNTIME_JSON"
exec /opt/isaac-sim/isaac-sim.xr.vr.sh "$@"
