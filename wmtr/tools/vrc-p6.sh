#!/bin/bash
# vrc-p6.sh LABEL dxvk|wmtr: one P6 A/B run of VRChat (same world as the account's home/last world).
#   Fresh VM boot from the LEAN bundle (dxvk: wmtr off = today's path; wmtr: lean path), presence gate polled
#   every 60 s until OFF/ON-LOCAL (each reading recorded), launch, join, IDLE s idle window (from join+10 s),
#   then MOVE s of the deterministic square route (uinput, guest), close, stats, poweroff.
# Passive only: no debugger/ptrace/perf/strace on the game. EAC attributed via files newer than the marker.
# Host side only: steamac-vm per-thread CPU (ps -M) every 15 s into host-threads.log.
#
# Whatever happens after the boot (error, unbound variable, bad clock value, Ctrl-C), the EXIT trap closes the
# game and powers the VM off, so a failed run never leaves VRChat running unattended.
# Exit codes: 0 done, 1 abort (gate, boot, busy host, driver error), 2 invalid run (no join).
#
# Test hooks (tests/test_vrc_p6.sh): P6_ROOT (result root), P6_G (guest command runner), P6_BOOT (boot script),
# P6_SCP, P6_ASKPASS, P6_TOOLS, P6_SLEEP, P6_BUSY_RE, P6_VMPROC, P6_DRIVER_RE; P6_POLL scales the 60 s gate and the shutdown waits.
set -u
LABEL=$1; MODE=$2; IDLE=${IDLE:-150}; MOVE=${MOVE:-150}; JOIN_TIMEOUT=${JOIN_TIMEOUT:-400}
L=/Volumes/LEANWORK/lean-graphics; G=${P6_G:-$L/bin/g}; R=${P6_ROOT:-$L/p3}/$LABEL; mkdir -p "$R"
TOOLS=${P6_TOOLS:-$HOME/vrc-mac/tools}; W=$(cd "$(dirname "$0")" && pwd); [ -f "$W/hitches.py" ] || W=/Volumes/LEANWORK/steamac-lean/wmtr/tools
BOOT=${P6_BOOT:-$L/bin/p3-boot.sh}; ASKPASS=${P6_ASKPASS:-$HOME/vrc-mac/ssh/askpass}; SLEEP=${P6_SLEEP:-sleep}
SCP=${P6_SCP:-scp -q -F $HOME/vrc-mac/ssh/config}; POLL=${P6_POLL:-60}
GUEST_ENV='XDG_RUNTIME_DIR=/run/user/$(id -u)'
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$R/driver.log"; }
# ms wall clock: macOS `date` has no %N (`date +%s%3N` prints a literal "N"), so use python
nowms() { python3 -c 'import time;print(int(time.time()*1000))'; }
isint() { case ${1:-x} in ''|*[!0-9-]*) return 1 ;; esac; }
need_int() { isint "${2:-}" || die "bad $1 value '${2:-}'"; }
die() { log "ERROR: $*"; exit 1; }
gate() { local p; p=$("$TOOLS/user_on_vrc.sh" 2>/dev/null || echo UNKNOWN); echo "$(date +%T) $p" >> "$R/gate.txt"; echo "$p"; }
wait_gate() { local p; for _ in $(seq 1 20); do p=$(gate); { [ "$p" = OFF ] || [ "$p" = ON-LOCAL ]; } && return 0
  log "gate $p: waiting $POLL s"; $SLEEP "$POLL"; done; return 1; }
sudo_g() { printf '%s\n' "$("$ASKPASS")" | $G "sudo -S -p '' $1" >/dev/null 2>&1; }
# heavy host work skews the measurement and starves the VM (the first P6 run overlapped a swift build)
BUSY_RE=${P6_BUSY_RE:-'swift-build|swift-frontend|clang|cargo|rustc|xcodebuild|ld'}
busy_host() { pgrep -x "$BUSY_RE" 2>/dev/null | head -1; }
# steamac-vm and its children (the VM process); per-thread %CPU >= 1 (ps -M thread rows start with the pid)
vm_threads() { local p; for p in "$VMPID" $(pgrep -P "$VMPID" 2>/dev/null); do ps -M -p "$p" 2>/dev/null |
  awk -v p="$p" 'NR>1 { c = ($1 ~ /^[0-9]+$/) ? $2 : $4; if (c + 0 >= 1.0) print p, c }'; done; }

