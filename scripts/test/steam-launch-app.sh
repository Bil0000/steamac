#!/bin/bash
# SPDX-License-Identifier: MIT
# guest/layer/usr/lib/steamac/steam-launch-app (steamac.launch_app= on the kernel command line):
#   none    no key or a bad value: Steam is not called
#   wait    the game starts only after this boot's ready marker, with steam://rungameid/APPID
#   once    a second run in the same boot (Steam restarted) starts nothing
#   unit    steam.service runs it after Steam starts
# usage: scripts/test/steam-launch-app.sh
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/guest/layer/usr/lib/steamac/steam-launch-app
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; fail() { fails=$((fails + 1)); echo "FAIL [$1]: $2"; }
printf '#!/bin/bash\necho "$@" >> %q\n' "$T/calls" > "$T/steam"; chmod +x "$T/steam"

run() { # cmdline runtime-dir
    printf '%s\n' "$1" > "$T/cmdline"
    mkdir -p "$2"
    STEAMAC_CMDLINE=$T/cmdline XDG_RUNTIME_DIR=$2 STEAMAC_READY_MARKER=$T/ready STEAMAC_BOOT_ID=boot-1 \
        STEAMAC_STEAM=$T/steam STEAMAC_WAIT_STEPS=20 bash "$S"
}
calls() { cat "$T/calls" 2>/dev/null; }

for c in "" "console=hvc0" "steamac.launch_app=" "steamac.launch_app=x" "steamac.launch_app=0" "steamac.launch_app=1;reboot"; do
    run "$c" "$T/rt-none"; rm -rf "$T/rt-none"
done
sleep 1
[ -z "$(calls)" ] || fail none "steam called: $(calls)"

echo boot-0 > "$T/ready"
run "console=hvc0 steamac.launch_app=2406770 rootwait" "$T/rt"
sleep 2
[ -z "$(calls)" ] || fail wait "started before this boot's ready marker: $(calls)"
echo boot-1 > "$T/ready"
for _ in $(seq 30); do [ -n "$(calls)" ] && break; sleep 0.2; done
[ "$(calls)" = "steam://rungameid/2406770" ] || fail wait "calls: $(calls)"

run "steamac.launch_app=2406770" "$T/rt"
sleep 2
[ "$(calls | wc -l | tr -d ' ')" = 1 ] || fail once "started again: $(calls)"

grep -qx 'ExecStartPost=-/usr/lib/steamac/steam-launch-app' "$R/guest/layer/usr/lib/systemd/user/steam.service.d/50-steamac.conf" \
    || fail unit "steam.service drop-in does not run it"

[ $fails = 0 ] && echo "steam-launch-app: PASS" || { echo "steam-launch-app: $fails FAILED"; exit 1; }
