#!/bin/bash
# steamac wrapper for RAUC's post-install handler (/etc/rauc/system.conf:
# post-install=/usr/lib/rauc/post-install.sh). It runs the *pristine* stock
# script of the booted slot, with one VM adaptation injected through PATH.
#
# ---------------------------------------------------------------------------
# RAUC / steamos-atomupd update flow on the Frame image, and where the VM hooks
# in (all files below are stock unless marked [steamac]):
#
#  1. steamos-atomupd-client (atomupd-daemon) picks the newest candidate for
#     variant "vr" from https://steamdeck-atomupd.steamos.cloud/meta/... using
#     /etc/steamos-atomupd/manifest.json (variant/buildid; NOT os-release, so
#     our VARIANT_ID=steamdeck rewrite does not change the update channel).
#     ensure_index_exists() symlinks /var/lib/steamos-atomupd/rootfs -> booted
#     rootfs device and (re)creates rootfs.caibx with `desync make` if needed.
#  2. `rauc install <bundle URL>` via the rauc D-Bus service, started by
#     /usr/lib/rauc/rauc-override.sh with --override-boot-slot=$(steamos-bootconf
#     this-image) (this-image = findmnt / vs /dev/disk/by-partsets/{A,B}/rootfs,
#     so the by-partsets udev symlinks from the initramfs must exist).
#     RAUC verifies the CMS signature against /etc/rauc/trusted_keys, selects
#     the non-booted slot (slot.rootfs.N device=/dev/disk/by-partsets/<X>/rootfs)
#     and calls the custom bootloader backend
#     /usr/lib/rauc/bootloader-custom-backend.sh {get-primary,get-state,...}
#     -> /usr/bin/steamos-bootconf (Frame wrapper) -> /usr/bin/splctl [steamac:
#     file-backed, esp:/steamac/bootenv]. activate-installed=false, so RAUC
#     itself does not switch the primary slot.
#  3. pre-install.sh: UUID sanity check, stop timers.
#  4. desync extract --seed /var/lib/steamos-atomupd/rootfs.caibx --in-place
#     writes the new rootfs straight into the other rootfs-X partition.
#  5. post-install.sh (stock, run by this wrapper):
#       - mounts other efi; creates SteamOS/partsets + esp:/SteamOS/conf/X.conf
#         only if missing (our image ships both pre-populated);
#       - mkfs.ext4 the other var-X (label kept), mounts new rootfs + var at
#         /mnt and runs /usr/lib/steamos/holo-sync-var all (copies /var incl.
#         the /etc overlay upper, filtered by rauc/atomic-update-keep.conf:
#         /etc/shadow, /etc/systemd/system/*.wants/** etc. survive, so our
#         steamos password and sshd enablement carry over);
#       - copies the bundle's rootfs.img.caibx as the new slot's seed;
#       - `steamos-chroot --partset X -- steamos-finalize-install --no-kernel`
#         in a chroot of the NEW, pristine rootfs (no steamac layer, no
#         bind mounts). There finalize-install would run the new slot's
#         /boot/kernelsetup.sh (UFS firmware flasher: reads rauc.slot from the
#         real /proc/cmdline - steamos-chroot binds /proc non-recursively so our
#         synthesized cmdline is not visible - and calls vrdevice_path/sgdisk
#         /dev/sdb; it fails under `set -e` in the VM and the update would be
#         rejected). [steamac] /usr/lib/steamac/rauc-shims/steamos-chroot adds
#         --no-boot-install, exactly what Valve's own
#         holo-post-update-shutdown already does for the same chroot. The
#         migration steps of finalize-install still run.
#       - `steamos-bootconf --image X set-mode reboot` -> splctl set-primary X:
#         BOOT_ORDER="X Y", BOOT_X_LEFT=3.
#  6. On shutdown holo-post-update-shutdown.service: holo-sync-var catchup +
#     chroot finalize-install --no-boot-install (stock, unaffected).
#  7. Reboot: [steamac] initramfs picks X (BOOT_X_LEFT 3 -> 2), mounts
#     rootfs-X/var-X, layer, masks; steamos-post-update.service runs once.
#     graphical.target -> steamos-boot.service -> steamos-bootconf set-mode
#     booted -> splctl set-state X good (BOOT_X_LEFT=3): update committed.
#     [steamac] On the first boot of a new BUILD_ID, steamos-boot.service.d
#     waits for Steam's UI first (boot-good-gate); no UI = not committed.
#  8. Rollback: if X never reaches graphical.target (or Steam, see 7), BOOT_X_LEFT drops 2,1,0
#     and the initramfs boots Y (BOOT_Y_LEFT was 3 from its last good boot);
#     RAUC then reports X "bad" (get-state X -> boot-attempts 1), primary stays
#     X in BOOT_ORDER but is skipped while BOOT_X_LEFT=0. The next update
#     targets X again (other of booted Y) and set-primary resets its counter.
#     A manual rollback is `steamos-bootconf set-mode reboot-other`.
# ---------------------------------------------------------------------------
set -euo pipefail

# holo-sync-var copies only the /etc files listed in atomic-update-keep.conf and
# /etc/atomic-update.conf.d/*.conf to the new slot; keep the launcher's settings.
{ mkdir -p /etc/atomic-update.conf.d && echo '/etc/steamac/**' > /etc/atomic-update.conf.d/50-steamac.conf; } \
    || echo "steamac: cannot write /etc/atomic-update.conf.d/50-steamac.conf: /etc/steamac will not carry over" >&2

root_dev=$(findmnt -n -v -o SOURCE /)
stock=$(mktemp -d /run/steamac-rauc-stock.XXXXXX)
rc=0
# Private mount namespace: the pristine rootfs mount is invisible to the rest of
# the system and disappears with this process. RAUC_* variables are inherited.
unshare --mount --propagation private /bin/bash -c '
    set -e
    mount -o ro "$1" "$2"
    PATH=/usr/lib/steamac/rauc-shims:$PATH
    export PATH
    exec "$2/usr/lib/rauc/post-install.sh"
' steamac-post-install "$root_dev" "$stock" || rc=$?
rmdir "$stock" || :
# The stock script switches the primary slot through steamos-bootconf -> splctl;
# make sure a later steamos-bootconf that no longer calls splctl still does.
case $(splctl get-current) in A) new_slot=B ;; B) new_slot=A ;; *) new_slot= ;; esac
if (( rc == 0 )) && [[ -n $new_slot ]]; then
    if [[ $(splctl get-primary) != "$new_slot" ]]; then
        echo "steamac: stock post-install left the primary slot unchanged: splctl set-primary $new_slot" >&2
        splctl set-primary "$new_slot" || rc=$?
    fi
fi
exit "$rc"
