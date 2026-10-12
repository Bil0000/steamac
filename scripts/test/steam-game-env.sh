#!/bin/bash
# SPDX-License-Identifier: MIT
# The game environment defaults that replace the documented Steam launch options:
# guest/layer/usr/lib/steamac/steam-game-env (installer) and proton-user-settings.py (what Proton imports).
#
# Installer, against a fake Steam tree with a second library:
#   install   every Proton whose script reads user_settings.py gets the file, in both libraries and in
#             compatibilitytools.d; a tool without that mechanism and a game directory get nothing
#   again     a second run changes nothing (idempotent)
#   own       a user's own user_settings.py is left byte for byte
#   update    a new payload (layer update) replaces this script's file, not the user's
#   off       steamac.game_env=0 removes this script's files and only those
# Environment, with the loop Proton's own script uses (a variable already in the environment wins):
#   vrchat    VRChat on 4 CPUs: EAC runtime, the launcher directory in the game's own prefix, 16 CPUs
#             mapped onto the 4, Xalia off
#   ids       the CPU list follows the CPUs the game may run on (6 CPUs with ids 2-7); 16 or more: unset
#   other     another game: the EAC variables only
#   library   the EAC runtime is found in a second Steam library; no runtime installed: no EAC variables
#   override  launch-option values win, variable by variable
#   never     no WINEDEBUG, PROTON_LOG, PROTON_NO_FSYNC or FEX_* in any case
# usage: scripts/test/steam-game-env.sh
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)/guest/layer/usr/lib/steamac
S=$R/steam-game-env; PAY=$R/proton-user-settings.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; fail() { fails=$((fails + 1)); echo "FAIL [$1]: $2"; }

ST=$T/steam; L2=$T/lib2
P1="$ST/steamapps/common/Proton - Experimental"; P2=$ST/compatibilitytools.d/Proton-custom
P3="$L2/steamapps/common/Proton 11.0"; OLD=$ST/steamapps/common/OldTool; GAME=$ST/steamapps/common/VRChat
for p in "$P1" "$P2" "$P3"; do mkdir -p "$p"; printf '#!/usr/bin/env python3\nimport user_settings\n' > "$p/proton"; done
mkdir -p "$OLD" "$GAME"; printf '#!/bin/sh\n' > "$OLD/proton"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$ST" "$L2" \
    > "$ST/steamapps/libraryfolders.vdf"
run() { # cmdline [payload]
    printf '%s\n' "$1" > "$T/cmdline"
    STEAMAC_CMDLINE=$T/cmdline STEAMAC_STEAM_ROOT=$ST STEAMAC_GAME_ENV_PAYLOAD=${2:-$PAY} bash "$S" >/dev/null 2>&1
}
snap() { (cd "$T" && find steam lib2 -type f -exec cksum {} + | sort -k3); }

# 1. install
run "console=hvc0 steamac.gfx=vulkan"
for p in "$P1" "$P2" "$P3"; do cmp -s "$PAY" "$p/user_settings.py" || fail install "no user_settings.py in $p"; done
[ -e "$OLD/user_settings.py" ] && fail install "wrote into a tool that does not read user_settings.py"
[ -e "$GAME/user_settings.py" ] && fail install "wrote into a game directory"
[ -z "$(find "$T" -name '*.steamac-tmp')" ] || fail install "temporary file left behind"

# 2. idempotent
before=$(snap); run ""; [ "$before" = "$(snap)" ] || fail again "second run changed files"

# 3. a user's own file stays
printf 'user_settings = {"DXVK_HUD": "fps"}\n' > "$P2/user_settings.py"; own=$(cksum < "$P2/user_settings.py")
run ""; [ "$own" = "$(cksum < "$P2/user_settings.py")" ] || fail own "replaced the user's user_settings.py"

# 4. a new payload replaces ours only
{ cat "$PAY"; echo "# newer"; } > "$T/new.py"
run "" "$T/new.py"
cmp -s "$T/new.py" "$P1/user_settings.py" || fail update "payload update not installed"
[ "$own" = "$(cksum < "$P2/user_settings.py")" ] || fail update "replaced the user's user_settings.py"

# 5. off removes ours only
run "steamac.game_env=0"
[ -e "$P1/user_settings.py" ] || [ -e "$P3/user_settings.py" ] && fail off "file left behind"
[ "$own" = "$(cksum < "$P2/user_settings.py")" ] || fail off "removed the user's user_settings.py"
run ""; cmp -s "$PAY" "$P1/user_settings.py" || fail off "not restored when on again"

# Environment: Proton's loop (proton, init_session): entries apply only to variables not in the environment.
EAC="$ST/steamapps/common/Proton EasyAntiCheat Runtime"; mkdir -p "$EAC/v2/lib64"
CD=$ST/steamapps/compatdata
genv() { # proton dir, then VAR=value... : prints the game's resulting environment, sorted
    local p=$1; shift
    env -i PATH="$PATH" HOME="$T/home" "$@" python3 -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
env = dict(os.environ)
import user_settings
for key, value in user_settings.user_settings.items():
    if key not in env:
        env[key] = value
for key in sorted(env):
    print("%s=%s" % (key, env[key]))' "$p"
}
has() { printf '%s\n' "$out" | grep -qxF "$1"; }
lacks() { ! printf '%s\n' "$out" | grep -q "^$1="; }
never() { printf '%s\n' "$out" | grep -Eq '^(WINEDEBUG|PROTON_LOG|PROTON_NO_FSYNC|FEX_[A-Z_]*)=' && fail never "$1 sets a debug or FEX variable"; }

