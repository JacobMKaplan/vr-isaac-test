"""Scene behaviours for the Quest 3 VR demo, imported by scenes/<name>.py inside Isaac Sim.

LoopingArm   - drives a robot arm's joint targets around a smooth looped trajectory.
PhysicsGrab  - grip near a rigid body to pick it up; release to drop or throw it.
run_scene()  - waits for the stage, presses Play and runs the behaviours every frame.

The grab steers the body with velocities (it stays a normal dynamic body), so held
objects still collide and a release keeps the hand's velocity, which is what throws it.
Kit's own XR grab tool is a plain transform link that fights PhysX, so run-demo.sh swaps
in the vrdemo.xr action map (grip unbound) for scenes that use this.
"""

import asyncio
import math
import os
import time

import carb
import omni.kit.app
import omni.timeline
import omni.usd
from pxr import Gf, Usd, UsdPhysics

# Seconds the simulation has been playing since run_scene() started (read by tests / scenes)
scene_time = 0.0

_LOG_PATH = os.path.join(os.environ.get("DEMO_DIR", os.path.expanduser("~/vr-test")), "logs", "scene.log")


def log(msg):
    carb.log_warn(f"[scene] {msg}")
    try:
        os.makedirs(os.path.dirname(_LOG_PATH), exist_ok=True)
        with open(_LOG_PATH, "a") as fh:
            fh.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


class LoopingArm:
    """Sets drive targets on named joints from functions of time (degrees / metres)."""

    def __init__(self, stage, root_path, trajectory):
        self._drives = {}
        root = stage.GetPrimAtPath(root_path)
        for prim in Usd.PrimRange(root):
            name = prim.GetName()
            if name not in trajectory:
                continue
            kind = "angular" if prim.IsA(UsdPhysics.RevoluteJoint) else "linear"
            drive = UsdPhysics.DriveAPI.Get(prim, kind)
            if not drive:
                drive = UsdPhysics.DriveAPI.Apply(prim, kind)
            self._drives[name] = drive.GetTargetPositionAttr() or drive.CreateTargetPositionAttr()
        self._trajectory = trajectory
        missing = sorted(set(trajectory) - set(self._drives))
        log(f"arm {root_path}: driving {sorted(self._drives)}" + (f", missing {missing}" if missing else ""))

    def update(self, t):
        for name, attr in self._drives.items():
            attr.Set(float(self._trajectory[name](t)))


def _quat_to_axis_angle(q):
    """Gf.Quatd -> (axis Gf.Vec3d, angle radians), shortest rotation."""
    if q.GetReal() < 0.0:
        q = Gf.Quatd(-q.GetReal(), -q.GetImaginary())
    w = max(-1.0, min(1.0, q.GetReal()))
    angle = 2.0 * math.acos(w)
    s = math.sqrt(max(0.0, 1.0 - w * w))
    if s < 1e-6:
        return Gf.Vec3d(1, 0, 0), 0.0
    return Gf.Vec3d(q.GetImaginary()) / s, angle


