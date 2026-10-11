# VR in the guest: OpenVR runtime and Proton submit path (experimental, M2/M3)

**Status: experimental.** The guest side is built and tested without a headset (fake host, test app, wmtr loopback).
It has not run with a game, with Proton's rebuilt `vrclient_x64.dll`, or against a live `steamac-vrhost` yet.

## How a frame gets out

```
VRChat (x86-64 Windows, under FEX)
  openvr_api.dll → Proton vrclient_x64.dll (PE)             guest/proton-vrclient/patches
      Submit(D3D11 texture): QueryInterface(IMTLD3D11ExportableTexture) → GetMetalTexture
      → Texture_t{ &svr_metal_texture, TextureType_Metal }
  → Proton unix side → <PROTON_VR_RUNTIME>/bin/linux64/vrclient.so   guest/vr (this runtime)
      both eyes → WMTVRSubmitInfo → winemetal unix call 146 (WMTVRSubmit) on the game's own wmtr context
      WaitGetPoses / poses / input / haptics → wmtr_vr_call (WMTR_CTL_VR_QUERY), same context
  → wmtr executor in steamac-vm: exporter (copy into IOSurface swapchain, VRL_SUBMIT) and the cached
    VRL_STATE/TIMING/POSES/INPUT the queries are answered from; haptics → VRL_HAPTICS
  → steamac-vrhost (GPL-3, separate process) → headset
```

* **Textures never leave the wmtr context they were created in.** DXMT's texture handles only mean something in the
  game process's wmtr context, so the runtime finds the already loaded `winemetal.so` (the wmtr client) in its own
  process and calls it directly; it opens no second connection.
* **The executor never waits for VR.** Queries are answered from the newest copy of what `steamac-vrhost` sent;
  `WaitGetPoses` sleeps in the guest until the pacer's wake-up time (converted from the host clock with the offset
  measured on each reply). With no headset connected the queries still return a 90 Hz cadence, so a game does not hang.
* **Poses** are predicted by the host to the frame's display time and extrapolated in the guest (linear and angular
  velocity) for any other time the game asks for (`GetDeviceToAbsoluteTrackingPose`, `GetPoseActionDataRelativeToNow`).
  The per-eye poses sent with a frame are the head pose the game rendered with, offset by half the IPD each.

## Why our own OpenVR runtime and not xrizer on an OpenXR runtime

