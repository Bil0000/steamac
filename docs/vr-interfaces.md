# VR internal interfaces (steamac-vm ⇄ steamac-vrhost ⇄ headset adapter)

Status: experimental. This file is the contract between the VR milestones being built in parallel:

* **M0** host: `host/vrhost/` — `steamac-vrhost` process, WiVRn adapter, encoder (owner: M0 agent).
* **M1** DXMT eye-texture export over the wmtr ring + host Metal compositor feeding the M0 encoder.
* **M2/M3** guest OpenVR runtime + Proton `vrclient_x64` DXMT submit + input/poses.

Change it by editing this file; add a line to the change log at the bottom (who, what). Anything marked
**[decided]** is implemented or being implemented against; **[proposed]** may still change.

## 1. Processes and licences [decided]

```
 guest (Linux, x86-64 under FEX)            steamac-vm (Apache-2.0)                  steamac-vrhost (GPL-3.0-or-later)
 VRChat → openvr_api → vrclient_x64 ─wmtr ring─▶ wmtr executor (DXMT/Metal) ─VR link─▶ VrSession ─adapter─▶ headset
 (M2/M3)                                (M1: eye textures, fence)                   (M0: WiVRn adapter, later ALVR)
```

* `steamac-vrhost` is a **separate executable**. It may contain WiVRn (GPL-3) code; `steamac-vm` must never link it.
  The only coupling is the IPC in section 3 (documented here, no shared code beyond a header of plain C structs,
  `host/vrhost/include/vrlink.h`, which is dual-licensed Apache-2.0 OR GPL-3.0-or-later so both sides can include it).
* `steamac-vm` launches `steamac-vrhost` as a child (`posix_spawn`), and kills it with the VM.

## 2. VrSession — inside steamac-vrhost [decided, M0, implemented]

C++ interface: `host/vrhost/src/session/vr_session.h` (the header is the source of truth; summary here). The wire
protocol is an adapter behind it (`WivrnSession` in `src/wivrn/`, an `AlvrSession` could follow). Nothing outside
`src/wivrn/` includes WiVRn headers.

| member | meaning |
|---|---|
| `start(SessionListener*)` / `stop()` | advertise (`_wivrn._tcp`) and accept one headset at a time; background threads |
| `connected()`, `headset()` | `HeadsetInfo`: stream size per eye, render size, refresh rates, FOV, codecs, name |
| `next_frame_timing()` | blocks until the next frame should start; returns `{wake_up, predicted_display}` (host clock). M0: fixed period at the headset rate, display = wake + 40 ms; WiVRn's feedback pacer comes with M1 |
| `views_at(t, pose[2], fov[2])` | per-eye pose (head pose at `t` × eye offset) and FOV in tracking space — what an OpenVR `WaitGetPoses` returns |
| `pose_at(Device, t)` | head / grip / aim poses, interpolated or extrapolated (≤100 ms) from the tracking history |
| `submit(Frame)` | `frame_id`, `display_time`, `pose[2]`, `fov[2]`, `eye[2].surface`; encodes both eyes and sends; the surfaces may be reused when it returns |
| `haptics(Device, duration, frequency, amplitude)` | to the headset |
| `request_idr()` | force an IDR on both streams |
| `SessionListener` | `on_connected`, `on_disconnected`, `on_tracking(TrackedPose[])`, `on_input(InputValue[])`, `on_refresh_rate` |

**Encoder input format [decided].** `EyeImage.surface` is an IOSurface in `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`
(`'420f'`, NV12, BT.709 **full range**: what WiVRn's server writes in `foveation.comp` and what its clients' samplers
assume) of exactly the stream size from `HeadsetInfo`. Converting the application's RGBA eye texture (sRGB/linear,
sub-rect, flip, MSAA) into this is the **M1 compositor's** job: one Metal compute pass per eye, the MSL port of WiVRn's
`foveation.comp` (M0's `src/pattern/test_pattern.mm` shows the plane mapping: `CVMetalTextureCache`, plane 0 as
`R8Unorm`, plane 1 as `RG8Unorm`).

**Poses.** `Frame.pose` is the exact per-eye pose the image was rendered with, in the headset's tracking space; the
client reprojects against it. Use `views_at(predicted_display)` to get it.

**Timing.** All `ns` values are the host clock: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (`src/session/clock.h`); the
adapter converts to the headset clock (WiVRn timesync).

