#!/bin/bash
# KVM test harness for PuralvOS images.
#
# Boots an ISO headlessly under KVM, mirrors the serial console to a log,
# and captures periodic screenshots through the QMP screendump command, so
# the live image can be checked without a human sitting in front of it.
#
# Usage: kvmtest.sh ISO RUNNAME [BOOT_SECONDS] [SHOT_EVERY]
set -u

ISO=${1:?usage: kvmtest.sh ISO RUNNAME [BOOT_SECONDS] [SHOT_EVERY]}
RUN=${2:?usage: kvmtest.sh ISO RUNNAME [BOOT_SECONDS] [SHOT_EVERY]}
BOOT_SECONDS=${3:-300}
SHOT_EVERY=${4:-15}

OUT=/tmp/opencode/kvmrun/$RUN
rm -rf "$OUT"; mkdir -p "$OUT"
SERIAL=$OUT/serial.log
QMP_SOCK=$OUT/qmp.sock
PIDFILE=$OUT/qemu.pid

# KVM only: refuse to fall back to TCG silently, a slow emulation run would
# look like a broken image.
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
	echo "FATAL: /dev/kvm not available" >&2; exit 2
fi

# A QEMU left over from an earlier run holds the VNC socket and makes this one
# die with "Failed to find an available port". Clear them out first.
pkill -f "qemu-system-x86_64.*$RUN" 2>/dev/null
pkill -f "qemu-system-x86_64.*name $RUN" 2>/dev/null
sleep 1

# Pick a VNC display from the pid so two runs never collide.
VNCD=$(( 10 + ($$ % 400) ))

echo "=== booting $ISO as $RUN (${BOOT_SECONDS}s, shot every ${SHOT_EVERY}s, vnc :${VNCD})"

qemu-system-x86_64 \
	-enable-kvm \
	-machine pc,accel=kvm \
	-cpu host \
	-m 4096 -smp 4 \
	-bios /usr/share/ovmf/OVMF.fd \
	-drive file="$ISO",format=raw,if=none,id=cd0,readonly=on \
	-device ide-cd,drive=cd0,bootindex=1 \
	-boot order=d \
	-vga std \
	-device intel-hda -device hda-duplex \
	-device qemu-xhci,id=usb \
	-device usb-tablet \
	-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
	-display none \
	-vnc 127.0.0.1:${VNCD} \
	-qmp "unix:$QMP_SOCK,server=on,wait=off" \
	-serial "file:$SERIAL" \
	-pidfile "$PIDFILE" \
	-daemonize \
	-name "$RUN" \
	>/"$OUT/qemu-stderr.log" 2>&1

if [ ! -s "$PIDFILE" ]; then
	echo "FATAL: qemu failed to start"; cat "$OUT/qemu-stderr.log" >&2; exit 2
fi
QPID=$(cat "$PIDFILE")
echo "qemu pid $QPID"

qmp() {
	printf '%s\n' "$@" | socat - "UNIX-CONNECT:$QMP_SOCK" 2>/dev/null
}
shot() {
	printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/%s.ppm"}}\n' \
		"$OUT" "$1" | socat - "UNIX-CONNECT:$QMP_SOCK" >/dev/null 2>&1
	[ -s "$OUT/$1.ppm" ] && echo "  shot $1"
}

# wait for the qmp socket to accept commands
for _ in $(seq 1 30); do
	[ -S "$QMP_SOCK" ] && break
	sleep 0.5
done

i=0
START=$SECONDS
while [ $((SECONDS-START)) -lt "$BOOT_SECONDS" ]; do
	if [ $((i % SHOT_EVERY)) -eq 0 ]; then
		shot "$(printf 't%03d' $((i/SHOT_EVERY)))"
	fi
	i=$((i+1))
	if ! kill -0 "$QPID" 2>/dev/null; then
		echo "qemu exited after $i s"; break
	fi
	sleep 1
done

shot final
kill "$QPID" 2>/dev/null
sleep 1
kill -9 "$QPID" 2>/dev/null
echo "=== done: $OUT"
