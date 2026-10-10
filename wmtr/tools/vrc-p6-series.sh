#!/bin/bash
# vrc-p6-series.sh TAG: P6 A/B series at 10240 MiB (restored to the previous value at the end):
#   wmtr cold, dxvk, wmtr, dxvk, wmtr, dxvk. Stops at the first ABORT (gate, boot, driver error).
#   CLIENT=spin|prespin picks the guest wmtr client build (~/vrc/lean/winemetal.so.<CLIENT>).
set -u
TAG=$1; L=/Volumes/LEANWORK/lean-graphics
OLD=$(defaults read es.fxgam.steamac memMiB); defaults write es.fxgam.steamac memMiB -int 10240
trap 'defaults write es.fxgam.steamac memMiB -int "$OLD"; echo "memMiB restored to $OLD"' EXIT
n=0
for spec in "W1 wmtr 1" "D1 dxvk 0" "W2 wmtr 0" "D2 dxvk 0" "W3 wmtr 0" "D3 dxvk 0"; do
  set -- $spec
  # wmtr runs: the guest client build under test (default the current one, "spin")
  prep=; [ "$2" = wmtr ] && prep="cp ~/vrc/lean/winemetal.so.${CLIENT:-spin} ~/vrc/lean/proton-lean/files/lib/wine/x86_64-unix/winemetal.so && sha256sum ~/vrc/lean/proton-lean/files/lib/wine/x86_64-unix/winemetal.so"
  COLD=$3 GUEST_PREP=$prep "$L/bin/vrc-p6.sh" "P6_${TAG}_$1" "$2"; rc=$?
  echo "$(date +%T) P6_${TAG}_$1 rc=$rc" >> "$L/p3/p6-$TAG.series.log"
  [ $rc = 1 ] && break
done
echo "$(date +%T) series done" >> "$L/p3/p6-$TAG.series.log"