class PhysicsGrab:
    """Velocity-tracking grab for dynamic rigid bodies under `bodies_root`.

    hand_provider() -> {hand_name: (Gf.Matrix4d world pose or None, grip 0..1)}
    """

    GRAB_ON = 0.6
    GRAB_OFF = 0.35
    REACH = 0.18  # metres from the hand to the body's surface (approx: centre minus half extent)
    MAX_SPEED = 8.0  # m/s
    MAX_SPIN = 720.0  # deg/s

    def __init__(self, stage, bodies_root, hand_provider):
        from omni.physx import get_physx_interface

        self._physx = get_physx_interface()
        self._hands = hand_provider
        self._held = {}  # hand -> (prim path, offset matrix)
        self._bodies = []
        for prim in Usd.PrimRange(stage.GetPrimAtPath(bodies_root)):
            if prim.HasAPI(UsdPhysics.RigidBodyAPI):
                rb = UsdPhysics.RigidBodyAPI(prim)
                size = prim.GetAttribute("size").Get() or 0.2
                scale = prim.GetAttribute("xformOp:scale").Get() or Gf.Vec3f(1, 1, 1)
                half = 0.5 * float(size) * max(scale)
                self._bodies.append((str(prim.GetPath()), rb.GetVelocityAttr(), rb.GetAngularVelocityAttr(), half))
        log(f"grab: {len(self._bodies)} grabbable bodies under {bodies_root}")
        self._last_report = 0.0

    def _body_pose(self, path):
        r = self._physx.get_rigidbody_transformation(path)
        if not r or not r.get("ret_val", True):
            return None
        p, q = r["position"], r["rotation"]  # rotation is (x, y, z, w)
        m = Gf.Matrix4d(1.0)
        m.SetRotateOnly(Gf.Quatd(q[3], q[0], q[1], q[2]))
        m.SetTranslateOnly(Gf.Vec3d(p[0], p[1], p[2]))
        return m

    def update(self, dt):
        dt = max(dt, 1.0 / 240.0)
        hands = self._hands()
        now = time.monotonic()
        if now - self._last_report > 5.0:
            self._last_report = now
            log("hands: " + ", ".join(
                f"{h} pos={tuple(round(x, 2) for x in m.ExtractTranslation()) if m else None} grip={g:.2f}"
                for h, (m, g) in hands.items()))

        for hand, (hand_m, grip) in hands.items():
            held = self._held.get(hand)
            if held and (hand_m is None or grip < self.GRAB_OFF):
                log(f"{hand} released {held[0]}")
                del self._held[hand]
                continue
            if hand_m is None:
                continue
            if not held and grip > self.GRAB_ON:
                self._try_grab(hand, hand_m)
                held = self._held.get(hand)
            if held:
                self._steer(held, hand_m, dt)

    def _try_grab(self, hand, hand_m):
        taken = {p for p, _ in self._held.values()}
        hand_pos = hand_m.ExtractTranslation()
        best = None
        for path, vel_attr, ang_attr, half in self._bodies:
            if path in taken:
                continue
            body_m = self._body_pose(path)
            if body_m is None:
                continue
            d = (body_m.ExtractTranslation() - hand_pos).GetLength() - half
            if d < self.REACH and (best is None or d < best[0]):
                best = (d, path, body_m)
        if best:
            _, path, body_m = best
            # row-vector convention: world = local * parent, so offset = body * hand^-1
            self._held[hand] = (path, body_m * hand_m.GetInverse())
            log(f"{hand} grabbed {path}")

    def _steer(self, held, hand_m, dt):
        path, offset = held
        body_m = self._body_pose(path)
        if body_m is None:
            return
        target = offset * hand_m
        _, vel_attr, ang_attr, _ = next(b for b in self._bodies if b[0] == path)

        v = (target.ExtractTranslation() - body_m.ExtractTranslation()) / dt
        if v.GetLength() > self.MAX_SPEED:
            v = v.GetNormalized() * self.MAX_SPEED
        vel_attr.Set(Gf.Vec3f(v))

        q_t = target.RemoveScaleShear().ExtractRotationQuat()
        q_b = body_m.RemoveScaleShear().ExtractRotationQuat()
        axis, angle = _quat_to_axis_angle(q_t * q_b.GetInverse())
        w = axis * math.degrees(angle) / dt
        if w.GetLength() > self.MAX_SPIN:
            w = w.GetNormalized() * self.MAX_SPIN
        ang_attr.Set(Gf.Vec3f(w))


def xr_hand_provider():
    """Quest controller grip poses (stage space) and grip-trigger values from Kit XR."""
    from omni.kit.xr.core import XRCore

    core = XRCore.get_singleton()
    out = {}
    for hand in ("/user/hand/left", "/user/hand/right"):
        dev = core.get_input_device(hand) if core.is_xr_enabled() else None
        if dev is None:
            out[hand] = (None, 0.0)
            continue
        try:
            m = Gf.Matrix4d(dev.get_virtual_world_pose())
            g = float(dev.get_input_gesture_value("squeeze", "value"))
        except Exception:
            m, g = None, 0.0
        out[hand] = (m, g)
    return out


async def run_scene(marker_prim, arm=None, grab_root=None, hand_provider=xr_hand_provider, autoplay=True):
    """Wait until `marker_prim` exists (the scene is loaded), press Play, run behaviours every frame.

    arm: (robot root path, {joint name: f(t) -> target}) or None
    """
    app = omni.kit.app.get_app()
    ctx = omni.usd.get_context()
    while True:
        stage = ctx.get_stage()
        if stage is not None and stage.GetPrimAtPath(marker_prim).IsValid():
            break
        await app.next_update_async()
    for _ in range(30):
        await app.next_update_async()
    stage_id = ctx.get_stage_id()

    timeline = omni.timeline.get_timeline_interface()
    if autoplay and not timeline.is_playing():
        timeline.play()
        log("simulation playing")
    for _ in range(5):
        await app.next_update_async()

    looping_arm = LoopingArm(stage, arm[0], arm[1]) if arm else None
    grab = PhysicsGrab(stage, grab_root, hand_provider) if grab_root else None

    global scene_time
    scene_time = 0.0
    last = time.monotonic()
    while ctx.get_stage_id() == stage_id:
        await app.next_update_async()
        now = time.monotonic()
        dt, last = now - last, now
        if not timeline.is_playing():
            continue
        # Own clock: the timeline wraps at the stage's end time, which may be 0
        scene_time += dt
        try:
            if looping_arm:
                looping_arm.update(scene_time)
            if grab:
                grab.update(dt)
        except Exception as exc:  # keep the scene alive; report once per second at most
            log(f"behaviour error: {type(exc).__name__}: {exc}")
            await asyncio.sleep(1.0)
    log("stage changed - scene behaviours stopped")
