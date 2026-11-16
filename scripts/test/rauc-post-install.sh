#!/bin/bash
# SPDX-License-Identifier: MIT
# guest/layer/usr/lib/rauc/post-install.sh (RAUC post-install wrapper) around a fake stock script:
#   keep     /etc/atomic-update.conf.d/50-steamac.conf lists /etc/steamac/** before the stock script runs
#   primary  the stock script exits 0 but leaves the booted slot primary: the wrapper sets the other;
#            with no booted slot known (get-current empty) it changes nothing; the other slot
#            already primary but with no boot tries left (after a rollback) gets set-primary again
#   shim     a stock script without "steamos-chroot ... -- steamos-finalize-install" gets one error
#            line and still runs; with the call, no error line
# Runs as root in a throwaway Linux container (writes /etc/atomic-update.conf.d):
#   docker run --rm -v "$PWD":/src:ro steamac-image-builder:4 bash /src/scripts/test/rauc-post-install.sh
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
W=$R/guest/layer/usr/lib/rauc/post-install.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; fail() { fails=$((fails + 1)); echo "FAIL [$1]: $2"; }
mkdir -p "$T/bin" "$T/stock/usr/lib/rauc"
printf '#!/bin/sh\necho /dev/fake-root\n' > "$T/bin/findmnt"
printf '#!/bin/sh\nwhile [ "$1" != private ]; do shift; done; shift; exec "$@"\n' > "$T/bin/unshare"
printf '#!/bin/sh\nfor a; do d=$a; done; cp -a %q/stock/. "$d"\n' "$T" > "$T/bin/mount"
cat > "$T/bin/splctl" <<SPL
#!/bin/sh
case \$1 in
    get-current) cat $T/current ;;
    get-primary) cat $T/primary ;;
    get-state) cat $T/state ;;
    set-primary) echo "\$2" > $T/primary; echo good > $T/state ;;
esac
SPL
echo A > "$T/primary"; echo A > "$T/current"; echo good > "$T/state"
cat > "$T/stock/usr/lib/rauc/post-install.sh" <<STOCK
#!/bin/bash
cat /etc/atomic-update.conf.d/50-steamac.conf > $T/keep-seen 2>/dev/null
exit 0
steamos-chroot --partset \$UPDATED_SLOT -- steamos-finalize-install --no-kernel
STOCK
chmod +x "$T"/bin/* "$T/stock/usr/lib/rauc/post-install.sh"
run() { PATH=$T/bin:$PATH bash "$W" > "$T/out" 2>&1; }

rm -f /etc/atomic-update.conf.d/50-steamac.conf
run || fail keep "exit $?: $(cat "$T/out")"
[ "$(cat "$T/keep-seen" 2>/dev/null)" = '/etc/steamac/**' ] || fail keep "stock script saw: $(cat "$T/keep-seen" 2>/dev/null)"
[ "$(cat "$T/primary")" = B ] || fail primary "primary slot $(cat "$T/primary")"
: > "$T/current"
run || fail primary "exit $?"
[ "$(cat "$T/primary")" = B ] || fail primary "unknown booted slot: primary set to $(cat "$T/primary")"
echo A > "$T/current"; echo bad > "$T/state"
run || fail primary "exit $?"
[ "$(cat "$T/state")" = good ] || fail primary "slot B primary with no boot tries left after post-install"
echo A > "$T/current"
grep -q ERROR "$T/out" && fail shim "error line with the call present: $(cat "$T/out")"
sed -i '$d' "$T/stock/usr/lib/rauc/post-install.sh"
rm -f "$T/keep-seen"
run || fail shim "exit $?"
[ -e "$T/keep-seen" ] || fail shim "stock script did not run"
[ "$(grep -c 'ERROR: stock post-install.sh has no' "$T/out")" = 1 ] || fail shim "no error line: $(cat "$T/out")"

[ "$fails" = 0 ] && echo "PASS rauc post-install wrapper"
exit $((fails > 0))
