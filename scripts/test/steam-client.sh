#!/bin/bash
# SPDX-License-Identifier: MIT
# guest/layer/usr/lib/steamac/steam-client without /usr/share/deckard/RUNSTEAM.sh (moved by a
# SteamOS update): exits 0 with one log line, so steam.service still starts Steam stock.
# Runs on a Linux host without that file (CI, or the builder container).
# usage: scripts/test/steam-client.sh
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
[ -r /proc/cmdline ] || { echo "SKIP: not Linux (no /proc/cmdline)"; exit 0; }
[ ! -e /usr/share/deckard/RUNSTEAM.sh ] || { echo "SKIP: /usr/share/deckard/RUNSTEAM.sh exists here"; exit 0; }
mkdir -p "$T/home/.local/share/Steam/config" "$T/run"
echo '"AutoLogin" "1"' > "$T/home/.local/share/Steam/config/loginusers.vdf"
HOME=$T/home XDG_RUNTIME_DIR=$T/run bash "$R/guest/layer/usr/lib/steamac/steam-client" 2> "$T/err"
rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c 'RUNSTEAM.sh not found' "$T/err")" = 1 ]; then
    echo "PASS steam-client: missing stock RUNSTEAM.sh"
else
    echo "FAIL steam-client: exit $rc: $(cat "$T/err")"; exit 1
fi
