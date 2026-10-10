#!/bin/bash
# lean-wrap.sh %command% : Steam launch-options wrapper for the lean graphics path. Steam passes
#   <...>/Proton - Experimental/proton waitforexitandrun <game exe> [args]
# This runs the same command with ~/vrc/lean/proton-lean/proton (DXMT + wmtr instead of DXVK) and a separate
# prefix copy (STEAM_COMPAT_DATA_PATH=~/vrc/lean/compatdata-<appid>), so the game's real prefix and Steam's
# compat-tool setting are untouched. Everything else (EAC runtime env, game args) passes through unchanged.
set -u
L=$HOME/vrc/lean
args=()
for a in "$@"; do
  case "$a" in
    */"Proton - Experimental"/proton) args+=("$L/proton-lean/proton") ;;
    *) args+=("$a") ;;
  esac
done
if [ -n "${STEAM_COMPAT_DATA_PATH:-}" ]; then
  appid=$(basename "$STEAM_COMPAT_DATA_PATH")
  # never fall back to the real prefix: without the copy (lean-cdcopy.sh) the launch stops here
  [ -d "$L/compatdata-$appid/pfx" ] || { echo "lean-wrap: no $L/compatdata-$appid" >> "$L/lean-wrap.log"; exit 1; }
  export STEAM_COMPAT_DATA_PATH="$L/compatdata-$appid"
  "$L/lean-pfx-fix.sh" "$STEAM_COMPAT_DATA_PATH/pfx"
fi
echo "lean-wrap: $(date '+%F %T') ${args[*]} (compatdata $STEAM_COMPAT_DATA_PATH)" >> "$L/lean-wrap.log"
exec "${args[@]}"
