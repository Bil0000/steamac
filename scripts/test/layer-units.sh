#!/bin/bash
# SPDX-License-Identifier: MIT
# The layer's systemd units on the stock SteamOS rootfs, checked with that rootfs's own
# systemd-analyze in a chroot (stock rootfs read-only + tmpfs overlay + guest/layer/usr,
# runtime masks from masks.d as the initramfs writes them):
#   repart   home.mount still starts when Valve masks systemd-repart.service
#   prefix   a deckard-*/steamvr-* unit that masks.d does not list (system and user) does not run
# Runs privileged in the builder container (dev only, needs the cached stock rootfs):
#   docker run --rm --privileged -v "$PWD":/src:ro \
#     -v "$PWD/work/cache/rootfs/<BUILDID>/rootfs.img":/rootfs.img:ro \
#     steamac-image-builder:4 bash /src/scripts/test/layer-units.sh
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd)
fails=0; fail() { fails=$((fails + 1)); echo "FAIL [$1]: $2"; }
M=/tmp/layer-units
mkdir -p $M/lower $M/ovl $M/root
mount -o ro,loop -t btrfs /rootfs.img $M/lower
mount -t tmpfs tmpfs $M/ovl; mkdir -p $M/ovl/u $M/ovl/w
mount -t overlay overlay -o lowerdir=$M/lower,upperdir=$M/ovl/u,workdir=$M/ovl/w $M/root
cp -a "$R/guest/layer/usr/." $M/root/usr/
mount -t proc proc $M/root/proc; mount --bind /dev $M/root/dev; mount -t tmpfs tmpfs $M/root/run
mkdir -p $M/root/run/systemd/system $M/root/run/systemd/user $M/root/run/steamac $M/root/run/user/0
while read -r scope unit _; do
    case $scope in system|user) ln -sfn /dev/null "$M/root/run/systemd/$scope/$unit" ;; esac
done < "$R/guest/layer/usr/lib/steamac/masks.d/frame-hardware.list"
echo A > $M/root/run/steamac/slot
sa() { chroot $M/root env XDG_RUNTIME_DIR=/run/user/0 systemd-analyze "$@" 2>&1 | grep -v 'is marked executable'; return "${PIPESTATUS[0]}"; }

ln -sfn /dev/null $M/root/run/systemd/system/systemd-repart.service
out=$(sa verify home.mount) || fail repart "$out"
rm $M/root/run/systemd/system/systemd-repart.service

for scope in system user; do
    for unit in deckard-steamac-test.service steamvr-steamac-test.service; do
        printf '[Service]\nExecStart=/bin/true\n' > "$M/root/usr/lib/systemd/$scope/$unit"
        flag=; [ $scope = user ] && flag=--user
        out=$(sa $flag condition --unit=$unit) && fail prefix "$scope $unit would run: $out"
        rm "$M/root/usr/lib/systemd/$scope/$unit"
    done
done

[ "$fails" = 0 ] && echo "PASS layer units"
exit $((fails > 0))
