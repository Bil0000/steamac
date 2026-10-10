# Lean graphics path — working notes (local branch `lean-graphics`, not for publishing as-is)

Goal: fewer translation layers between a D3D11 game in the guest and Metal on the host, with measured
improvement over today's path, while patched FEX + genuine EAC keep working.

Today's path: game (DX11, x86-64) → FEX + Proton → DXVK (D3D11→Vulkan) → guest Mesa Venus → virtio-gpu →
libkrun → virglrenderer (render server) → KosmicKrisp/MoltenVK (Vulkan→Metal) → Metal → BGRA scanout copy
→ launcher window.

Target path (chosen working hypothesis, see P2): game → FEX + Proton → DXMT PE side (D3D11→Metal command
stream, x86-64 PE) → `winemetal.so` guest shim (x86-64 Linux unixlib under FEX: serializes the winemetal
unix calls) → virtio-gpu (new context type, blob shared memory) → libkrun → host executor (DXMT's
`winemetal_unix.c` compiled native arm64, plus DXBC→AIR shader compiler native) → Metal → CAMetalLayer in
the launcher window.

Layers removed: DXVK, Venus (guest and host), virglrenderer, Vulkan→Metal translation, scanout copy.

## Status per gate

| gate | status |
|---|---|
| P0 baseline | done for VRChat (A/B table below); d3d11bench-in-VM baseline still to do |
| P1 feasibility (no VM) | DXMT renders d3d11bench on macOS Wine (numbers below); VRChat on Mac Wine and D3D12 not yet; D3DMetal crashes in this setup |
| P2 cut point | winemetal-level remoting works end to end on macOS (d3d11bench through wmtr-server); sync round trip p50 0.25 µs, p99 11.5 µs; ~48 calls/frame of which ~15 sync |
| P3 transport | virtio-gpu client transport + libkrun rutabaga context written (wmtr/libkrun/wmtr.rs), not yet built into libkrun |
| P4 presentation | not started |
| P5 guest integration | not started |
| P6 full test | not started |

## P0 — baseline

Harness: `~/vrc-mac/tools/sweep-run-one.sh` (passive: launcher per-frame CSV, guest /proc, VRChat
output_log). My copy with hooks: `/Volumes/LEANWORK/lean-graphics/bin/sweep-ab.sh` (adds PREHOOK =
FEX swap with md5 check, a 30 s host sampler of CPU idle/swap/load/top-3, and the EAC launcher log read
before poweroff). Settings: memMiB 10240 (user default 8192, restored at the end), retina 1.

| run | FEX | join | in-world avg fps | 1% low | 0.1% low | note |
|---|---|---|---|---|---|---|
| P0_LEAN_R10a | 0001-0026 | yes, 31 s join→world | 19.0 | 5.0 | 1.8 | host-confounded: concurrent wineboot/clone/download + a `bfs /` scan at 190% CPU + Spotlight; Mac swap 3.8→6.4 GB |
| P0_LEAN_R10b | 0001-0026 | yes, 44 s join→world | 29.4 | 15 | 7.5 | Mac swap 5.6/7 GB at start (coordinator-verified summary) |

| AB_A2 | 0001-0020 | yes, 51 s | 37.7 | 17.5 | 9.6 | clean (coverage 99.9%, longest gap 0.5 s) |
| AB_A3 | 0001-0020 | yes, 46 s | 41.3 | 18.7 | 9.2 | clean |
| AB_B1 | 0001-0026 | yes, 54 s | 39.0 | 18.4 | 9.5 | clean |
| AB_B2 | 0001-0026 | yes, 26 s | 48.6 | 22.1 | 12.3 | clean |
| AB_B3 | 0001-0026 | yes, 43 s | 41.7 | 19.3 | 9.2 | clean |

