# KosmicKrisp graphics pipeline libraries

Experimental implementation: patches 0048–0049, enabled in the **host launcher's environment** with
`MESA_KK_EXPERIMENTAL=gpl`. This is downstream Mesa code, not a stock FEX option. Default behaviour is unchanged.
It advertises `VK_EXT_graphics_pipeline_library` and `VK_KHR_pipeline_library`, with
`graphicsPipelineLibraryFastLinking = false`. Do not enable it by default on the evidence below.

## What phase 1 does

The Mesa runtime retains shader precompiles (SPIR-V to NIR) in libraries. Final linking invokes the driver's full
program compilation, including NIR lowering, MSL generation and Metal pipeline creation. No independent Metal
shader-stage compilation has moved to library creation. This is a correctness foundation, not a demonstrated
stutter fix.

DXVK `685301564ea3486a7098bd37194020da84299617` (v3.1.1 + 47, the Proton Experimental pin used by the optional
DXVK build) does **not** gate GPL on `graphicsPipelineLibraryFastLinking`:
`DxvkDevice::canUseGraphicsPipelineLibrary` checks the feature, independent interpolation decoration and its
configuration option. `DxvkShaderPipelineLibrary::canCreatePipelineLibrary` uses that predicate.
`DxvkGraphicsPipeline::createInstance` calls `getBasePipeline` synchronously; `compilePipeline` normally skips
state-cache precompiles for pipelines eligible for this path. Consequently phase 1 can still stall at first draw
and may lose useful precompilation. This conclusion is source analysis, not a measured game regression.

## Why independent compilation is not a small flag change

At Mesa base `ce576c29` plus this fork's patches:

* `kk_populate_vs_key` hashes vertex input and topology. `kk_lower_vs_vbo` lowers fetches using actual binding,
  format, divisor and input rate. KK uses shader-based vertex fetching; its current bridge does not install a
  Metal vertex descriptor. Merely deferring a descriptor therefore does not separate the shader from input state.
* `kk_populate_fs_key` and `kk_lower_fs` depend on attachment formats, blend state, multisampling, depth/stencil
  presence and input-attachment mapping. Blend operations, format signedness and non-native channel swizzles can
  change shader code. Moving just the attachment formats to a final Metal descriptor is insufficient.
* `kk_new_render_pipeline` compiles both MSL libraries and creates a Metal render pipeline state. Attachment
  formats, topology, sample count and view amplification still participate in that final operation.

Existing approaches inform the design but are not interchangeable. NVK uses the shared runtime's shader compile
and state-hash interfaces and advertises fast linking. Honeykrisp lowers inputs/outputs to prologs/epilogs and
calls `agx_fast_link` on native shader parts; that binary linker is not available through Metal. Lavapipe retains
NIR and compiles linked executable pipelines, which is the closer model for phase 1. Reuse the Mesa runtime and
existing NIR lowering rather than building a parallel pipeline implementation.

## Phase 2 design and gates

1. Separate shader-stage preparation from executable pipeline creation in KK, retaining a stage-owned Metal
   library with explicit ownership, cache keys and thread-safe lifetime. Support the full GPL state contract,
   not just the four-library test's simple shaders.
2. Make vertex fetch independent of vertex-input library state, using an opt-in dynamic-fetch path. Reuse Mesa's
   format and robustness lowering; test missing attributes, formats, instancing/divisors and robustness. Keep
   the current static path for applications not using this feature: no universal per-vertex format switch.
3. Separate fragment-output specialisation. Investigate Metal function specialisation or separately compiled
   functions for blend/swizzle/type conversion, including MRT, dual-source blending, sample shading and depth
   writes. Precompiled MSL alone does not establish cheap final specialisation or compatible stage interfaces.
4. Measure cold final pipeline-state creation after early stage-library compilation. A binary archive may help
   repeated states, but cannot be claimed to eliminate first-use compilation of previously unseen state.
5. Only advertise fast linking after representative cold links are demonstrated cheap. Add Mesa unit tests for
   the new lowering/key/lifetime mechanisms, native pixel oracles, and host integration tests. Then verify Venus
   passthrough, DXVK usage, d3d11bench images and interleaved game runs with the same workload and caches.

There is no safe, evidence-backed phase-2 implementation in this branch yet. In particular, do not set the fast
linking property to true or layer an unverified generic fetch/blend engine into all shaders.

## Validation (2026-10-12)

The Mac driver built with the unpacked CLT27 Metal 4 SDK. Direct-host tests passed:

* `gpl-link`: monolithic, non-LTO library link and retained-LTO link all render `ff406020`; libraries are destroyed
  before drawing the linked pipelines. Fixed the test's original expected pixel: RGB is multiplied by 0.5, alpha
  uses `ONE`, and little-endian BGRA packs as `ff406020`, not `80402060`.
* With the experiment unset, `gpl-link` reports the GPL extensions absent and skips, as intended.
* Allocation granularity and sparse binding, dynamically indexed shader input/output, and 600 asynchronous
  pipeline create/destroy cycles passed.

A temporary timing probe on the small test observed the first invocation's vertex/fragment library calls at
11.408/9.841 ms and final render-pipeline creation at 17.455 ms; subsequent identical states were much cheaper.
These are a single small-shader observation, include cache effects, and are **not** a game benchmark or a cold-cache
performance guarantee. The probe is not shipped.

The x86 reference host was unreachable on this continuation, so the corrected pixel oracle has not been rerun
there. VM work is blocked by the coordinator's memory-guard hold: no Venus verification, game stutter A/B,
d3d11bench image comparison or VRChat world-entry pass is claimed. Keep this work on `kk-gpl`, off by default;
no integration into the development or release branch is justified yet.