# 6. VRChat, 4 CPUs
out=$(genv "$P1" SteamGameId=438100 STEAM_COMPAT_DATA_PATH="$CD/438100" STEAMAC_CPU_IDS=0,1,2,3)
has "PROTON_EAC_RUNTIME=$EAC" || fail vrchat "PROTON_EAC_RUNTIME: $(printf '%s\n' "$out" | grep EAC_RUNTIME)"
has "EAC_LAUNCHERDIR=$CD/438100/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat" || fail vrchat "EAC_LAUNCHERDIR"
has "WINE_CPU_TOPOLOGY=16:0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3" || fail vrchat "WINE_CPU_TOPOLOGY: $(printf '%s\n' "$out" | grep TOPOLOGY)"
has "PROTON_USE_XALIA=0" || fail vrchat "PROTON_USE_XALIA"
never vrchat

# 7. the CPU list is the game's own
out=$(genv "$P1" SteamGameId=438100 STEAMAC_CPU_IDS=2,3,4,5,6,7)
has "WINE_CPU_TOPOLOGY=16:2,3,4,5,6,7,2,3,4,5,6,7,2,3,4,5" || fail ids "$(printf '%s\n' "$out" | grep TOPOLOGY)"
out=$(genv "$P1" SteamGameId=438100 STEAMAC_CPU_IDS=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15)
lacks WINE_CPU_TOPOLOGY || fail ids "topology set on a 16-CPU guest"
# without the test override the value comes from the running system and is well formed
out=$(genv "$P1" SteamGameId=438100)
t=$(printf '%s\n' "$out" | sed -n 's/^WINE_CPU_TOPOLOGY=//p')
[ -z "$t" ] || printf '%s' "$t" | grep -Eq '^16:[0-9]+(,[0-9]+){15}$' || fail ids "malformed: $t"

# 8. another game
out=$(genv "$P1" SteamGameId=1167630 STEAM_COMPAT_DATA_PATH="$CD/1167630" STEAMAC_CPU_IDS=0,1,2,3)
has "PROTON_EAC_RUNTIME=$EAC" || fail other "PROTON_EAC_RUNTIME"
has "EAC_LAUNCHERDIR=$CD/1167630/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat" || fail other "EAC_LAUNCHERDIR"
lacks WINE_CPU_TOPOLOGY || fail other "topology for a game that is not in the table"
lacks PROTON_USE_XALIA || fail other "Xalia setting for a game that is not in the table"
never other

# 9. the runtime in a second library; no runtime at all
mv "$EAC" "$L2/steamapps/common/"; EAC2="$L2/steamapps/common/Proton EasyAntiCheat Runtime"
out=$(genv "$P1" SteamGameId=438100 STEAM_COMPAT_DATA_PATH="$CD/438100" STEAM_COMPAT_LIBRARY_PATHS="$ST/steamapps:$L2/steamapps")
has "PROTON_EAC_RUNTIME=$EAC2" || fail library "steamapps list: $(printf '%s\n' "$out" | grep EAC_RUNTIME)"
out=$(genv "$P1" SteamGameId=438100 STEAM_COMPAT_INSTALL_PATH="$L2/steamapps/common/VRChat")
has "PROTON_EAC_RUNTIME=$EAC2" || fail library "next to the game"
out=$(genv "$P3" SteamGameId=438100)
has "PROTON_EAC_RUNTIME=$EAC2" || fail library "next to the Proton"
rm -rf "$EAC2"
out=$(genv "$P1" SteamGameId=438100 STEAM_COMPAT_DATA_PATH="$CD/438100" STEAMAC_CPU_IDS=0,1,2,3)
lacks PROTON_EAC_RUNTIME && lacks EAC_LAUNCHERDIR || fail library "EAC variables without the runtime"
has "PROTON_USE_XALIA=0" || fail library "per-game values lost without the runtime"
never library

# 10. launch options win
mkdir -p "$ST/steamapps/common/Proton EasyAntiCheat Runtime/v2"
out=$(genv "$P1" SteamGameId=438100 STEAM_COMPAT_DATA_PATH="$CD/438100" STEAMAC_CPU_IDS=0,1,2,3 \
    WINE_CPU_TOPOLOGY=8:0,1,2,3,0,1,2,3 PROTON_USE_XALIA=1 EAC_LAUNCHERDIR=/mine PROTON_EAC_RUNTIME=/my/runtime)
has "WINE_CPU_TOPOLOGY=8:0,1,2,3,0,1,2,3" || fail override "WINE_CPU_TOPOLOGY"
has "PROTON_USE_XALIA=1" || fail override "PROTON_USE_XALIA"
has "EAC_LAUNCHERDIR=/mine" || fail override "EAC_LAUNCHERDIR"
has "PROTON_EAC_RUNTIME=/my/runtime" || fail override "PROTON_EAC_RUNTIME"
# a runtime the user points to gets the matching launcher directory
out=$(genv "$P1" SteamGameId=1 STEAM_COMPAT_DATA_PATH="$CD/1" PROTON_EAC_RUNTIME=/my/runtime)
has "EAC_LAUNCHERDIR=$CD/1/pfx/drive_c/users/steamuser/AppData/Roaming/EasyAntiCheat" || fail override "launcher directory for a user-set runtime"

echo "steam-game-env: $([ $fails = 0 ] && echo passed || echo FAILED)"
exit $((fails > 0))