Both were checked by building them. xrizer (`a1216c7`, GPL-3) builds for x86-64 Linux and its own test suite passes
(84 tests). It cannot take a DXMT texture as it is: its graphics backends accept only Vulkan and OpenGL textures
(`SupportedBackend::new` panics on any other type) and copy the game's texture into runtime-owned OpenXR swapchain
images through that graphics API. A DXMT process has neither. Using it would mean a fork with a new backend, plus a
second runtime underneath (an OpenXR runtime with a custom graphics binding and its own action/binding resolution;
xrizer's `fakexr` test runtime sets action states directly and resolves no bindings), plus an extra copy per eye, and a
GPL-3 component loaded into the game process. Every OpenVR call would cross two API layers under FEX.

The runtime here implements the OpenVR subset directly: about 2.6k lines of C++ (Apache-2.0) plus 1.5k lines of generated stubs for
every interface method. It answers `IVRSystem`, `IVRCompositor`, `IVRInput`, `IVRChaperone`, `IVRSettings`,
`IVRApplications`, `IVRRenderModels`, `IVROverlay`, `IVRScreenshots` and `IVROverlayView` at the versions of OpenVR
2.15.6. Every method the runtime does not implement logs its first call; every interface request is logged
(`STEAMAC_VR_LOG=1`). That gives the record of which versions and methods VRChat really uses.

## Input (M3)

* SteamVR Input: the action manifest, then the game's **own default binding file** for the headset's controller
  family: `oculus_touch` for Quest/Pico/Touch-style controllers, `knuckles` for Index-style ones (falls back to the
  other, then to the first listed).
* Modes: `button`, `trigger` (with `click_activate_threshold`/`click_deactivate_threshold`), `joystick`, `trackpad`,
  `dpad` (click or touch `sub_mode`), `scalar_constant`, `force_sensor`, `grab` (0.7 on / 0.6 off), `toggle_button`.
  Action sets: only the active ones are evaluated; actions report `bChanged`, `fUpdateTime` and the origin hand;
  `ulRestrictToDevice` works per hand.
* Poses: `pose/raw`, `base`, `handgrip` → grip; `pose/tip` → aim. Skeletal actions report finger curls in
  `GetSkeletalSummaryData` (trigger → index, grip → middle/ring/pinky, any thumb touch → thumb). Full bone transforms
  are not produced yet.
* Haptics: `TriggerHapticVibrationAction` and the legacy `TriggerHapticPulse` go to the host as `VRL_HAPTICS`.
* Legacy `GetControllerState` is filled from the same input snapshot.
* Input values arrive as one table per hand (`enum svr_input` in `guest/vr/include/steamac_vr_guest.h`, mirrored by
  `VRL_INPUT_COUNT` in `vrlink.h`): the headset adapter maps its controller inputs to these ids.

## Build and test (no headset, no VM)

On x86-64 Linux:

```sh
make -C guest/vr RUNTIME_LDFLAGS= check     # native toolchain: unit tests + end-to-end
guest/vr/build-sniper.sh                     # release build in the Steam Runtime sniper SDK (podman), then the same tests
```

| test | checks |
|---|---|
| `unit_tests` | JSON reader (escapes, BOM, comments, errors); binding parsing; toggle, grab hysteresis, dpad, trigger thresholds, inactive sets; pose extrapolation forwards and backwards, matrices, projection |
| `run_e2e.sh` | `vr-fakehost` (90 Hz pacing, synthetic head/hand motion, frame-keyed input script `tests/data/script.txt`) + `vr-testapp`, which loads `vrclient.so` the way Proton does and runs 150 frames: interfaces and versions, render size, projection, eye transforms, device classes, activation events, properties, frame pacing (no skipped frames), head yaw consistent with the motion model, 100 ms prediction, actions pressed/released in the scripted windows, `bChanged` exactly twice, per-hand restriction, pose actions (grip and aim), skeleton summary, legacy controller state, both eyes submitted per frame. The fake host checks every submit against the frame it issued (frame id, display time, eye poses centred on that frame's head pose and one IPD apart) and that the haptic event reached the right hand only. Run for both controller families. |
| `wmtr/tests/wmtr_loopback` (macOS) | the executor side: `WMTR_CTL_VR_QUERY` through the ring before any host state (local cadence), after `VRL_STATE`/`VRL_TIMING`/`VRL_POSES`/`VRL_INPUT`, the cadence after the pacer's frame, haptics → `VRL_HAPTICS`, an unknown request refused |

The same `vr-fakehost`/`vr-testapp` pair runs in the VM guest under FEX (`STEAMAC_VR_SOCKET` selects the socket
transport instead of wmtr).

## Deploying (not automated yet)

1. `PROTON_VR_RUNTIME=<dir>` where `<dir>/bin/linux64/vrclient.so` is the sniper build.
2. Rebuild Proton's `vrclient_x64.dll` with `guest/proton-vrclient/patches` applied to the pinned Proton
   (`guest/proton-vrclient/pin.env`) and put it in the compat tool used for the DXMT path.
3. DXMT from the `vr-export` branch (`IMTLD3D11ExportableTexture`, call 146) and a wmtr client with `wmtr_vr_call`.

## Licences

`guest/vr` is Apache-2.0, except `third_party/openvr/openvr.h` (Valve, BSD-3-Clause). `guest/proton-vrclient/patches`
are LGPL-2.1-or-later like the Proton/Wine code they change. Nothing here contains xrizer, WiVRn or Monado code.
