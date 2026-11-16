#!/bin/sh
# SPDX-License-Identifier: MIT
# Checks that a plain `open` of the app starts the DXMT setting saved in Settings (Advanced > Allow DXMT):
# for each value, write it to the app's defaults, open the app with --selftest-graphics-path only, and expect
# its PASS line naming that path. The previously saved value is restored afterwards.
# usage: scripts/test/graphics-path.sh [APP]   default: work/out/FX Steam Launcher.app
APP=${1:-"work/out/FX Steam Launcher.app"}
DOM=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") || exit 1
old=$(defaults read "$DOM" wmtr 2>/dev/null)
out=$(mktemp); fail=0
for g in dxmt vulkan; do
  if [ "$g" = dxmt ]; then defaults write "$DOM" wmtr -bool true; else defaults write "$DOM" wmtr -bool false; fi
  open -W -n --stderr "$out" --stdout "$out" "$APP" --args --selftest-graphics-path
  if grep -q "selftest-graphics-path: resolved $g," "$out" && grep -q 'selftest-graphics-path: PASS' "$out"; then
    echo "ok   $g"
  elif [ "$g" = dxmt ] && grep -q 'resolved vulkan' "$out" && ! [ -f "$APP/Contents/Frameworks/libwmtr_host.dylib" ]; then
    echo "ok   $g (not in this build: Vulkan used)"
  else
    echo "FAIL $g: $(grep selftest-graphics-path "$out" | tr '\n' '|')"; fail=1
  fi
done
if [ -n "$old" ]; then defaults write "$DOM" wmtr -bool "$old"; else defaults delete "$DOM" wmtr 2>/dev/null; fi
rm -f "$out"
exit $fail