**Input ids.** `InputValue.id` currently carries WiVRn's `device_id` value (OpenXR path table in WiVRn
`common/wivrn_packets.h`). M2/M3 owns the adapter-neutral table; change it here when defined.

## 3. VR link: steamac-vm → steamac-vrhost [decided, M1 implemented the frame path]

Header: `host/vrhost/include/vrlink.h` (plain C, `Apache-2.0 OR GPL-3.0-or-later`; drafted by M1 on branch `vr-m1`,
M0/M2/M3 add their message structs there). Two channels, both set up when `steamac-vm` spawns the host:

1. **Control/events: AF_UNIX `SOCK_DGRAM` socketpair**, fd passed as `--link-fd=N`. **Changed from SOCK_SEQPACKET:
   macOS has no AF_UNIX SOCK_SEQPACKET** (`socketpair` fails with EPROTONOSUPPORT). Datagrams on a local socketpair are
   reliable, ordered and keep message boundaries; each message must stay under `net.local.dgram.maxdgram` (2048 B).
   One fixed-size struct per datagram (`struct vrl_header {uint32_t type, size;}` first). For tests and manual runs,
   `wmtr_vr_connect(path)` / `VrLinkServer::accept_one(path)` connect over a SOCK_STREAM path and hand one end of the
   DGRAM pair over by SCM_RIGHTS. Both ends send `VRL_HELLO {version, pid}` first.
