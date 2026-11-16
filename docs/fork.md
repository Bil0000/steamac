# Fork notes

A fork of [steamac](https://github.com/fxgl/steamac) (base: 1.9; results on 1.9 are marked, older ones were measured on 1.8.1/1.8.2) that adds support for genuine-Easy-Anti-Cheat x86 games,
verified in earlier VRChat sessions with `eac-2610.2` (Mini Royale's EAC also reached `301`; results differ game by game), plus launcher and stability fixes. The current `eac-2610.3` runtime and automatic setup have not passed a real game test. Nothing here is sent to libkrun, Mesa, FEX or Proton by this fork;
steamac changes are discussed with its maintainer directly. Bug reports are welcome here (see the README). Not affiliated with FX GAMES, Valve, Epic or VRChat.

## Changes

| change | where | why | status |
|---|---|---|---|
| patched FEX-2610 ([StonkGuy/FEX](https://github.com/StonkGuy/FEX/tree/eac-2610) tag `eac-2610.3`), `build-fex.sh`, `install-fex-tool.sh`, `guest-tune.sh` | [`fex-eac/`](../fex-eac/README.md) | Valve's FEX-2607 in Steam's compatibility tool fails EAC's ptrace injection and signal semantics ([eac-how-it-works.md](eac-how-it-works.md)) | `.2`: tested in 3 sessions; current `.3`: gameplay unverified |
| triple-buffered present | launcher (Swift) | replaces a `waitUntilCompleted()` per frame | experimental |
| `--render-scale` (0.25–1.0) with MetalFX upscaling | launcher (Swift) | render below native and upscale, to move the frame-time cost off the GPU while keeping UI at real-world size | experimental (default stays 1.0 = unchanged) |
| libkrun log level default `error` | launcher | less logging overhead | experimental |
| Metal HUD library loaded only when the HUD is on | launcher | avoids loading it needlessly | experimental |
| direct-to-display presentation, key releases never dropped, HID off the main thread, Retina EDID DPI, stall-indicator timer, pad-port lock, `framebufferOnly` restore, Clipboard-writer restart | launcher | findings of a code audit of 1.8.2 | experimental |
| kernel parameter `virtio_snd.msg_timeout_ms=10000` | guest default | a slow microphone start otherwise trips a 1 s guest time-out and freezes the game ([eac-troubleshooting.md](eac-troubleshooting.md)) | workaround, built |
| asynchronous capture start, no global lock across CoreAudio calls | libkrun patch 0018 | root cause of the microphone freeze | experimental |
| start the capture unit **outside** the `capture` mutex | libkrun patch 0020 | `AudioOutputUnitStart` can block (microphone open / permission prompt) while holding a lock the snd pump takes every iteration, wedging *every* virtio-snd control message — the real cause of the microphone freeze | verified live |
| copy only the damage owed to each frame buffer | libkrun patch 0019 | avoids copying the whole scanout per present | experimental |
| 5 robustness fixes from the same audit (XFB bounds, `container_of` guard, minmax UAB scan, NULL plane layouts, sparse underflow) | KosmicKrisp patch 0100 (was 0042) | defensive fixes | experimental |
| opt-in frame-latency toggle (**Settings > Advanced "Frame latency"**; `dxgi.maxFrameLatency = 1`) | launcher (Swift) + guest `steam-frame-latency` | stock DXVK option that caps the frames the CPU runs ahead of the GPU, for lower input latency at some cost in throughput; the guest writes it into the DXVK config (`$DXVK_CONFIG_FILE`, else `$HOME/vrc/dxvk.conf`) so no game needs a launch option | experimental; **off by default**, the guest's DXVK config is left unchanged. Vulkan path only (the DXMT path has its own config) |
| bound the indirect-deref branch tree (`nir_lower_indirect_derefs_to_if_else_trees`, threshold 16) | KosmicKrisp patch 0101 (was 0046) | bounds a compile-time blow-up that shows as a long synchronous-compile stall | experimental |
| Metal command allocators reset and released | KosmicKrisp patch 0104 (was 0051) | an allocator went back to its command pool at `vkEndCommandBuffer` and was reused without a reset, so it kept every command recorded with it. In a Bodycam match the allocators held 23 GiB (43 GB process footprint): macOS ran out of application memory and joining a match froze while the Mac swapped. The allocator is now reset when its command buffer is reset or destroyed, and a pool keeps at most 4 allocators of at most 4 MiB each (`tests/cmd-alloc-leak.c`: 16000 resubmissions grow the footprint 838 MiB before, none after) | host tests pass; live: allocator memory stayed at about 1.2 GiB through a Bodycam start (was 23 GiB and growing) |
| timestamps resolved in runs and triggered once per compute encoder | KosmicKrisp patch 0103 (was 0053; 0052 is upstream 0064 now) | vkd3d-proton writes 8192 timestamps in one command buffer; each had its own counter heap resolve (about 56 KiB of command allocator memory) and its own trigger dispatch between two barriers (about 10 KiB). One recording took 526 MiB and a Bodycam match grew the footprint past 12 GB within a minute, so the whole Mac lagged (`tests/ts-heap-leak.c`: 547 MiB before, under 60 MiB after) | host tests pass; live: GPU memory about 4 GB after 72 s of a match with 0052 (12 GB before); 0053 not yet live-tested |
| a never-submitted Metal command buffer released before its allocator reset | KosmicKrisp patch 0105 (was 0054) | since 0051 a reset allocator went to the next recording while a Metal command buffer that was recorded and never committed still owned its memory; when that buffer began again or was released, the next commit crashed in `fillCommandBufferArgs` (FX quit in the Bodycam training area). vkd3d-proton leaves one for every closed D3D12 command list it never executes (`tests/cmd-unsubmitted.c`: crashed before, passes after) | host tests pass; live: not yet verified |
| aligned indexed indirect draws kept in the render pass | KosmicKrisp patch 0106 (was 0055) | with robustness on (vkd3d-proton), every indexed indirect draw was unrolled by a compute dispatch, which ends the Metal render encoder: about 700 encoders per frame in Bodycam, the Venus ring thread CPU bound and the GPU half idle (more with glass scopes, which add passes). macOS 26 gives the Metal 4 indirect draw's index length to the GPU as 4-byte words, so the length is now passed in words (rounded up to the index size) and draws whose index range is 4-byte aligned and a multiple of 4 indices are not unrolled (`tests/indirect-index-bound.c`: 2000 draws 164 ms before, 1.6 ms after; out-of-range indices still draw nothing) | host tests pass; live: Bodycam 24 fps (41.7 ms frames, 310% VM CPU) before, about 72 fps (p95 18 ms, 222–282% VM CPU, GPU use 50% to 82%) after; 3 minutes in game with no stall |
| DXMT graphics path (since 1.9.14: **Settings > Advanced > Allow DXMT** plus a per-game profile in Settings > Games): Direct3D 11/10 (and experimentally 12) through DXMT, its Metal calls remoted over a dedicated virtio-gpu context to a host executor. DXMT is [StonkGuy/dxmt](https://github.com/StonkGuy/dxmt) branch `steamac` (upstream plus fixes adopted from other DXMT forks with their authors, ledger in its STEAMAC-README.md), pinned by commit in `host/dxmt/pin.env` | `wmtr/`, libkrun patch 0021, `host/dxmt/patches/` (generated by `scripts/export-dxmt-patches.sh`), guest `steam-gfx-path`, launcher | fewer translation layers than DXVK + Venus + virglrenderer + Vulkan-to-Metal | **verified live on 1.9**: VRChat EAC `301` + session + world on DXMT (DXMT pin upstream e94c312 + steamac d5576ef, 2026-10-11); measured ahead of Vulkan ([eac-performance.md](eac-performance.md)). Default stays Vulkan |
| `steam-gfx-path`: Direct3D 12 routed to DXMT when the payload has it, ARM64 Protons left stock, Proton's kept originals deleted only once they are back (a DXMT file from another app build is recognised; with no original kept, a warning names Steam's Verify integrity) | guest `steam-gfx-path` | switching paths, or between two app builds on one disk, could leave DXMT's d3d11/dxgi in Proton and Direct3D 11 games failing on Vulkan | built; `scripts/test/steam-gfx-path.sh` (cases foreign/noorig fail before the fix, pass after) |
| virtio-snd: control requests and the playback pump no longer stall each other; a failed control request completes the stream's queued I/O; control deadline 8 s | libkrun patches 0022, 0023 | a slow CoreAudio start under load otherwise left the guest driver refusing every PREPARE ("invalid I/O queue state") | experimental; offline unit tests pass, live verification of 0023 pending |
| virtio-input worker runs at user-interactive QoS, like the vCPUs and the GPU worker (0013) | libkrun patch 0024 | key presses and pointer motion reach the guest through that thread; a busy host should not delay them | experimental; unit test for the QoS helper passes, the thread's runtime QoS is unverified |
| DXMT path: arena blobs idle after a load peak go back to the Mac. Idle blobs beyond a 128 MiB warm reserve are released once they have been idle for 1 s (`WMTR_ARENA_KEEP_MB`, `WMTR_ARENA_TRIM_MS`; `WMTR_ARENA_KEEP_MB=-1` keeps them all). On release the guest closes the blob and the wmtr context drops its own mapping | `wmtr/` client and transports, libkrun patch 0028 | each blob is shared memory mapped three times (VMM, Hypervisor.framework stage-2, executor), so a level-load peak otherwise stays in `phys_footprint` until the game exits | experimental; `wmtr_loopback` (footprint 504 -> 203 MiB after the peak) and the libkrun `wmtr` detach test pass; a live footprint check in the VM is still owed |

The app-side changes (the launcher changes above, libkrun 0018/0019/**0020**, KosmicKrisp 0100-0106) are **experimental**, except libkrun 0020, which is verified live. Since the merge with steamac 1.9.14 the fork's opt-in asynchronous pipelines (KosmicKrisp 0041/0043/0047/0050, `MESA_KK_ASYNC_PIPELINES`) are gone: upstream 0051-0057 and 0063 compile every pipeline on a thread pool, and upstream 0055 keeps the disk cache the fork's 0044 added (host/kosmickrisp/patches/README.md has the old -> new numbers). These results describe the earlier `.2` setup; the current `.3` runtime and automatic setup need live checks. Each earlier change was built and checked in isolation, and the live runs of the combined app are listed above. They are verified only on an M2 MacBook Air, 16 GB, macOS 27.0, with steamac 1.8.1/1.8.2. The launcher build is
clean (`swift build -c release`, 0 warnings). One logging-only race remains open and is not claimed fixed: `hidInputs` is
incremented on `hidQueue` and reset on the main thread.

## Audit

12 parallel code audits of steamac 1.8.2, every claim re-verified. They also confirmed upstream issues this fork does not
yet fix, including a full-frame scanout copy per present in libkrun.

## Build and deploy a local app

1. Start from the official steamac release bundle (1.8.1/1.8.2).
2. Replace its launcher with the rebuilt launcher from this fork (`build.sh`).
3. Ad-hoc sign the app with the entitlements of the release build.
4. macOS treats the re-signed app as a new app: it asks again for microphone permission and keychain access.

The libkrun 0018/0019 and KosmicKrisp 0100-0106 changes are separate components of the bundle. They are **experimental**: each passed its adversarial re-verification. These historical results do not verify the current `.3` runtime.

## Documents

| page | contents |
|---|---|
| [eac-how-it-works.md](eac-how-it-works.md) | the chain and why the FEX swap is needed |
| [eac-troubleshooting.md](eac-troubleshooting.md) | symptoms, checks and fixes |
| [eac-performance.md](eac-performance.md) | measurements and limits |
| [fex-eac/README.md](../fex-eac/README.md) | FEX setup and launch options |
