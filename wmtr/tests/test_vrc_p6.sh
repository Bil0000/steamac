#!/bin/bash
# vrc-p6.sh against a stub guest (P6_G), a stub boot (a `sleep` process stands in for steamac-vm) and stub tools:
#   ok        normal run: rc 0, idle/move windows timed on the host ms clock, game closed, VM powered off
#   badroute  a garbage value after the join (route pid): rc 1, and the game is still closed and the VM off
#   nojoin    no "Finished entering world": rc 2 (invalid), game closed, VM off
# The first P6 run failed after the join on macOS `date +%s%3N` and left VRChat running with the VM up.
set -u
here=$(cd "$(dirname "$0")" && pwd); D=$here/../tools/vrc-p6.sh
T=$(mktemp -d); trap 'for f in "$T"/*/vm.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$T"' EXIT
mkdir -p "$T/tools" "$T/bin"
printf '#!/bin/sh\necho OFF\n' > "$T/tools/user_on_vrc.sh"
printf 'import sys\nprint("frame_avg_fps,60")\nprint("window,%%s,%%s" %% (sys.argv[2], sys.argv[3]))\n' > "$T/tools/frame_stats.py"
touch "$T/tools/vrc-route.py" "$T/tools/vrc-route-square.json"
printf '#!/bin/sh\necho pw\n' > "$T/bin/askpass"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/scp"
printf '#!/bin/sh\nexec sleep 0.05\n' > "$T/bin/nap"
# boot: a long sleep is the "VM"; its pid goes to vm.pid like p3-boot.sh
cat > "$T/bin/boot" <<'EOF'
#!/bin/bash
R=$P6_ROOT/$1; sleep 300 >/dev/null 2>&1 & echo $! > "$R/vm.pid"; echo "vm pid $! mode=$2"
EOF
# guest: records every command; SCENARIO picks the join/route answers
cat > "$T/bin/g" <<'EOF'
#!/bin/bash
S=$P6_ROOT/state; mkdir -p "$S"; echo "$*" >> "$S/calls"
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
case "$*" in
  *"steam://close"*) touch "$S/closed" ;;
  *"systemctl poweroff"*) cat >/dev/null; kill "$(cat "$P6_ROOT"/*/vm.pid)" 2>/dev/null ;;
  *'VRChat[.]exe'*) [ -f "$S/closed" ] && exit 1; exit 0 ;;
  *"Finished entering world"*) [ "$SCENARIO" = nojoin ] || echo "2026.10.10 16:04:34" ;;
  *"date -d"*) echo $(( $(ms) - 10500 )) ;;
  *"date +%s%3N"*) ms ;;
  *nohup*) [ "$SCENARIO" = badroute ] && echo "bash: nohup: oops" || echo 4242 ;;
  *sudo*) cat >/dev/null ;;
esac
exit 0
EOF
chmod +x "$T"/bin/* "$T"/tools/*
fails=0
fail() { fails=$((fails + 1)); echo "FAIL [$1]: $2"; }
run() { # scenario expected_rc
  local root=$T/$1; mkdir -p "$root"
  SCENARIO=$1 P6_ROOT=$root P6_G=$T/bin/g P6_BOOT=$T/bin/boot P6_SCP=$T/bin/scp P6_ASKPASS=$T/bin/askpass \
    P6_TOOLS=$T/tools P6_SLEEP=$T/bin/nap JOIN_TIMEOUT=3 P6_POLL=2 P6_BUSY_RE=no-such-process-xyz P6_VMPROC=${VMPROC:-no-such-vm-xyz} P6_DRIVER_RE=${DRIVER_RE:-t6-no-such-driver} IDLE=1 MOVE=1 \
    perl -e "alarm 60; exec @ARGV" bash "$D" "T_$1" dxvk > "$root/out" 2>&1
  local rc=$?
  [ "$rc" = "$2" ] || fail "$1" "rc $rc, expected $2: $(tail -3 "$root/out" | tr '\n' '|')"
  grep -q 'steam://close' "$root/state/calls" 2>/dev/null || fail "$1" "game not closed"
  grep -q 'systemctl poweroff' "$root/state/calls" 2>/dev/null || fail "$1" "VM not powered off"
  kill -0 "$(cat "$root/T_$1/vm.pid")" 2>/dev/null && fail "$1" "VM process still running"
  grep -q 'integer expression\|value too great\|unbound variable' "$root/out" && fail "$1" "shell error: $(grep -m1 'integer\|too great\|unbound' "$root/out")"
}
run ok 0
grep -q '^window,' "$T/ok/T_ok/stats-idle.csv" 2>/dev/null || fail ok "no idle stats"
grep -q ' done; mac' "$T/ok/T_ok/driver.log" 2>/dev/null || fail ok "driver did not finish"
run badroute 1
grep -q "cleanup after failure in phase 'move'" "$T/badroute/T_badroute/driver.log" || fail badroute "no cleanup record"
run nojoin 2
# another driver or VM already running: refuse before the boot
printf '#!/bin/sh\nsleep 20\n' > "$T/bin/t6-other-driver.sh"; chmod +x "$T/bin/t6-other-driver.sh"
"$T/bin/t6-other-driver.sh" & other=$!
busy() { # name vmproc driver_re
  local root=$T/busy-$1; mkdir -p "$root"
  SCENARIO=ok P6_ROOT=$root P6_G=$T/bin/g P6_BOOT=$T/bin/boot P6_TOOLS=$T/tools P6_BUSY_RE=no-such-process-xyz \
    P6_VMPROC=$2 P6_DRIVER_RE=$3 bash "$D" T_busy dxvk > "$root/out" 2>&1; local rc=$?
  { [ "$rc" = 1 ] && grep -q 'ABORT: a.* is running' "$root/out"; } || fail "busy-$1" "rc $rc: $(tail -1 "$root/out")"
  [ -f "$root/T_busy/vm.pid" ] && fail "busy-$1" "booted although another driver/VM runs"
}
busy driver no-such-vm-xyz 't6-other-driver[.]sh'
busy vm sleep t6-no-such-driver
# started from a shell whose own command line names the driver: that ancestor is not "another driver"
root=$T/ancestor; mkdir -p "$root"
SCENARIO=ok P6_ROOT=$root P6_G=$T/bin/g P6_BOOT=$T/bin/boot P6_SCP=$T/bin/scp P6_ASKPASS=$T/bin/askpass P6_TOOLS=$T/tools \
  P6_SLEEP=$T/bin/nap P6_POLL=2 P6_BUSY_RE=no-such-process-xyz P6_VMPROC=no-such-vm-xyz P6_DRIVER_RE=t6-anc-marker IDLE=1 MOVE=1 \
  bash -c 'bash "$1" T_anc dxvk && : t6-anc-marker' _ "$D" > "$root/out" 2>&1 || fail ancestor "rc $?: $(grep -m1 ABORT "$root/out")"
kill $other 2>/dev/null; wait $other 2>/dev/null
echo "test_vrc_p6: $([ $fails = 0 ] && echo passed || echo FAILED)"
exit $((fails > 0))