2. **GPU objects: Mach ports, IOSurfaces only.** The host registers a receive right under `--mach-name=...`
   (`bootstrap_register2`, as DXMT's `WMTBootstrapRegister`); `steamac-vm` looks it up and sends one
   `struct vrl_mach_swapchain` (msgh_id `VRL_MACH_SWAPCHAIN_ID`, `IOSurfaceCreateMachPort` rights for up to 4 images)
   per swapchain, **before** the matching `VRL_SWAPCHAIN` datagram; the host receives the ports when it reads that
   datagram. **No MTLSharedEvent crosses**: `steamac-vm` sends `VRL_SUBMIT` from the copy's Metal completion handler,
   so the named images are complete when the datagram arrives (no private `newSharedEventWithMachPort` SPI, and a
   stalled guest can never stall the host GPU). Cost: one CPU wake-up per frame (measured below).

| dir | message (vrlink.h) | fields |
|---|---|---|
| vm→host | `VRL_SWAPCHAIN` `vrl_swapchain` | id (new id on every recreate), image_count (3 per eye now), w, h, MTLPixelFormat, `VRL_SWAPCHAIN_SRGB` |
| vm→host | `VRL_SUBMIT` `vrl_submit` | frame_id, display_time, app_submit_time, ready_time, per eye {swapchain, image, x,y,w,h, `VRL_EYE_FLIP_Y`}, pose[2][7] (xyzw, xyz, stage), fov[2][4] (l,r,u,d rad) |
| host→vm | `VRL_RELEASE` `vrl_release` | swapchain, image, frame_id, release_time — per eye, after the compositor pass (image reusable) |
| host→vm | `VRL_TIMING` | reserved (M0/M2) |
| host→vm | `VRL_POSES` | reserved (M0/M2/M3) |
| host→vm | `VRL_INPUT` | reserved (M3) |
| vm→host | `VRL_HAPTICS` | reserved (M3) |
| host→vm | `VRL_STATE` | reserved (M0) |

Answers to the M1 open questions: DXMT eye textures are **not** IOSurface-backed (private render targets), so the vm
side copies each eye into its own IOSurface swapchain image (one blit per eye; not separately timed, included in "submit → copy complete" below). MSAA
sources are rejected (OpenVR requires resolved textures; DXMT resolves when the game calls ResolveSubresource).
Array textures: `WMTVREye.slice` selects the slice; the blit copies it (single-pass stereo works). Format: the
swapchain keeps the eye texture's MTLPixelFormat (RGBA8/BGRA8 (+_sRGB), RGBA16Float); others are refused and counted.

### 3.1 M1 pieces (implemented)

* **DXMT** (StonkGuy/dxmt branch `vr-export`): `IMTLD3D11ExportableTexture` (uuid `ad6245d1-3a11-4dd6-87b7-7a58048b55d3`,
  QueryInterface on any `ID3D11Texture2D`): `GetMetalTexture(UINT64 *texture, UINT64 *shared_event, UINT64 *value)`
  flushes the immediate context and returns the MTLTexture handle and the DXMT queue's MTLSharedEvent + value covering
  all work submitted so far. New winemetal export `uint32_t WMTVRSubmit(const struct WMTVRSubmitInfo *)` = **unix call
  146** (async): `{frame_id, display_time, eye[2] {texture, x,y,w,h (w=0: whole), flags WMTVR_EYE_FLIP_Y|WMTVR_EYE_SRGB, slice},
  pose[2][7], fov[2][4], wait_event, wait_value}`; plain DXMT returns STATUS_NOT_SUPPORTED. **M2's vrclient path**: for
  each eye `QueryInterface(IID_IMTLD3D11ExportableTexture)` → `GetMetalTexture` → fill `WMTVRSubmitInfo` (wait_event/value
  from the last call) → `WMTVRSubmit` (GetProcAddress on winemetal.dll). Example: wmtr `tests/d3d11bench.cpp --vr W`.
* **wmtr** (steamac branch `vr-m1`): `WMTR_NCALLS` = 147; call 146 is executed by `wmtr_vr_submit` (`wmtr/src/wmtr_vr.m`,
  `include/wmtr_vr.h`), never blocks the executor: GPU waits for `wait_event`, blits into a free swapchain image, sends
  `VRL_SUBMIT` on completion; no free image → frame dropped (counted). Attach: `wmtr_host_set_vr(h, wmtr_vr_create(fd,
  mach_name))` from the embedder, or env `WMTR_VR_SOCKET=<path>` + `WMTR_VR_MACH_NAME=<name>` at `wmtr_host_create`.
  **To do for the launcher (M0/M1):** steamac-vm creates the socketpair, spawns steamac-vrhost with `--link-fd`/`--mach-name`,
  and calls `wmtr_host_set_vr` (or sets the env before libkrun creates the wmtr context).
* **steamac-vrhost** (`host/vrhost/src/compositor/`, `compositor.cmake`): `VrLinkServer(fd, mach_name, sink)` receives
  swapchains/submits and releases images after the sink returns; `CompositorBridge(out_w, out_h, EyeEncoderSink&)` runs
  `EyeCompositor` per frame: Metal compute port of WiVRn's `foveation.comp` (same per-pixel source ranges from a port of
  WiVRn's `foveation.cpp`: `solve_foveation`/`fill_param_2d`/`fill_ubo`, no-gaze centre = 1 m convergence, 10° down),
  sRGB encode + BT.709 full range → the encoder's `'420f'` CVPixelBuffer (Y + CbCr planes via CVMetalTextureCache).
  `EyeEncoderSink { acquire(eye) → CVPixelBufferRef; encode(eye, buf, LinkFrame, FoveationParams) }` — M0 adapts
  `VtEncoder` (`acquire` = `pool()`, `encode` = `VtEncoder::encode`) and sends `FoveationParams` (WiVRn
  `foveation_parameter` x/y vectors) with the stream. Output size = the stream eye size from `HeadsetInfo`.

Measured (M2 Mac, `host/vrhost/tests/m1_pipeline_test`, both link ends in one process, another VM running on the
GPU): 2064x2208 → 1248x1344 per eye at 90 Hz, 300 frames, 0 dropped: guest submit → copy complete p50 2.6 ms (includes
the producer's own render it waits for), → host receive p50 0.015 ms, → encoder input p50 2.0 ms (compositor GPU
1.7 ms for both eyes), total p50 4.6 / p99 8.9 ms.

## 4. Guest side (M2/M3) [implemented by M2/M3 on branch `vr-m23`, not yet live-tested]

Guest pieces: Proton `vrclient_x64` patch (`guest/proton-vrclient/patches`, LGPL) and our OpenVR runtime
`vrclient.so` (`guest/vr`, Apache-2.0; x86-64 Linux, loaded by Proton's unix side under FEX). Overview and tests:
`docs/vr-guest.md`. Guest wire protocol: `guest/vr/include/steamac_vr_guest.h` (dual-licensed like vrlink.h).

* **Submit [decided, uses M1's call 146].** `vrclient_x64.dll`: D3D11 texture → `QueryInterface(IMTLD3D11ExportableTexture)`
  → `GetMetalTexture` → `struct svr_metal_texture {magic "SVRT", handle, event, value, w, h, dxgi_format, array_size,
  samples}` passed as `Texture_t{handle, TextureType_Metal}` (Proton's unix side passes non-Vulkan handles through).
  The runtime collects both eyes and calls **winemetal call 146 directly** through the loaded wmtr client's
  `__wine_unix_call_funcs[146]` with a `WMTVRSubmitInfo` (`struct svr_wmtvr_submit`, layout checked by a
  `_Static_assert` in `wmtr_vr.m`): frame_id and display_time (host clock) of the frame `WaitGetPoses` returned,
  per-eye rect from the OpenVR bounds (`w = 0` whole texture, `WMTVR_EYE_FLIP_Y` when vMin > vMax), `WMTVR_EYE_SRGB`
  for 8-bit UNORM textures unless the colour space is Linear, slice (SubmitWithArrayIndex, or eye for a 2-slice
  array), per-eye pose = the frame's head pose ± IPD/2 along head x, fov of the frame, wait_event/value = the later
  eye's. MSAA textures are refused in the guest. Depth/motion attachments are not forwarded.
* **Queries [decided, new control op].** `WMTR_CTL_VR_QUERY` (= 4, a wmtr *control* request, so the winemetal call
  numbering is untouched): sync, params = one guest request, overwritten in place with the reply. Guest entry point:
  `int wmtr_vr_call(req, req_size, rep, rep_cap)` exported by the wmtr client. Executor side: `wmtr_vr_query()` in
  `wmtr_vr.m`, answered **without waiting** from the newest host packets:
  * `SVR_HELLO` → `vrl_state` (connected, eye size, refresh, IPD, fov, controller family, name).
  * `SVR_FRAME {last_frame_id}` → the pacer's `vrl_timing` (frame_id, wake_up, predicted_display); if the guest
    already has that frame (or no timing arrived), the cadence continues locally at the refresh rate. Plus
    `vrl_poses` (with the time they are for) and `vrl_input`. The guest sleeps until wake_up itself.
  * `SVR_HAPTIC` → `vrl_haptics` to the host.
* **vrlink.h additions (host → vm unless noted), for M0 to send:** `VRL_STATE` `vrl_state` on connect/disconnect/
  refresh change; `VRL_TIMING` `vrl_timing` once per frame (the pacer's next frame); `VRL_POSES` `vrl_poses`
  {time, pose[VRL_DEV_COUNT] (orientation, position, lin_vel, ang_vel, flags VALID/TRACKED/VEL), stage space} once per
  frame, predicted to that frame's display time; `VRL_INPUT` `vrl_input` {time, profile, value[2][21]} on change;
  vm → host `VRL_HAPTICS` `vrl_haptics` {hand, duration_s, frequency (0 = default), amplitude}. Devices = `vrhost::Device`
  order. Controller family `VRL_PROFILE_TOUCH` (Quest/Pico) or `VRL_PROFILE_INDEX`. **Input ids** = `enum svr_input`
  in `steamac_vr_guest.h` (trigger value/click/touch, squeeze value/click/force, thumbstick x/y/click/touch, A/X and B/Y
  click/touch, menu, system, thumbrest touch, trackpad x/y/touch/force); the adapter maps WiVRn `device_id`s to them.
* **Open for M0:** emit the five packets above from `VrSession` (the M0 `input_ids.h` should become this table or map
  to it); route `VRL_HAPTICS` to `VrSession::haptics`. **Open for the launcher:** `PROTON_VR_RUNTIME`, deploying the
  patched `vrclient_x64.dll`.

## Change log

* 2026-10-11 M0 agent: initial version (sections 1-3; section 4 placeholder).
* 2026-10-11 M0 agent: section 2 rewritten to match the implemented `vr_session.h` (encoder input = `'420f'` IOSurface, `views_at`, timing, input ids).
* 2026-10-11 M1 agent: section 3 decided and implemented for the frame path: **SOCK_DGRAM instead of SOCK_SEQPACKET** (not supported on macOS), no shared event across processes (VRL_SUBMIT sent on copy completion), vrlink.h drafted; new 3.1 (DXMT `IMTLD3D11ExportableTexture` + `WMTVRSubmit` call 146, wmtr exporter, vrhost compositor + `EyeEncoderSink`).
* 2026-10-11 M2/M3 agent: section 4 written (submit via call 146 from the guest runtime, `WMTR_CTL_VR_QUERY`,
  `VRL_STATE/TIMING/POSES/INPUT/HAPTICS` structs added to vrlink.h on `vr-m23`).
