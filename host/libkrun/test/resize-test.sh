#!/bin/sh
# Live display resize check on a clone of the guest disk (needs host/libkrun/build.sh output
# and the work/out guest images). Boots the guest headless with test/resize.c, waits for the
# Steam UI, then walks through display sizes at a constant 96 DPI (krun_display_resize)
# and records for each: the guest connector modes, the X screen size gamescope gives
# Steam (xrandr), gamescope's mode switches, and a frame dump.
#
#   host/libkrun/test/resize-test.sh [OUTDIR]   (default work/scratch/resize-test)
#
# A size may end in @HZ (1600x1000@120): krun_display_set_mode with that refresh rate.
#
# Env: SSH_PORT (default 2230), SIZES ("1600x1000 1024x640"), BOOT_WAIT (s, default 600),
# SETTLE (s after each resize, default 45: the Steam UI may restart its GPU process on a
# mode change), KEEP_CLONE=1 keeps the cloned disk.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=$root/work/out
dir=${1:-$root/work/scratch/resize-test}
port=${SSH_PORT:-2230}
sizes=${SIZES:-1600x1000 1024x640}
boot_wait=${BOOT_WAIT:-600}
settle=${SETTLE:-45}

mkdir -p "$dir"
run=$(mktemp -d /tmp/krun-resize.XXXXXX)
clone=$dir/steamos.img
bin=$root/work/build/host-libkrun/resize

clang -std=c11 -Wall -Wextra -Werror -o "$bin" "$here/resize.c" \
	-I"$out/host/include" -L"$out/host/lib" -lkrun -Wl,-rpath,"$out/host/lib" \
	-framework CoreFoundation -framework CoreGraphics -framework ImageIO
codesign --force -s - --entitlements "$here/hypervisor.entitlements" "$bin"

rm -f "$clone"
cp -c "$out/steamos.img" "$clone"

vm_pid=
gv_pid=
cleanup() {
	[ -n "$vm_pid" ] && kill "$vm_pid" 2> /dev/null || true
	[ -n "$gv_pid" ] && kill "$gv_pid" 2> /dev/null || true
	wait 2> /dev/null || true
	rm -rf "$run"
	[ "${KEEP_CLONE:-0}" = 1 ] || rm -f "$clone"
}
trap cleanup EXIT INT TERM

"$out/host/bin/gvproxy" -listen-vfkit "unixgram://$run/net.sock" -listen "unix://$run/api.sock" \
	-ssh-port "$port" -log-file "$run/gvproxy.log" > /dev/null 2>&1 &
gv_pid=$!
while [ ! -S "$run/net.sock" ]; do sleep 0.1; done

mkfifo "$run/control"
: > "$dir/console.log"
"$bin" --kernel "$out/Image" --initrd "$out/initramfs.cpio.gz" \
	--disk "$clone" --disk "$out/steamac-layer.img:ro" --net "$run/net.sock" \
	--console "$dir/console.log" --control "$run/control" --size 1280x800 --mm 339x212 \
	2> "$dir/harness.log" &
vm_pid=$!
exec 3> "$run/control"

g() {
	sshpass -p steamos ssh -q -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=5 steamos@127.0.0.1 "$@"
}

# One guest query for the report; a failure (e.g. Steam restarting) is noted, not fatal.
q() {
	g "$1" || echo "(failed: $?)"
}

report() { # label
	{
		echo "=== $1"
		echo "--- /sys/class/drm/card0-Virtual-1/modes (first 3)"
		q 'head -3 /sys/class/drm/card0-Virtual-1/modes'
		echo "--- preferred mode refresh (EDID detailed timing, Hz)"
		q 'od -An -w18 -tu1 -j54 -N18 /sys/class/drm/card0-Virtual-1/edid |
			awk "{c=(\$1+\$2*256)*10000; w=\$3+int(\$5/16)*256; hb=\$4+(\$5%16)*256; h=\$6+int(\$8/16)*256; vb=\$7+(\$8%16)*256; printf \"%.1f\n\", c/((w+hb)*(h+vb))}"'
		# Steam's X display is gamescope's first Xwayland (:0, no access control).
		echo "--- xrandr (DISPLAY=:0)"
		q 'DISPLAY=:0 xrandr --current 2>&1 | head -4'
		echo "--- gamescope mode selection"
		q 'echo steamos | sudo -S -p "" journalctl -b --no-pager -o short-monotonic 2>/dev/null |
			grep -E "drm: (selecting mode|selecting connector)|Got change event for KMS" | tail -6'
		echo "--- Steam UI scale (last webhelper ThreadSetForceDeviceScaleFactors)"
		q 'grep ThreadSetForceDeviceScaleFactors ~/.local/share/Steam/logs/webhelper.txt | tail -1'
	} >> "$dir/report.txt" 2>&1
	echo "dump $dir/$1.png" >&3
	sleep 2
}

# Frames the display backend presented so far (dumps report the count).
frames() {
	echo "dump $run/probe.png" >&3
	sleep 1
	sed -n 's/.*frame #\([0-9]*\).*/\1/p' "$dir/harness.log" | tail -1
}

echo "waiting for the Steam UI (up to ${boot_wait}s)"
t=0
until [ "$(frames)" -ge 300 ] 2> /dev/null &&
	g 'pgrep -u steamos -f steamwebhelper > /dev/null' 2> /dev/null; do
	sleep 10
	t=$((t + 11))
	kill -0 "$vm_pid" || { echo "VM exited"; exit 1; }
	[ "$t" -lt "$boot_wait" ] || { echo "no Steam UI after ${boot_wait}s"; exit 1; }
done
sleep 30 # Steam UI load
: > "$dir/report.txt"
report 1280x800

for s in $sizes; do
	hz=${s#*@}
	[ "$hz" = "$s" ] && hz=
	s=${s%@*}
	w=${s%x*} h=${s#*x}
	# constant DPI: 96 px per inch
	wmm=$(((w * 254 + 480) / 960)) hmm=$(((h * 254 + 480) / 960))
	if [ -n "$hz" ]; then
		echo "mode $w $h $wmm $hmm $hz" >&3
		s=$s@$hz
	else
		echo "resize $w $h $wmm $hmm" >&3
	fi
	sleep "$settle"
	report "$s"
done

cat "$dir/report.txt"
grep -E "configure_scanout|krun_display_resize|krun_display_set_mode|dump" "$dir/harness.log"
g 'echo steamos | sudo -S -p "" systemctl poweroff' > /dev/null 2>&1 || true
for _ in $(seq 60); do kill -0 "$vm_pid" 2> /dev/null || break; sleep 1; done
