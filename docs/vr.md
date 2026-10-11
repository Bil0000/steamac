# VR (experimental)

**Status: experimental, milestone M0.** A Mac-native VR host, `steamac-vrhost`, streams a test pattern to a standalone
headset running the WiVRn client. No game, VM or guest is involved yet; nothing in the launcher starts it.

## What works (M0)

* `steamac-vrhost` speaks the **WiVRn v26.9** protocol (hash `fc26e619b7ab80f8`), using WiVRn's own protocol,
  serialization and socket code, vendored unmodified (`host/vrhost/third_party/wivrn/UPSTREAM.md`).
* Bonjour advertisement `_wivrn._tcp` on port 9757 with WiVRn's TXT keys (`protocol`, `version`, `cookie`), so the
  headset's server list shows the Mac.
* Handshake: version check (an incompatible client gets WiVRn's `incompatible_version` answer), encryption
  **disabled**, control on TCP and stream on UDP, headset info.
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

Not yet: PIN pairing/encryption (the code is vendored and built, not wired), WiVRn's feedback-driven pacer, foveation,
audio, game frames (M1), OpenVR in the guest (M2/M3).

## Licence

`host/vrhost/` is **GPL-3.0-or-later** because it contains WiVRn code. It builds a separate executable; `steamac-vm`
(Apache-2.0) does not link it. They will talk over the IPC described in `docs/vr-interfaces.md`.

## Build and test (no headset)

Requires Xcode command-line tools, CMake ≥ 3.25, Ninja and OpenSSL 3 (`brew install cmake ninja openssl@3`).

```sh
cmake -S host/vrhost -B build/vrhost -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
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
| `loopback` | the full server against a test headset that follows the WiVRn client's connection sequence over loopback: handshake, stream description, tracking control, timesync, UDP shards, decode of 60+ frames per eye with matching frame numbers, poses 64 mm apart, display time in the headset clock, a lost frame → new IDR → decoding resumes, wrong protocol refused |

Encoder self-test on an M2 MacBook Air (16 GB, macOS 27), 2 eyes encoded concurrently, measured while a steamac VM was
running (2026-10-11):

| per-eye size, rate | encode per eye p50 / p95 (ms) | both eyes p50 / p95 (ms) | frame budget (ms) |
|---|---|---|---|
| 1832×1920, 90 Hz (Quest 3 default) | 18.3 / 20.8 | 20.2 / 21.1 | 11.1 |
| 1440×1584, 72 Hz | 10.6 / 12.3 | 12.1 / 12.4 | 13.9 |
| 1280×1408, 72 Hz | 9.0 / 10.2 | 10.1 / 10.3 | 13.9 |

The two VideoToolbox sessions share one media engine (about 350 Mpixel/s of HEVC here), so encoding both eyes in
parallel saves little. Quest 3's default stream size at 90 Hz does not fit; 72 Hz at about 1440×1584 per eye does. The
stream size is the headset's request; `--size WxH` overrides it.

## Testing with a headset

The client must be **WiVRn v26.9** exactly: WiVRn refuses any other protocol version (the headset greys the server
out). Mac and headset on the same LAN; allow `steamac-vrhost` in System Settings → Privacy & Security → Local Network
when macOS asks.

```sh
build/vrhost/steamac-vrhost --testpattern            # add --size 1440x1584 to lower the stream size
```

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

## Next milestones

* **M1:** game eye textures from DXMT over the wmtr ring into `steamac-vm`, shared with `steamac-vrhost` as IOSurfaces,
  converted by a Metal compositor pass (WiVRn's `foveation.comp` in MSL) into the encoder input; WiVRn's pacer.
* **M2/M3:** OpenVR in the guest (Proton `vrclient_x64` DXMT submit, poses, input), then VRChat.

Interfaces between these pieces: `docs/vr-interfaces.md`.
