# VR (experimental)

**Status: experimental, M0–M3 implemented and M4 integration in progress.** The host, guest OpenVR runtime, input/pose
path and Proton DXMT texture submit have offline fake-host coverage. No headset-backed VRChat session has been run;
M4 guest/FEX and host-launcher integration remain open.

## Using the launcher

1. Install the WiVRn v26.9 client for the headset as described below, and put the Mac and headset on the same LAN.
2. In Launcher Settings → VR, enable **VR (experimental)**. This setting is off by default and is available only with
   the DXMT graphics path. Start the VM; the launcher starts the separate `steamac-vrhost` process with it.
3. Pairing: with **Let new headsets ask to pair** (default on) a headset that is not paired yet opens pairing when it
   connects; enter the six-digit PIN shown in the panel and in the VM window's title in WiVRn on the headset. Pairing
   closes again once it has paired. With the option off, new headsets are refused (the panel names the refused headset
   and offers **Pair this headset**). Paired headsets reconnect with encryption enabled; the paired list groups entries
   of the same name (a reinstalled or test client), and **Unpair** removes them all.
4. Options follow WiVRn's split between headset and machine. On the headset (WiVRn app): refresh rate, resolution
   scale and microphone; the panel shows the current values only. In the panel (next start unless noted):
   * **Quality**: preset (Low/Medium/High/Ultra, or Custom), **Render resolution** 50-150 % of the headset's render
     size (`--render-scale`; below 100 % the Mac upscales before encoding with **MetalFX** spatial or bilinear,
     `--upscaler`), **Sharpening** (`--sharpness`), **Treat game images as sRGB** (`--force-srgb`, for games whose
     8-bit images hold sRGB data without the sRGB format).
   * **Video codec**: Automatic/HEVC/H.264, **Bitrate** (applies at once to a running host; the headset can still
     lower it), **Keyframe interval** (`--keyframe-interval`; default only when the headset reports a loss).
   * **Stream**: resolution per eye (stream size), **TCP only** (`--tcp-only`).
   * **Statistics**: live game fps, copy/compose/encode/decode times, bitrate, lost frames, upscaler.
   Measured on an M2 (`test_foveation_geometry`, Quest 3 sizes, both eyes): MetalFX upscale from 50 % adds about
   2.8 ms of compositor GPU time per frame, bilinear about 0.55 ms; sharpening has no measurable cost. Not offered:
   temporal MetalFX (OpenVR submits no motion vectors or depth), AV1 (no hardware AV1 encoder on these Macs), HEVC
   10-bit (the WiVRn v26.9 stream description carries no bit depth; untested with real clients), constant bitrate
   (VideoToolbox rejects it with low-latency rate control), encoder speed priority (no measurable gain: 19.5 vs
   19.9 ms p50 per eye pair), reprojection/frame pacing modes (done by the WiVRn client itself).
5. Game: **Start in VR** runs `steam -ifrunning steam://launch/<id>/vr` in the guest (fx-progress-agent `launch-vr`;
   a plain launch may pick a game's desktop mode). The same game (Steam app ID, default VRChat 438100) is listed in the
   WiVRn app's app list on the headset; picking it there starts it the same way. **Game audio in the headset** (default
   on) routes the guest's sound to a connected headset and its microphone to the guest.
6. The panel reports headset connection, battery, codec, encryption and host encoder/stream statistics. If the host is
   not running, it can still show and remove the saved paired-headset list; pairing and live status require the host.

**Limitations:** VR is experimental and off by default. The guest OpenVR runtime and the Proton `vrclient_x64` path are
not included in the end-user launcher, so a game cannot currently submit eye frames through this UI. The headset server
and encoder can be tested independently with `--testpattern`; the integrated host frame path is for development and is
not yet an end-user in-game VR feature. Use a WiVRn v26.9 client only; newer protocol versions are incompatible. The
encoder must meet the headset's refresh-rate budget; reduce per-eye resolution or refresh rate if frames cannot keep up.

## What works (M0)

* `steamac-vrhost` speaks the **WiVRn v26.9** protocol (hash `fc26e619b7ab80f8`), using WiVRn's own protocol,
  serialization and socket code, vendored unmodified (`host/vrhost/third_party/wivrn/UPSTREAM.md`).
* Bonjour advertisement `_wivrn._tcp` on port 9757 with WiVRn's TXT keys (`protocol`, `version`, `cookie`), so the
  headset's server list shows the Mac.
* Handshake: version check (an incompatible client gets WiVRn's `incompatible_version` answer), control on TCP and
  stream on UDP, headset info.
* **Encryption and PIN pairing** as in WiVRn, with WiVRn's own code: X448 key exchange, the PIN checked by SMP (the
  PIN never crosses the network), keys derived with PBKDF2, AES-128-CTR on both the TCP control and UDP stream
  sockets. Paired headsets are remembered in `~/Library/Application Support/steamac/vrhost/known_keys` and reconnect
  without a PIN. Same modes as WiVRn: pairing (default while no headset is paired, or with `--pair`), encryption on
  with pairing off (default once a headset is paired: unknown headsets get `pairing_disabled`), `--no-encryption`.