VMPID=; DONE=0; GAME=0; LOPTS=0; PHASE=start
# wmtr runs need ~/vrc/lean/lean-wrap.sh in VRChat's launch options; it is there only while the run needs it
lopts_off() { [ "$LOPTS" = 1 ] || return 0
  $G "$GUEST_ENV ~/vrc/lean/lean-launchopts.sh off" >> "$R/driver.log" 2>&1 && { LOPTS=0; log "launch options restored"; } || log "WARN: launch options NOT restored"; }
close_game() {
  $G "$GUEST_ENV steam steam://close/438100" >/dev/null 2>&1
  local i; for i in $(seq 1 $((POLL * 2 + 1))); do $G 'pgrep -f "VRChat[.]exe" >/dev/null' 2>/dev/null || { log "game exited"; return 0; }; $SLEEP 2; done
  log "WARN: game still running after close"; return 1; }
poweroff() {
  [ -n "$VMPID" ] || return 0
  sudo_g "systemctl poweroff"
  local i; for i in $(seq 1 $((POLL + 1))); do kill -0 "$VMPID" 2>/dev/null || { log "VM exited"; VMPID=; return 0; }; $SLEEP 3; done
  log "WARN: VM still up after poweroff; SIGTERM $VMPID"; kill -TERM "$VMPID" 2>/dev/null
  for i in $(seq 1 10); do kill -0 "$VMPID" 2>/dev/null || { VMPID=; return 0; }; $SLEEP 3; done; log "WARN: VM $VMPID did not exit"; }
cleanup() {
  local rc=$?
  for p in ${SAMPLERS:-}; do kill "$p" 2>/dev/null; done
  [ "$DONE" = 1 ] && return
  [ "$rc" = 0 ] && rc=1
  log "cleanup after failure in phase '$PHASE' (rc=$rc)"
  [ "$GAME" = 1 ] && close_game
  lopts_off
  poweroff
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

case $MODE in dxvk) VMMODE=off; FR=$R/perf-frames.csv; CD=/home/steamos/.local/share/Steam/steamapps/compatdata/438100 ;;
              wmtr) VMMODE=wmtr; FR=$R/wmtr-frames.csv; CD=/home/steamos/vrc/lean/compatdata-438100 ;; *) DONE=1; exit 2 ;; esac
