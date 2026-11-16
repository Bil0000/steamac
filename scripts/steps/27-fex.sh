#!/bin/bash
# Step 27 (runs in AARCH64_IMAGE from guest/mesa/versions.env: holo-deckard base-devel, the SteamOS
# guest's own userspace, so the binaries link against its libraries): the patched FEX of
# fex-eac/build-fex.sh, tuned for Apple M1 (the oldest supported Mac) instead of the build machine.
#   /work/out/fex-eac/stage     Runtime component + .steamac-fex-source (= FEX_EAC_SHA), packed by
#                               step 30 into /usr/lib/steamac/fex-eac/stage
#   /work/out/fex-eac/licenses  license texts of FEX and its bundled sources
# Clean build from a fresh clone of the pinned tag on every run.
set -euo pipefail

OUT=/work/out/fex-eac
WORK=/tmp/fex-eac
# --needed: never touch libraries that are already installed (they must stay identical to the image).
pacman -Sy --noconfirm --needed clang lld cmake ninja git python

rm -rf "$OUT" "$OUT.tmp"
WORK=$WORK TUNE_CPU=apple-m1 sh /src/fex-eac/build-fex.sh
grep -q -- '-mcpu=apple-m1' "$WORK/FEX/build-steam/build.ninja" \
    || { echo "[fex] build.ninja does not use -mcpu=apple-m1" >&2; exit 1; }
mkdir -p "$OUT.tmp/licenses"
cp -a "$WORK/stage" "$OUT.tmp/stage"
cp "$WORK/FEX/LICENSE" "$OUT.tmp/licenses/FEX-LICENSE"
for f in "$WORK"/FEX/External/*/LICEN[CS]E* "$WORK"/FEX/External/*/COPYING*; do
    [[ -f $f ]] || continue
    name=${f#"$WORK"/FEX/External/}
    cp "$f" "$OUT.tmp/licenses/${name//\//-}"
done
# SoftFloat-3e carries its BSD notice only in its source headers.
sed -n '1,/\*\/$/p' "$WORK/FEX/External/SoftFloat-3e/src/extF80_add.c" > "$OUT.tmp/licenses/SoftFloat-3e-LICENSE"
mv "$OUT.tmp" "$OUT"
echo "[fex] $OUT/stage: $(cat "$OUT/stage/.steamac-fex-source"), $(sed -n 's/^FEX describe\t//p' "$OUT/stage/VERSIONS.txt"), $(clang --version | head -1)"
