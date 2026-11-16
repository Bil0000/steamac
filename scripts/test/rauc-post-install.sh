#!/bin/bash
# SPDX-License-Identifier: MIT
# guest/layer/usr/lib/rauc/post-install.sh (RAUC post-install wrapper) around a fake stock script:
#   keep     /etc/atomic-update.conf.d/50-steamac.conf lists /etc/steamac/** before the stock script runs
#   primary  the stock script exits 0 but leaves the booted slot primary: the wrapper sets the other;
#            with no booted slot known (get-current empty) it changes nothing
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
    set-primary) echo "\$2" > $T/primary ;;
esac
SPL
echo A > "$T/primary"; echo A > "$T/current"
cat > "$T/stock/usr/lib/rauc/post-install.sh" <<STOCK
#!/bin/bash
cat /etc/atomic-update.conf.d/50-steamac.conf > $T/keep-seen 2>/dev/null
exit 0
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
echo A > "$T/current"

[ "$fails" = 0 ] && echo "PASS rauc post-install wrapper"
exit $((fails > 0))