# LEANWRAP=0 (wmtr): the guest's own graphics path (steam-gfx-path follows steamac.gfx=dxmt): the game's real
# prefix and launch options, as a user runs it; LEANWRAP=1 (default): the launch-options wrapper and prefix copy
LEANWRAP=${LEANWRAP:-1}
[ "$MODE" = wmtr ] && [ "$LEANWRAP" = 0 ] && CD=/home/steamos/.local/share/Steam/steamapps/compatdata/438100
log "start $LABEL mode=$MODE idle=$IDLE move=$MOVE memMiB=$(defaults read es.fxgam.steamac memMiB 2>/dev/null) mac: $(sysctl -n vm.swapusage)"
# one driver and one VM at a time: refuse if any steamac-vm or another vrc-p6.sh (not this shell or its
# subshells) is running
v=$(pgrep -x "${P6_VMPROC:-steamac-vm}" | tr '\n' ' '); [ -z "$v" ] || { log "ABORT: a VM is running (pid $v)"; DONE=1; exit 1; }
# (ancestors are skipped too: the shell that started this driver has its name on its command line)
o=$(ps -axo pid=,ppid=,command= | awk -v me=$$ -v re="${P6_DRIVER_RE:-vrc-p6[.]sh}" '
  { pp[$1] = $2; line[$1] = $0; cmd[$1] = $3 }
  END { for (p = me; p > 1; p = pp[p]) { skip[p] = 1; if (!(p in pp)) break }
        for (p in line) if (!skip[p] && pp[p] != me && cmd[p] !~ /(^|\/)awk$/ && line[p] ~ re) printf "%s ", p }')
[ -z "$o" ] || { log "ABORT: another P6 driver is running (pid $o)"; DONE=1; exit 1; }
b=$(busy_host); [ -z "$b" ] || { log "ABORT: host busy (build process pid $b)"; DONE=1; exit 1; }
# COLD=1 (wmtr): start without DXMT's shader cache for VRChat (host side; kept aside, not deleted)
DC="$(getconf DARWIN_USER_CACHE_DIR)/dxmt/VRChat.exe"
if [ "$MODE" = wmtr ] && [ "${COLD:-0}" = 1 ] && [ -d "$DC" ]; then mv "$DC" "$DC.aside-$LABEL"; log "cold: moved $DC aside"; fi
log "dxmt cache: $(du -sh "$DC" 2>/dev/null | cut -f1 || echo none)"
PHASE=gate; wait_gate || { log "ABORT: gate never OFF"; DONE=1; exit 1; }
PHASE=boot; "$BOOT" "$LABEL" "$VMMODE" >> "$R/driver.log" 2>&1 || { log "ABORT: boot"; DONE=1; exit 1; }
VMPID=$(cat "$R/vm.pid"); need_int vm.pid "$VMPID"
SAMPLERS=
( while kill -0 "$VMPID" 2>/dev/null; do echo "$(date +%T) $(sysctl -n vm.swapusage | awk '{print $6}') free%=$(memory_pressure -Q 2>/dev/null | awk '/percentage/{print $NF}') vm_rss_mb=$(ps -o rss= -p "$(pgrep -P "$VMPID" -x steamac-vm | head -1)" 2>/dev/null | awk '{print int($1/1024)}') busy=$(busy_host)"; $SLEEP 15; done ) > "$R/mac-mem.log" 2>&1 &
SAMPLERS="$SAMPLERS $!"
( while kill -0 "$VMPID" 2>/dev/null; do echo "@ $(nowms)"; vm_threads; $SLEEP 15; done ) > "$R/host-threads.log" 2>&1 &
SAMPLERS="$SAMPLERS $!"
PHASE=steam-up
for _ in $(seq 1 60); do $G 'pgrep -x steamwebhelper >/dev/null && [ $(ps -o etimes= -p $(pgrep -x steam | head -1)) -gt 45 ]' 2>/dev/null && break; $SLEEP 4; done
log "steam up; free guest /home: $($G "df -h /home | tail -1" 2>/dev/null)"
# guest-host clock offset (guest log times -> host clock), ssh round trip midpoint
h0=$(nowms); gm=$($G 'date +%s%3N'); h1=$(nowms); need_int guest-clock "$gm"; OFS=$(( (h0 + h1) / 2 - gm )); log "clock: host-guest ${OFS} ms"
$G "echo $MODE > ~/vrc/lean/MODE; rm -f ~/vrc/lean/TRACE; mkdir -p ~/vrc/route" || die "guest setup"
# GUEST_PREP: one guest shell command before the launch (e.g. pick the wmtr client build under test)
if [ -n "${GUEST_PREP:-}" ]; then $G "$GUEST_PREP" || die "guest prep"; log "guest prep: $GUEST_PREP"; fi
if [ "$MODE" = wmtr ] && [ "$LEANWRAP" = 1 ]; then LOPTS=1; $G "$GUEST_ENV ~/vrc/lean/lean-launchopts.sh on" >> "$R/driver.log" 2>&1 || die "launch options on"
  for _ in $(seq 1 30); do $G 'pgrep -x steamwebhelper >/dev/null' 2>/dev/null && break; $SLEEP 4; done; $SLEEP 20; fi
$SCP "$TOOLS/vrc-route.py" "$TOOLS/vrc-route-square.json" vrc-guest:vrc/route/ || die "route copy"
sudo_g "sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'"
PHASE=gate2; wait_gate || die "gate"
b=$(busy_host); [ -z "$b" ] || die "host busy (build process pid $b)"
PHASE=launch; M=/tmp/p6-$LABEL; GAME=1
$G "touch $M; $GUEST_ENV steam -ifrunning steam://rungameid/438100 >/dev/null 2>&1"; LSTART=$(nowms); log "launched"
VRC=$CD/pfx/drive_c/users/steamuser/AppData/LocalLow/VRChat/VRChat; JOIN=
PHASE=join
while [ $(( $(nowms) - LSTART )) -lt $((JOIN_TIMEOUT * 1000)) ]; do
  JOIN=$($G "f=\$(find '$VRC' -maxdepth 1 -name 'output_log_*.txt' -newer $M | head -1); [ -n \"\$f\" ] && grep -a -m1 'Finished entering world' \"\$f\" | cut -c1-19" 2>/dev/null)
  [ -n "$JOIN" ] && break; $SLEEP 5
done
[ -n "$JOIN" ] || { log "INVALID: no join in $JOIN_TIMEOUT s"; echo invalid > "$R/INVALID"; close_game; poweroff; DONE=1; exit 2; }
GJ=$($G "date -d '$(echo "$JOIN" | sed 's/\./-/; s/\./-/')' +%s%3N"); need_int join-time "$GJ"
JMS=$((GJ + OFS)); log "join at $JOIN (host $JMS), launch->join $(( (JMS - LSTART) / 1000 ))s"
PHASE=idle; I0=$((JMS + 10000)); I1=$((I0 + IDLE * 1000))
while t=$(nowms); need_int clock "$t"; [ "$t" -lt "$I1" ]; do $SLEEP 2; done
PHASE=move
MP=$($G "nohup python3 -I ~/vrc/route/vrc-route.py ~/vrc/route/vrc-route-square.json --marks /tmp/route-$LABEL.marks --duration $MOVE >/tmp/route-$LABEL.log 2>&1 </dev/null & echo \$!")
need_int route-pid "$MP"; M0=$(nowms); M1=$((M0 + MOVE * 1000)); log "route pid $MP"
while t=$(nowms); need_int clock "$t"; [ "$t" -lt "$M1" ]; do $SLEEP 2; done
$G "kill -TERM $MP 2>/dev/null; cat /tmp/route-$LABEL.log" > "$R/route.log" 2>&1
PHASE=close; close_game; GAME=0; log "closed"; lopts_off
for w in "first60 $JMS $((JMS + 60000))" "idle $I0 $I1" "move $M0 $M1"; do set -- $w
  { python3 -I "$TOOLS/frame_stats.py" "$FR" "$2" "$3"; python3 -I "$W/hitches.py" "$FR" "$2" "$3"; } > "$R/stats-$1.csv" 2>&1
done
$SLEEP 15
PHASE=eac
$G "find '$CD/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat' -type f -newer $M -exec grep -a -h 'Launcher finished' {} + ; find '$VRC' -maxdepth 1 -name 'output_log_*.txt' -newer $M -exec grep -a -h 'AntiCheat Session Begin\|Finished entering world\|Graphics Device Version' {} +" > "$R/eac-log.txt" 2>&1
log "eac: $(grep -a -o 'Launcher finished with: [0-9]*' "$R/eac-log.txt" | tail -1) | $(grep -a -o 'AntiCheat Session Begin: [A-Za-z]*' "$R/eac-log.txt" | tail -1)"
grep -a "faulted" "$R/vm.out" 2>/dev/null | head -3 >> "$R/driver.log"
PHASE=poweroff; poweroff
for w in first60 idle move; do log "$w: $(grep -E '^(frame_avg_fps|frame_1pct_low_fps_pct|frame_0.1pct_low_fps_pct|frame_longest_gap_s|hitch_ge_1s|hitch_ge_2s),' "$R/stats-$w.csv" | tr '\n' ' ')"; done
log "done; mac: $(sysctl -n vm.swapusage)"
DONE=1
