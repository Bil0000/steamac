#!/bin/bash
# vrc-p6-series.sh TAG: P6 A/B series at 10240 MiB (restored to the previous value at the end):
#   wmtr cold, dxvk, wmtr, dxvk, wmtr, dxvk. Stops at the first ABORT (gate, boot).
set -u
TAG=$1; L=/Volumes/LEANWORK/lean-graphics
OLD=$(defaults read es.fxgam.steamac memMiB); defaults write es.fxgam.steamac memMiB -int 10240
trap 'defaults write es.fxgam.steamac memMiB -int "$OLD"; echo "memMiB restored to $OLD"' EXIT
n=0
for spec in "W1 wmtr 1" "D1 dxvk 0" "W2 wmtr 0" "D2 dxvk 0" "W3 wmtr 0" "D3 dxvk 0"; do
  set -- $spec
  COLD=$3 "$L/bin/vrc-p6.sh" "P6_${TAG}_$1" "$2"; rc=$?
  echo "$(date +%T) P6_${TAG}_$1 rc=$rc" >> "$L/p3/p6-$TAG.series.log"
  [ $rc = 1 ] && break
done
echo "$(date +%T) series done" >> "$L/p3/p6-$TAG.series.log"
