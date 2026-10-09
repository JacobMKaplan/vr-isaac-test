# Runs inside Isaac Sim (passed via --exec by run-demo.sh).
# Optionally opens a USD stage, then turns on the "vr" XR profile so the app
# goes straight to "Waiting for connection" without clicking Start XR.
import asyncio
import os

import carb
import omni.kit.app
import omni.usd

_DEMO_STAGE = os.environ.get("DEMO_STAGE", "").strip()
_DEMO_START_CAMERA = "/World/VRStart"
_DEMO_SETTLE_FRAMES = 120


def _demo_log(msg):
    # carb.log_warn so it shows up in the terminal at the default log level
    carb.log_warn(f"[run-demo] {msg}")


async def _demo_main():
    app = omni.kit.app.get_app()
    for _ in range(_DEMO_SETTLE_FRAMES):
        await app.next_update_async()

    if _DEMO_STAGE:
        _demo_log(f"opening stage {_DEMO_STAGE}")
        ok, err = await omni.usd.get_context().open_stage_async(_DEMO_STAGE)
        if not ok:
            _demo_log(f"could not open stage: {err}")
        for _ in range(_DEMO_SETTLE_FRAMES):
            await app.next_update_async()

    # XR anchors the headset to the active viewport camera, so start from the scene's VR camera
    stage = omni.usd.get_context().get_stage()
    if stage is not None and stage.GetPrimAtPath(_DEMO_START_CAMERA).IsValid():
        from omni.kit.viewport.utility import get_active_viewport

        viewport = get_active_viewport()
        if viewport is not None:
            viewport.camera_path = _DEMO_START_CAMERA
            _demo_log(f"active camera set to {_DEMO_START_CAMERA}")
            for _ in range(10):
                await app.next_update_async()

    from omni.kit.xr.core import XRCore

    _demo_log("starting XR (vr profile)")
    XRCore.request_enable_profile("vr")
    for _ in range(1200):
        await app.next_update_async()
        if XRCore.get_singleton().is_xr_enabled():
            _demo_log("XR started - waiting for the Quest to connect")
            return
    _demo_log("XR did not report enabled yet - check the XR panel and click Start XR if needed")


asyncio.ensure_future(_demo_main())
