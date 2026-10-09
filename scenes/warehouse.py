# vrdemo: physics-grab
# Behaviour for scenes/warehouse.usda, run inside Isaac Sim by run-demo.sh (--exec).
# Presses Play, loops the Franka through a smooth 8 s motion, and lets you grab the boxes with the grip.
import asyncio
import math
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("DEMO_DIR", os.path.expanduser("~/vr-test")), "scripts"))
import vrdemo_physics  # noqa: E402

_W = 2.0 * math.pi / 8.0  # one full loop every 8 seconds

# Joint targets in degrees (fingers in metres), all well inside the Franka's limits:
# j1 sweeps side to side, j2/j4/j6 dip and rise twice per loop, j7 twists the hand, fingers open/close.
_FRANKA_LOOP = {
    "panda_joint1": lambda t: 60.0 * math.sin(_W * t),
    "panda_joint2": lambda t: -20.0 + 20.0 * math.sin(2 * _W * t),
    "panda_joint3": lambda t: 0.0,
    "panda_joint4": lambda t: -120.0 + 30.0 * math.sin(2 * _W * t + math.pi / 2),
    "panda_joint5": lambda t: 0.0,
    "panda_joint6": lambda t: 100.0 + 25.0 * math.sin(2 * _W * t),
    "panda_joint7": lambda t: 45.0 + 60.0 * math.sin(_W * t),
    "panda_finger_joint1": lambda t: 0.02 + 0.02 * math.sin(4 * _W * t),
}

asyncio.ensure_future(
    vrdemo_physics.run_scene(
        marker_prim="/World/Boxes",
        arm=("/World/Robot", _FRANKA_LOOP),
        grab_root="/World/Boxes",
    )
)
