# Quest 3 → Isaac Sim 6.1 VR demo

This project streams an Isaac Sim 6.1 scene to a Meta Quest 3 over a private Wi-Fi hotspot, using NVIDIA CloudXR. The Quest needs no app: it connects through Quest Browser, which supports WebXR.

```
Isaac Sim 6.1 (VR app, RTX GPU)
   │ OpenXR
CloudXR runtime + WSS proxy  (.venv-cloudxr, isaacteleop 1.3.131)
   │ WebRTC video / input over the hotspot (10.42.0.1)
Quest 3 → Quest Browser → CloudXR web client (served by the laptop at :48322/client/)
```

## Requirements

- Ubuntu 24.04, an NVIDIA RTX GPU and a working driver (`nvidia-smi` should work)
- Isaac Sim 6.1 at `/opt/isaac-sim`, or `export ISAAC_DIR=...`
- A USB Wi-Fi adapter that can host a 5 GHz hotspot. The default is `wlx78205150434a`; set yours in `config.sh`.
- Internet on the laptop's other connection. Scenes stream their assets from NVIDIA's asset server.
- A Meta Quest 3 (OS v79 or newer)

## First-time setup

```bash
./setup.sh           # check and fix everything (asks for sudo, and for a hotspot password if it creates the hotspot)
./setup.sh --check   # report only
```

`setup.sh` sets up everything outside this folder that the demo needs. It's safe to re-run: each step checks first and only changes what's missing.

| Step | What it does |
|---|---|
| Packages | Installs `iw`, `curl`, `python3-venv`, `libvulkan1`, `libbsd0` and `network-manager` |
| Wi-Fi country | Writes `/etc/modprobe.d/cfg80211.conf`. Without a country set, Linux won't host a hotspot on 5 GHz |
| Hotspot | Creates the NetworkManager profile `quest-hotspot`: SSID `IsaacVR`, 5 GHz channel 36, laptop at `10.42.0.1` |
| Firewall | If ufw is active: opens the CloudXR ports to the hotspot subnet and lets hotspot traffic out to the internet |
| CloudXR | Creates `.venv-cloudxr` with `isaacteleop[cloudxr]==1.3.131` |
| Web client | Downloads and patches the client into `~/.cloudxr/static-client` |

It also checks, but can't fix, the Isaac Sim install, the NVIDIA driver and the Wi-Fi adapter.

**On the Quest, once:**
1. Join the **IsaacVR** Wi-Fi network.
2. In Quest Browser, open `https://10.42.0.1:48322/` and accept the certificate warning (**Advanced → Proceed**).
3. Bookmark `https://10.42.0.1:48322/client/?serverIP=10.42.0.1&port=48322&immersiveMode=vr`

## Running

```bash
./run-demo.sh                    # default scene (demo)
./run-demo.sh --scene warehouse  # pick a scene
./run-demo.sh --list-scenes
```

The launcher:
1. Checks the GPU.
2. Starts the hotspot.
3. Prepares the web client.
4. Starts CloudXR in the background.
5. Launches Isaac Sim in VR mode, opens the scene and starts XR by itself. The terminal then says `[run-demo] XR started`.

Then, on the Quest: join IsaacVR, open the bookmark and tap **CONNECT**.

To stop, close Isaac Sim or press Ctrl+C. CloudXR stops with it; the hotspot stays up.

| Option | Meaning |
|---|---|
| `--scene NAME` | Load `scenes/NAME.usda`. Default: `demo` |
| `--stage PATH_OR_URL` | Load any USD file or URL instead |
| `--empty` | Start with no scene |
| `--list-scenes` | List the scenes and their descriptions |
| `--no-hotspot` | Skip the hotspot, for example when using a router. Set `HOST_IP` to the laptop's address on it |
| `--no-auto-xr` | Don't start XR automatically. Note: this also skips opening the scene |
| `--diag` | Log every controller input Isaac Sim receives to `logs/xr-diag.log` |
| `-- ARGS` | Pass extra arguments to Isaac Sim |

## Scenes

| Scene | What's in it |
|---|---|
| `demo` | NVIDIA's Simple Room with a Franka arm on the table. Static |
| `warehouse` | Simple warehouse. A Franka on a pedestal loops through an 8 s motion, and a workbench holds 8 physics boxes you can grab and throw. The simulation starts by itself |

## Controls (Quest 3 Touch Plus)

| Control | Action |
|---|---|
| Right stick forward / back | Teleport. Push, aim the arc at the floor, release |
| Right stick left / right | Turn |
| Left stick | Fly or glide |
| Trigger | Select with the beam |
| A / X | Show or hide the beam |
| B | Isaac Sim's in-VR menu |
| Grip | **demo:** Kit's grab tool, which moves objects without physics. **warehouse:** physics grab: squeeze near a box to pick it up, release to drop or throw |

Avoid the Meta button while in the scene; it pauses the stream. Press it again to return.

## Adding a scene

