# KosmicKrisp patches

`build.sh` (one level up) applies these `git format-patch` files in name order on top of the pinned Mesa commit.
Each patch names its upstream origin (a Mesa merge request) or says it is a steamac change.

0001–0098 are steamac upstream's series, with its gaps (0060, 0070, 0081, 0084, 0093, 0097). 0100–0108 are this
fork's patches on top of it; 0099 is not used, so that the fork's series starts at a round number.

The fork's series was 0041–0055 before the merge with steamac 1.9.14, whose own 0041–0098 took those numbers. Its
0041/0043/0047/0050 (opt-in asynchronous pipelines, `MESA_KK_ASYNC_PIPELINES`) are gone: upstream 0051–0057 and 0063
compile every pipeline on a thread pool instead. Its 0044 (disk cache) is upstream 0055, its 0049 (pools without
counter heap entries) upstream 0045 and its 0052 (one resolve for consecutive timestamps) upstream 0064. Its 0053
(one timestamp trigger dispatch per compute encoder, briefly 0103) is dropped: with upstream 0064 it broke the
timestamp tests. The others are 0100–0106 in the same order, without 0103:

| now  | was  | change |
| ---- | ---- | ------ |
| 0100 | 0042 | audit robustness fixes |
| 0101 | 0046 | bounded indirect-deref branch tree |
| 0102 | 0048 | timestamp chunks of a destroyed device |
| 0104 | 0051 | Metal command allocators reset |
| 0105 | 0054 | uncommitted Metal command buffers released before the allocator reset |
| 0106 | 0055 | aligned indexed indirect draws kept in the render pass |
| 0107 | new  | sparse residency through read-only textures on Apple10 |
| 0108 | new  | release-build bound checks of guest-controlled indices |
