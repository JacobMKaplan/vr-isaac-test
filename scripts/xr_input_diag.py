# Diagnostic, run inside Isaac Sim via run-demo.sh --diag.
# Once XR is running and a controller shows up, logs the active VR tool layout / action map
# and the controllers Kit sees, then logs every button/trigger/stick change it receives.
# Everything is prefixed "[xr-diag]" and also written to logs/xr-diag.log.
import asyncio
import os
import time

import carb
import omni.kit.app

_DIAG_LOG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs", "xr-diag.log")
os.makedirs(os.path.dirname(_DIAG_LOG_PATH), exist_ok=True)
_diag_fh = open(_DIAG_LOG_PATH, "w", buffering=1)


def _diag_log(msg):
    carb.log_warn(f"[xr-diag] {msg}")
    _diag_fh.write(f"{time.strftime('%H:%M:%S')} {msg}\n")


def _diag_safe(fn, default="?"):
    try:
        return fn()
    except Exception as exc:  # diagnostics only: never break the app
        return f"<{type(exc).__name__}: {exc}>" if default == "?" else default


async def _diag_main():
    from omni.kit.xr.core import XRCore, XRSettings

    app = omni.kit.app.get_app()
    core = XRCore.get_singleton()
    settings = XRSettings.get_singleton()

    _diag_log("waiting for XR and controllers...")
    while True:
        await app.next_update_async()
        if core.is_xr_enabled() and any(
            "hand" in str(d.get_name()) for d in _diag_safe(core.get_all_input_devices, [])
        ):
            break
    for _ in range(60):
        await app.next_update_async()

    _diag_log(f"profile={_diag_safe(core.get_current_profile_name)}")
    for key in (
        "profile/persistent/tools/layout",
        "profile/persistent/enableNavigationControls",
        "profile/persistent/tooltips/visible",
        "profile/persistent/tools/dominantHand",
        "profile/persistent/anchorMode",
    ):
        _diag_log(f"setting {key} = {_diag_safe(lambda: settings.get_setting(key))!r}")

    amap = _diag_safe(core.get_action_map, None)
    if amap is None:
        _diag_log("action map: NONE (no VR tool layout active)")
    else:
        _diag_log(f"action map: name={_diag_safe(amap.get_name)} layout={_diag_safe(amap.get_tool_layout)} "
             f"hand={_diag_safe(amap.get_dominant_hand)} tags={_diag_safe(amap.get_input_device_tags)}")
        for rec in _diag_safe(amap.get_action_map, ()) or ():
            _diag_log(f"  action: {rec}")

    devices = _diag_safe(core.get_all_input_devices, [])
    watch = []
    for dev in devices:
        name = str(dev.get_name())
        model = _diag_safe(dev.get_model, None)
        _diag_log(f"device {name} type={_diag_safe(dev.get_type)} model={_diag_safe(model.get_name) if model else None}")
        for inp in _diag_safe(dev.get_input_names, []) or []:
            gestures = [str(g) for g in (_diag_safe(lambda: dev.get_input_gesture_names(inp), []) or [])]
            has_gen = _diag_safe(lambda: dev.has_event_generator(inp))
            tips = _diag_safe(lambda: dev.get_input_tooltips(inp), {})
            _diag_log(f"  input {inp}: gestures={gestures} event_generator={has_gen} tooltips={tips}")
            for g in gestures:
                watch.append((dev, name, str(inp), g))

    _diag_log(f"watching {len(watch)} inputs - press buttons, pull triggers, move sticks")
    last = {}
    while True:
        await app.next_update_async()
        for dev, name, inp, g in watch:
            v = _diag_safe(lambda: dev.get_input_gesture_value(inp, g), None)
            if not isinstance(v, float):
                continue
            prev = last.get((name, inp, g), 0.0)
            # log digital transitions and big analog moves only
            if (prev < 0.5) != (v < 0.5) or abs(v - prev) > 0.6:
                _diag_log(f"{name} {inp}.{g} = {v:.2f}")
                last[(name, inp, g)] = v


asyncio.ensure_future(_diag_main())
