#!/bin/bash
# lean-launchopts.sh on|off|show [APPID]: add/remove ~/vrc/lean/lean-wrap.sh in front of %command% in the
# game's Steam launch options (every user's localconfig.vdf), leaving every other option byte-identical.
# Steam must not be running (it rewrites localconfig.vdf on exit): this script stops the gamescope session,
# waits for Steam to exit, edits, and starts the session again. A one-time backup is kept
# (localconfig.vdf.bak-lean); "off" removes exactly the inserted token and checks the result against it.
set -u
ACT=$1; APP=${2:-438100}; WRAP="$HOME/vrc/lean/lean-wrap.sh "
edit() { python3 "$(dirname "$0")/lean-vdfopts.py" "$1" "$ACT" "$APP" "$WRAP"; }
CFS=$(ls "$HOME"/.local/share/Steam/userdata/*/config/localconfig.vdf)
if [ "$ACT" = show ]; then for c in $CFS; do edit "$c"; done; exit 0; fi
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
systemctl --user stop gamescope-session.target
for _ in $(seq 1 60); do pgrep -x steam >/dev/null || break; sleep 1; done
pgrep -x steam >/dev/null && { echo "Steam still running; not editing"; systemctl --user start gamescope-session.target; exit 1; }
rc=0
for c in $CFS; do
  [ -f "$c.bak-lean" ] || cp -p "$c" "$c.bak-lean"
  edit "$c" || rc=1
  if [ "$ACT" = off ]; then
    a=$(ACT=show; edit "$c.bak-lean"); b=$(ACT=show; edit "$c")
    [ "$a" = "$b" ] && echo "restored: identical to the backup's launch options" || { echo "MISMATCH vs backup"; rc=1; }
  fi
done
systemctl --user start gamescope-session.target
exit $rc