P0 baseline (today's path, VRChat idle in one world, 10 GB VM, retina on, Mac swap 7-9 GB with Safari open):
37.7-48.6 fps in-world (5 runs), 1% low 17.5-22.1, 0.1% low 9.2-12.3. Raw data:
`~/vrc-mac/audit/vrc-runs/AB_{A2,A3,B1,B2,B3}/` (summary.csv, frames.csv, vm.out, host-sample.log).
AB_A1 has no summary: the measurement script was replaced on disk while it ran. EAC 301 was not attributed
per run by these runs (the captured line is an old one); the harness now reads files newer than the launch
marker (anticheatlauncher.log "Launcher finished with: 301", output_log "AntiCheat Session Begin: Success").

Host-condition finding: macOS load average stays ~280-300 even with the VM powered off (03:12, many idle
daemons in state R at 0% CPU), so load average is not a usable confound signal on this Mac; the sampler
records CPU idle% and swap instead.

## P1 — DXMT and D3DMetal on macOS Wine (no VM)

Setup: Sikarugir's Wine 10.0 engine (`WS12WineSikarugir10.0_6`, extracted to /Volumes/LEANWORK/wine) with
its template's dylibs; prefix /Volumes/LEANWORK/wine/pfx; renderer switch `bin/renderer.sh` (local copy of
the engine only). Test app: `d3d11bench` (own, llvm-mingw): N draws with a per-draw Map(WRITE_DISCARD)
constant buffer + K full-screen fill passes with a 24-sample pixel shader, 1280x800, no vsync, first second
excluded; prints avg fps, p50/p95/p99 frame ms, 1% low.

Findings:
* Sikarugir's prebuilt DXMT set is internally mismatched (d3d11.dll reports v0.80-215-g380af47, the
  `version` file says v0.80-213-g4ddb20e) and fails `CreateSwapChain` ("cross-process swapchain not
  supported yet") for the app's own window. DXMT PE dlls built here from 4ddb20e (+ host/dxmt patch 0001,
  marked with `winebuild --builtin`) with Sikarugir's winemetal.so of the same revision work.
* Wine needs the dlls in the prefix's system32 as well (builtins outside its fake-dll set are otherwise
  "not found").