1. **Create `scenes/NAME.usda`.** Z-up, metres, everything under `/World`. The first `# ` comment line is the description shown by `--list-scenes`.
2. **Add a camera at `/World/VRStart`, at eye height, facing where you want to look.** XR uses the active camera as your start point: it drops the camera to the floor below it (within 2.5 m) and adds your real head height.
3. **If the scene animates anything, add a time range** (`endTimeCode = 1000000`, `timeCodesPerSecond = 60`). Otherwise the timeline wraps at 0.
4. **Optional: add `scenes/NAME.py`.** It runs inside Isaac Sim when the scene loads. `scripts/vrdemo_physics.py` provides:
   - `run_scene(marker_prim, arm=..., grab_root=...)`: waits for the scene to load, presses Play, then updates the behaviours every frame
   - `LoopingArm`: drives joint targets from functions of time (degrees, or metres for sliding joints)
   - `PhysicsGrab`: grip-to-grab for every rigid body under `grab_root`
5. **If the scene uses `PhysicsGrab`,** put `# vrdemo: physics-grab` on the first line of the `.py`. `run-demo.sh` then enables `exts/vrdemo.xr`, which turns off Kit's own grab tool so the grip button is free.

See `scenes/warehouse.usda` and `scenes/warehouse.py` for a complete example.

## Files

```
run-demo.sh              launcher
setup.sh                 one-time / re-runnable system setup
config.sh                shared settings (interface, SSID, IPs, versions); override via environment
scenes/                  NAME.usda scenes + optional NAME.py behaviours
scripts/xr_autostart.py  inside Isaac Sim: open scene, set VRStart camera, start XR
scripts/vrdemo_physics.py scene behaviours (looping arm, physics grab)
scripts/xr_input_diag.py --diag controller logger
scripts/ensure-web-client.sh  download + patch the CloudXR web client
exts/vrdemo.xr/          Quest action map without Kit's grab tool (physics-grab scenes)
.venv-cloudxr/           CloudXR runtime environment (created by setup.sh)
logs/                    cloudxr-*.log, scene.log, xr-diag.log
start-*.sh               older step-by-step scripts, superseded by run-demo.sh
```

Outside this folder: `~/.cloudxr/` (CloudXR runtime files, certificate, web client), the `quest-hotspot` NetworkManager profile, `/etc/modprobe.d/cfg80211.conf`, the ufw rules, and Isaac Sim's saved XR settings (`~/.local/share/ov/data/Kit/Isaac-Sim XR VR/6.1/`).

## Troubleshooting

These are the problems hit while building this setup, and their fixes.

| Symptom | Cause / fix |
|---|---|
| `NVIDIA driver is not loaded`, or CloudXR fails with `cudaErrorNoDevice` | A kernel update arrived without matching NVIDIA modules. Run `sudo apt install linux-modules-nvidia-580-open-generic-hwe-24.04 nvidia-driver-580-open` and reboot. Check `nvidia-smi` after every kernel update |
| Hotspot fails: `802.1X supplicant took too long` | The Wi-Fi country is unset, so 5 GHz hosting is blocked. `run-demo.sh` sets it automatically; by hand: `sudo iw reg set US` |
| Hotspot drops mid-session | The small USB adapter can be flaky. Re-run `./run-demo.sh` (it reuses CloudXR), or `nmcli con up quest-hotspot`. A Wi-Fi 6 router (with `--no-hotspot`) is more reliable |
| Quest can't load `https://10.42.0.1:48322/` | The Quest isn't on IsaacVR; it tends to switch back to networks with internet. Rejoin IsaacVR and turn off auto-connect on other networks |
| Client page is blank, the dropdown is empty, CONNECT is grey | The page's script didn't load. Run `scripts/ensure-web-client.sh` (it re-applies the `<base href="/client/">` patch), then reload the page |
| CloudXR fails with `libPoco.so: ELF load command address/offset not page-aligned` | Isaac Sim 6.1's bundled isaacteleop library is broken. The launcher uses `.venv-cloudxr` instead; run `./setup.sh` if that environment is missing |
| Client download fails with 404 | NVIDIA moved the client from IsaacTeleop to IsaacCapture. `config.sh` → `CLIENT_URL` |
| Controllers are visible but buttons do nothing | Kit's XR tools aren't loaded. The launcher passes `--enable omni.kit.xr.ui.stage`. Use `--diag` to see what Isaac Sim receives |
| Grabbing boxes does nothing in `warehouse` | Check `logs/scene.log`. It records hand positions every 5 s, plus each grab and release |

## Not set up yet

- **Opening the client on the Quest automatically.** This would need Quest Developer Mode, adb, and the launcher's `--setup-oob` option. With `--host-client`, also set `TELEOP_WEB_CLIENT_BASE=https://10.42.0.1:48322/client/`, because the launcher otherwise guesses the wrong IP.
- **Isaac Teleop robot control.** In the Tools → Replicator → Teleop panel, click Connect *before* starting XR, because of a 6.1 bug.
