#!/bin/bash
# benchmat.sh LABEL WINE_BIN: d3d11bench config matrix (15 s each) on one renderer.
# configs: present-bound (200 draws, 0 fill), draw-bound (10000 draws), mixed (2000 draws, 4 fill),
# fill-bound (100 draws, 16 fill). Results: /Volumes/LEANWORK/lean-graphics/p1/<LABEL>.results
set -u
LABEL=$1; WINE=$2; shift 2
O=/Volumes/LEANWORK/lean-graphics/p1; R=$O/$LABEL.results; : > "$R"
echo "# $(date '+%F %T') $LABEL wine=$WINE load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage | awk '{print $6}') vm=$(pgrep -x steamac-vm >/dev/null && echo up || echo off)" >> "$R"
for cfg in "200 0" "10000 0" "2000 4" "100 16"; do
  set -- $cfg
  name="${LABEL}_d$1_f$2"
  "$WINE" /Volumes/LEANWORK/lean-graphics/d3d11bench/d3d11bench.exe --seconds 15 --draws $1 --overdraw $2 \
    --csv "Z:${O//\//\\}\\$name.csv" --label "$name" > "$O/$name.out" 2>&1
  grep -a RESULT "$O/$name.out" >> "$R" || echo "FAILED $name" >> "$R"
done
cat "$R"