* Stock Wine 11.18 (Gcenx build) lacks the winemac exports DXMT needs for its Metal view ("your Wine has
  no exported symbols needed by DXMT"); the Sikarugir (CrossOver-derived) engine has them.
* D3DMetal 3.0 (Sikarugir copy, used in place): d3d11bench crashes right after window creation with an
  execute fault at 0x0020019008070C10, with or without CX_APPLEGPTK_LIBD3DSHARED_PATH / CX_D3DMETALPATH /
  ROSETTA_ADVERTISE_AVX=1. Not yet resolved.

DXMT on macOS Wine, d3d11bench 15 s per config, VM off (raw: /Volumes/LEANWORK/lean-graphics/p1/w10_dxmt*):

| config | avg fps | p50 ms | p95 ms | p99 ms | 1% low fps |
|---|---|---|---|---|---|
| 200 draws, 0 fill | 242.6 | 4.10 | 9.10 | 10.76 | 62.9 |
| 10000 draws, 0 fill | 165.3 | 7.46 | 9.07 | 14.10 | 53.3 |
| 2000 draws, 4 fill | 100.5 (118.4 in an earlier 10 s run) | 8.52 | 24.01 | 25.29 | 38.4 |
| 100 draws, 16 fill | 29.7 | 33.81 | 34.80 | 35.15 | 27.6 |

Single runs; the 2000/4 repeat differs by 18%, so treat differences under ~20% as noise until repeated.

### D3D12 (DXMT, measured with d3d12bench probe; source refs src/d3d12/d3d12_device.cpp)

Max feature level 11_1, shader model 5.1 (DXBC only, no DXIL), root signature 1.1, binding tier 2, tiled
resources not supported (CreateReservedResource E_NOTIMPL), no ray tracing / mesh shaders / wave ops,
conservative rasterization not supported (Metal does not expose it), ROVs reported. Shader-visible heaps,
PSOs, ExecuteIndirect command signatures work. Known perf issue: ExecuteIndirect with 10000 draws ran at
0.2 fps vs 369 fps for the same draws issued directly (one run, VM up). D3DMetal (Sikarugir copy, in place)
crashes in this setup; not pursued (user: focus on D3D11).

## P2 — two-process remoting (measured)

Per-frame winemetal calls (wmtcount interposer, d3d11bench under direct DXMT, raw p1/wmtcount_{A,B}.log):
48 calls/frame at both 200 and 2000 draws (draws are batched into 20 encodeCommands calls). Calls that need
a reply: ~15/frame (2 autorelease pools, commandBuffer, 2 encoders, 2 status, texture width/height,
drawable texture, nextDrawable, logs, enumerate, display setting, waitUntilCompleted on DXMT's finish
thread). Blocking time is in nextDrawable (6.6-7.9 ms) and waitUntilCompleted (1.2-1.9 ms), not in work.

wmtr two-process (client winemetal.so x86_64 in Wine -> unix socket + shm -> wmtr-server arm64 running
DXMT's winemetal_unix.c + airconv natively): d3d11bench runs end to end, shaders compile on the host.
Round trip of a sync no-op request (tests/wmtr_ping, x86_64 client under Rosetta, 3 x 20000):
p50 0.25 µs, p95 0.29-0.38 µs, p99 11.5 µs (host executor asleep -> kick), max 83-94 µs.
At ~15 sync calls/frame this is ~4 µs/frame typical. Displayed fps of these runs is not comparable
(windows occluded by the user's apps: 145 vs 275 fps for the same config), so fps comparisons wait for P3.

Fixes found by this run (each with a loopback case that fails on the previous commit and passes now):
command lists longer than 512 commands, zero-length outputs, DXMT's caller-placed (CpuPlaced) buffer memory;
plus virtual per-thread autorelease pools on the host (DXMT returns autoreleased objects and brackets work in
NSAutoreleasePools from several threads).

## P2 — cut point analysis

Evidence for cutting at DXMT's winemetal unix-call boundary:

* The boundary is 136 unix calls (`src/winemetal/winemetal_thunks.c`) + 12 shader-compiler calls
  (`src/winemetal/airconv_thunks.c`); every call passes one params struct (`winemetal_thunks.h`).
* Draw-level work is batched: `MTL{Render,Compute,Blit}CommandEncoder_encodeCommands(encoder, cmd_head)`
  takes a linked list of `wmtcmd_*` structs (`winemetal.h` ~line 903 onward). Only three command types
  embed data pointers besides `next`: `wmtcmd_{render,compute}_setbytes.bytes`,
  `wmtcmd_render_setviewports.viewports`, `wmtcmd_render_setscissorrects.scissor_rects`. Everything else is
  handles (`obj_handle_t`, opaque 64-bit) and values, so the stream serializes by copying.
* Buffers: `_MTLDevice_newBuffer` (`unix/winemetal_unix.c:156`) already accepts caller-provided memory
  (`newBufferWithBytesNoCopy`), else returns `[buffer contents]` as the CPU pointer. A guest-visible blob
  mapped on the host can therefore back an MTLBuffer without copies (Apple silicon unified memory).
* libkrun (steamac patch 0007) already maps blobs as an mmap'd shm fd that is `hv_vm_map`ped into the
  guest — page-aligned host memory, which is what `newBufferWithBytesNoCopy` needs.
* Wine-specific pieces in the unix side that need a host replacement: `CreateMetalViewFromHWND`
  (macdrv window lookup, `winemetal_unix.c:1685`) and `MTLSharedEvent_setWin32EventAtValue` /
  `SharedEventListener_*` (`NtSetEvent` from a CFRunLoop thread, `winemetal_unix.c:2537-2600`).

Constraint: DXMT's `AGENTS.md` forbids AI-generated code in contributions to DXMT. Nothing here is
contributed upstream (standalone fork rule); local changes keep the LGPL-2.1 terms.

## Dead ends / notes

* Run P0_LEAN_R10a: overlapped host work → not an fps baseline (kept for join).
