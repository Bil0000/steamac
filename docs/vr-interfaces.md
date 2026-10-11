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

## 3. VR link: steamac-vm → steamac-vrhost [proposed by M0, M1 to confirm]

Two channels, both set up when `steamac-vm` spawns the host:

1. **Control/events: Unix `SOCK_SEQPACKET` socketpair**, fd passed as `--link-fd=N`. Fixed-size message structs from
   `vrlink.h` (little-endian, `uint32_t type; uint32_t size;` header). Carries frame submits, poses, inputs, haptics,
   timing. No allocations in the per-frame path.
2. **GPU objects: Mach ports.** IOSurfaces and the frame `MTLSharedEvent` cross by Mach port, sent **once per swapchain**
   (not per frame): the host registers a bootstrap name given on argv (`--mach-name=com.steamac.vrhost.<vm-uuid>`,
   same mechanism as DXMT's `WMTBootstrapRegister/LookUp`), `steamac-vm` looks it up and sends a Mach message with
   `IOSurfaceCreateMachPort()` rights for each swapchain image and the shared event's port.
   Host side: `IOSurfaceLookupFromMachPort`, `MTLDevice newSharedEventWithMachPort:` (the DXMT/winemetal thunk path).

Per-frame flow (all on the SOCK_SEQPACKET channel):

| dir | message | fields |
|---|---|---|
| vm→host | `VRL_SWAPCHAIN` | swapchain id, image count, w, h, MTLPixelFormat, srgb flag (ports arrive by Mach msg, same ids) |
| vm→host | `VRL_SUBMIT` | frame_id, swapchain id, image index per eye, rect per eye, flip_y, pose[2], fov[2], display_time, shared-event value to wait for (the vrhost-side M1 compositor converts the RGBA image to the `'420f'` encoder input of section 2) |
| host→vm | `VRL_RELEASE` | swapchain id, image index (producer may reuse it) |
| host→vm | `VRL_TIMING` | wake_up, predicted_display, refresh Hz (answers `WaitGetPoses`) |
| host→vm | `VRL_POSES` | array of `TrackedPose` at predicted_display |
| host→vm | `VRL_INPUT` | array of `InputValue` |
| vm→host | `VRL_HAPTICS` | device, duration, frequency, amplitude |
| host→vm | `VRL_STATE` | connected/disconnected, HeadsetInfo |

Why this split: no per-frame Mach messages or port rights (cheap), shared-memory not needed for ~200-byte messages at
90 Hz, and IOSurface/MTLSharedEvent are the only objects Metal can share across processes without a copy. Times are the
host monotonic clock (`CLOCK_UPTIME_RAW` ns); the vm side converts to guest time when it relays to the guest (M2/M3).

Open questions for M1: whether DXMT eye textures can be allocated as IOSurface-backed (M1 copies into a vrhost
swapchain image if not: one blit per eye); MSAA resolve location; 2-slice array textures (single-pass instanced).

## 4. Guest side (M2/M3) [placeholder, owned by M2/M3]

The guest sees only the wmtr ring: VR opcodes for submit (handle per eye + bounds + pose id), wait-poses, input poll,
haptics. `steamac-vm` (wmtr executor) translates those to section 3 messages.

## Change log

* 2026-10-11 M0 agent: initial version (sections 1-3; section 4 placeholder).
* 2026-10-11 M0 agent: section 2 rewritten to match the implemented `vr_session.h` (encoder input = `'420f'` IOSurface, `views_at`, timing, input ids).
