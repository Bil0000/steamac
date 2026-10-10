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
| P0 baseline | in progress — A/B 0001-0020 vs 0001-0026 under identical host conditions |
| P1 feasibility (no VM) | Wine 10.0 (Sikarugir engine) + DXMT local; test app toolchain (llvm-mingw) ready |
| P2 cut point | analysis started (below) |
| P3 transport | not started |
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

Host-condition finding: macOS load average stays ~280-300 even with the VM powered off (03:12, many idle
daemons in state R at 0% CPU), so load average is not a usable confound signal on this Mac; the sampler
records CPU idle% and swap instead.

## P2 — cut point analysis (in progress)

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