* **Pacing: WiVRn's pacer** (`server/compositor/pacer.cpp`, unmodified): the headset's feedback packets (decode,
  blit and display times, converted with the timesync clock offset) set how early a frame is started (99.5th
  percentile of present-to-decoded + 1 ms) and the predicted display time, and phase-lock frames to the headset's
  vsync. `next_frame_timing()` returns the frame id the pacer assigned (`FrameTiming::frame_id`).
* Timesync (WiVRn's clock regression), `tracking_control`, head/controller pose history with interpolation and bounded
  extrapolation, per-eye poses from the headset's view offsets.
* VideoToolbox **HEVC** (H.264 fallback), hardware encoder required, low-latency rate control, no frame reordering,
  infinite GOP, BT.709 full range. Annex-B with VPS/SPS/PPS before every IDR, IDR on request and on reported loss
  (WiVRn's IDR state machine), IDR frames on TCP like WiVRn's encoders, 1400-byte shards with `view_info` on the first
  shard and timing on the last, identity foveation.
* Test pattern: a sky sphere with a 15° grid, coloured 45° sectors, a yellow horizon and a red marker straight ahead,
  rendered by a Metal compute kernel for the pose the frame is sent with, so it stays **world-locked** while the head
  turns (rotation; the sphere is at infinity, so walking does not move it). The frame number is encoded in the top-left
  corner (16 blocks) for automated checks.

Implemented since M0: PIN pairing/encryption, WiVRn's pacer, compositor foveation, audio transport, DXMT game-frame
path (M1), guest OpenVR runtime/input (M2/M3), and Proton's DXMT texture-export patch (M4). The Proton bootstrap
`IVRCompositor_028` adapter and M4 guest/FEX end-to-end run remain pending.

## Licence

`host/vrhost/` is **GPL-3.0-or-later** because it contains WiVRn code. It builds a separate executable; `steamac-vm`
(Apache-2.0) does not link it. They will talk over the IPC described in `docs/vr-interfaces.md`.

## Build and test (no headset)

Requires Xcode command-line tools, CMake ≥ 3.25 and Ninja (`brew install cmake ninja`). OpenSSL is **not** taken
from the system: the build downloads the pinned OpenSSL 3.5.4 release tarball (SHA-256 checked), builds a static
`libcrypto` (no shared libs, no TLS, no apps; about 2 minutes once) into the build directory and links it, so
`steamac-vrhost` loads only macOS system libraries. The binary is signed ad hoc with the identifier
`com.steamac.vrhost` after linking (stable identity for the Local Network permission). `-DVRHOST_SYSTEM_OPENSSL=ON`
uses `find_package(OpenSSL)` instead, for development only.

```sh
cmake -S host/vrhost -B build/vrhost -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
ninja -C build/vrhost
ctest --test-dir build/vrhost --output-on-failure
build/vrhost/steamac-vrhost --selftest-encoder          # headless VideoToolbox latency report
```

| test | checks |
|---|---|
| `protocol` | the vendored tree hashes to the pinned WiVRn v26.9 value; a first shard with `view_info` round-trips |
| `annexb` | length-prefixed → Annex-B, malformed input, start-code splitting, HEVC NAL types |
| `pose_history` | interpolation, angular/linear extrapolation and its 100 ms bound, pose composition |
| `encoder` | hardware + low-latency session, VPS/SPS/PPS only before IDRs, IDR on request, decode back (VideoToolbox) to the same frame number; HEVC and H.264 |
| `pacer` | WiVRn's pacer with synthetic feedback (headset clock 5 s ahead): learns decode time + margin and blit-to-display, phase-locks display times to the headset vsync grid, ignores stale feedback |
| `crypto` | both peers derive the same AES keys (X448 + PBKDF2), SMP accepts the right PIN and rejects a wrong one, key PEM round trip, paired-headset store (replace, remove, mode 0600) |
| `self_contained` | `otool -L steamac-vrhost` lists only `/usr/lib` and `/System` libraries |
| `loopback` | the full server against a test headset that follows the WiVRn client's connection sequence over loopback: handshake, stream description, tracking control, timesync, UDP shards, decode of 60+ frames per eye with matching frame numbers, poses 64 mm apart, display time in the headset clock, a lost frame → new IDR → decoding resumes, wrong protocol refused; pacing: with synthetic headset feedback (8 ms decode, 72 Hz vsync at a 3.3 ms phase) the announced display times land on the headset's vsync grid; encryption: PIN pairing then encrypted stream (lost frame + IDR included), reconnect of the paired headset without PIN, wrong PIN refused and not stored, pairing disabled refuses an unknown headset |

Encoder self-test on an M2 MacBook Air (16 GB, macOS 27), 2 eyes encoded concurrently, measured while a steamac VM was
running (2026-10-11):

| per-eye size, rate | encode per eye p50 / p95 (ms) | both eyes p50 / p95 (ms) | frame budget (ms) |
|---|---|---|---|
| 1832×1920, 90 Hz (Quest 3 default) | 18.3 / 20.8 | 20.2 / 21.1 | 11.1 |
| 1440×1584, 72 Hz | 10.6 / 12.3 | 12.1 / 12.4 | 13.9 |
| 1280×1408, 72 Hz | 9.0 / 10.2 | 10.1 / 10.3 | 13.9 |

Encoder tuning knobs (`--selftest-encoder`): `--layout eyes|serial|sbs` (one session per eye concurrently, one after
the other, or one side-by-side 2W×H session), `--prioritize-speed`, `--max-frame-delay N`, `--qp N` (constant QP via
Min/MaxAllowedFrameQP), `--no-low-latency-rc`, `--codec h264`, `--csv` for one summary line per run. First finding:
the low-latency HEVC encoder **rejects** `PrioritizeEncodingSpeedOverQuality` and `MaxFrameDelayCount` (the
self-test lists rejected properties); the full sweep is still to be measured on an idle machine.

The two VideoToolbox sessions share one media engine (about 350 Mpixel/s of HEVC here), so encoding both eyes in
parallel saves little. Quest 3's default stream size at 90 Hz does not fit; 72 Hz at about 1440×1584 per eye does. The
stream size is the headset's request; `--size WxH` overrides it.

## Real Linux client test

The reproducible Fedora/x86 real-client procedure and current blockers are tracked in [`vr-testing.md`](vr-testing.md).
It is not yet verified end-to-end; the fake-headset loopback results above are not a substitute.

## Testing with a headset

The client must be **WiVRn v26.9** exactly: WiVRn refuses any other protocol version (the headset greys the server
out). Mac and headset on the same LAN; allow `steamac-vrhost` in System Settings → Privacy & Security → Local Network
when macOS asks.

```sh
build/vrhost/steamac-vrhost --testpattern            # add --size 1440x1584 to lower the stream size
build/vrhost/steamac-vrhost --show-pin               # the PIN, while the host waits for a new headset
build/vrhost/steamac-vrhost --list-headsets          # paired headsets; --unpair NAME / --unpair-all
```

The first connection of a headset asks for the 6-digit PIN printed by the host (`--pin NNNNNN` fixes it, `--pair`
accepts new headsets when one is already paired).

* **Meta Quest 2/3/3S/Pro, Pico 4/Neo 3:** install `WiVRn-release.apk` from the
  [v26.9 release](https://github.com/WiVRn/WiVRn/releases/tag/v26.9) with `adb install` (developer mode), and turn off
  automatic updates for WiVRn if you also have the Store version: a newer client will not connect. Start WiVRn on the
  headset; the Mac appears in its server list (or add it by IP, port 9757).
* **Steam Frame:** WiVRn's Linux client runs on the Frame (Linux arm64). There is no prebuilt client in the v26.9
  release, so build the client from the `v26.9` tag (`-DWIVRN_BUILD_CLIENT=ON -DWIVRN_BUILD_SERVER=OFF`), on the Frame
  or in an arm64 Linux build environment, and connect to the Mac by IP.

What to check: the pattern appears; the red marker stays at the same place in the room while you turn your head; the
`steamac-vrhost` log prints frames, feedback and tracking counts every 5 s, the last encode time and the headset's
decode time.

## M4: headset-less VRChat path checklist

Complete in order; the VM step is gated by the coordinator's memory guard and must not be attempted until cleared.

* **Encode budget sweep** (pending, needs an idle Mac): the knob matrix above × resolution/refresh, H.264 vs HEVC,
  foveated stream sizes from M1.

- [x] Extract candidate OpenVR interface versions from installed VRChat binaries and Unity/IL2CPP metadata, without
  launching the game. Inventory and caveat: `docs/vr-interfaces.md` and local provenance
  `/Volumes/LEANWORK/vr-vrchat-interfaces.txt`.
- [x] Implement DXMT D3D11 texture export in the pinned Proton `vrclient_x64` path and add a COM fake-texture test,
  including array texture slices and a stock-Proton negative control.
- [ ] Integrate M6 version adapters, especially `IVRCompositor_028`, and run the real Proton registry bootstrap path
  (no manual registry-state bypass); verify `HmdSystemFactory` and `VRClientCoreFactory` resolve.
- [ ] Run the Proton test and `guest/vr` fakehost/testapp under FEX in the VM; no VRChat launch is needed for this gate.
- [ ] Verify the installer/launcher sets `PROTON_VR_RUNTIME`, installs the rebuilt PE DLL and Unix library, and restores
  stock Proton files when VR is disabled.
- [ ] Connect the host pipeline and fake headset, then confirm frame arrival, input/pose, haptics and clean shutdown.
- [ ] Only after those pass, request explicit coordination for a VRChat live run. Before starting, confirm Steam does not
  say the account is playing elsewhere; launch in the background without focus stealing. No debugger/ptrace/perf tools.

Interfaces between components: `docs/vr-interfaces.md`. Guest build/test details: `docs/vr-guest.md`.
