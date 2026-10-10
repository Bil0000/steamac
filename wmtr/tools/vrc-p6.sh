#!/bin/bash
# vrc-p6.sh LABEL dxvk|wmtr: one P6 A/B run of VRChat (same world as the account's home/last world).
#   Fresh VM boot from the LEAN bundle (dxvk: wmtr off = today's path; wmtr: lean path), presence gate polled
#   every 60 s until OFF/ON-LOCAL (each reading recorded), launch, join, IDLE s idle window (from join+10 s),
#   then MOVE s of the deterministic square route (uinput, guest), close, stats, poweroff.
# Passive only: no debugger/ptrace/perf/strace on the game. EAC attributed via files newer than the marker.
set -u
LABEL=$1; MODE=$2; IDLE=${IDLE:-150}; MOVE=${MOVE:-150}
L=/Volumes/LEANWORK/lean-graphics; G=$L/bin/g; R=$L/p3/$LABEL; mkdir -p "$R"
TOOLS=$HOME/vrc-mac/tools; W=/Volumes/LEANWORK/steamac-lean/wmtr/tools
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$R/driver.log"; }
gate() { local p; p=$("$TOOLS/user_on_vrc.sh" 2>/dev/null || echo UNKNOWN); echo "$(date +%T) $p" >> "$R/gate.txt"; echo "$p"; }
wait_gate() { local p; for _ in $(seq 1 20); do p=$(gate); [ "$p" = OFF ] || [ "$p" = ON-LOCAL ] && return 0; log "gate $p: waiting 60 s"; sleep 60; done; return 1; }
poweroff() { printf '%s\n' "$("$HOME/vrc-mac/ssh/askpass")" | $G "sudo -S -p '' systemctl poweroff" >/dev/null 2>&1
  for _ in $(seq 1 60); do kill -0 "$VMPID" 2>/dev/null || { log "VM exited"; return; }; sleep 3; done; log "WARN: VM still up"; }
case $MODE in dxvk) VMMODE=off; FR=$R/perf-frames.csv; CD=/home/steamos/.local/share/Steam/steamapps/compatdata/438100 ;;
              wmtr) VMMODE=wmtr; FR=$R/wmtr-frames.csv; CD=/home/steamos/vrc/lean/compatdata-438100 ;; *) exit 2 ;; esac
log "start $LABEL mode=$MODE idle=$IDLE move=$MOVE memMiB=$(defaults read es.fxgam.steamac memMiB) mac: $(sysctl -n vm.swapusage)"
pgrep -x steamac-vm >/dev/null && { log "ABORT: a VM is running"; exit 1; }
wait_gate || { log "ABORT: gate never OFF"; exit 1; }
"$L/bin/p3-boot.sh" "$LABEL" "$VMMODE" >> "$R/driver.log" 2>&1 || { log "ABORT: boot"; exit 1; }
VMPID=$(cat "$R/vm.pid")
for _ in $(seq 1 60); do $G 'pgrep -x steamwebhelper >/dev/null && [ $(ps -o etimes= -p $(pgrep -x steam | head -1)) -gt 45 ]' 2>/dev/null && break; sleep 4; done
log "steam up; free guest /home: $($G "df -h /home | tail -1" 2>/dev/null)"
$G "echo $MODE > ~/vrc/lean/MODE; rm -f ~/vrc/lean/TRACE; mkdir -p ~/vrc/route" && scp -q -F "$HOME/vrc-mac/ssh/config" "$TOOLS/vrc-route.py" "$TOOLS/vrc-route-square.json" vrc-guest:vrc/route/
printf '%s\n' "$("$HOME/vrc-mac/ssh/askpass")" | $G "sudo -S -p '' sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'" >/dev/null 2>&1
wait_gate || { log "ABORT: gate"; poweroff; exit 1; }
M=/tmp/p6-$LABEL
$G "touch $M; XDG_RUNTIME_DIR=/run/user/\$(id -u) steam -ifrunning steam://rungameid/438100 >/dev/null 2>&1"; LSTART=$(date +%s); log "launched"
VRC=$CD/pfx/drive_c/users/steamuser/AppData/LocalLow/VRChat/VRChat; JOIN=
while [ $(( $(date +%s) - LSTART )) -lt 400 ]; do
  JOIN=$($G "f=\$(find '$VRC' -maxdepth 1 -name 'output_log_*.txt' -newer $M | head -1); [ -n \"\$f\" ] && grep -a -m1 'Finished entering world' \"\$f\" | cut -c1-19" 2>/dev/null)
  [ -n "$JOIN" ] && break; sleep 5
done
[ -n "$JOIN" ] || { log "INVALID: no join in 400 s"; echo invalid > "$R/INVALID"; $G "XDG_RUNTIME_DIR=/run/user/\$(id -u) steam steam://close/438100" >/dev/null 2>&1; sleep 10; poweroff; exit 2; }
JMS=$($G "date -d '$(echo "$JOIN" | sed 's/\./-/; s/\./-/')' +%s%3N"); log "join at $JOIN ($JMS), +$(( $(date +%s) - LSTART ))s after launch"
I0=$((JMS + 10000)); I1=$((I0 + IDLE * 1000))
while [ $(date +%s%3N) -lt $I1 ]; do sleep 2; done
MP=$($G "nohup python3 -I ~/vrc/route/vrc-route.py ~/vrc/route/vrc-route-square.json --marks /tmp/route-$LABEL.marks --duration $MOVE >/tmp/route-$LABEL.log 2>&1 </dev/null & echo \$!")
M0=$(date +%s%3N); M1=$((M0 + MOVE * 1000)); log "route pid $MP"
while [ $(date +%s%3N) -lt $M1 ]; do sleep 2; done
$G "kill -TERM $MP 2>/dev/null; cat /tmp/route-$LABEL.log" > "$R/route.log" 2>&1
END=$(date +%s%3N)
$G "XDG_RUNTIME_DIR=/run/user/\$(id -u) steam steam://close/438100" >/dev/null 2>&1; log "closed"
for w in "idle $I0 $I1" "move $M0 $M1"; do set -- $w
  { python3 -I "$TOOLS/frame_stats.py" "$FR" "$2" "$3"; python3 -I "$W/hitches.py" "$FR" "$2" "$3"; } > "$R/stats-$1.csv" 2>&1
done
sleep 15
$G "find '$CD/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat' -type f -newer $M -exec grep -a -h 'Launcher finished' {} + ; find '$VRC' -maxdepth 1 -name 'output_log_*.txt' -newer $M -exec grep -a -h 'AntiCheat Session Begin\|Finished entering world\|Graphics Device Version' {} +" > "$R/eac-log.txt" 2>&1
log "eac: $(grep -a -o 'Launcher finished with: [0-9]*' "$R/eac-log.txt" | tail -1) | $(grep -a -o 'AntiCheat Session Begin: [A-Za-z]*' "$R/eac-log.txt" | tail -1)"
grep -a "faulted" "$R/vm.out" | head -3 >> "$R/driver.log"
poweroff
for w in idle move; do log "$w: $(grep -E '^(frame_avg_fps|frame_1pct_low_fps_pct|frame_0.1pct_low_fps_pct|frame_longest_gap_s|hitch_ge_1s|hitch_ge_2s),' "$R/stats-$w.csv" | tr '\n' ' ')"; done
log "done; mac: $(sysctl -n vm.swapusage)"
