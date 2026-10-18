#!/bin/bash
# kvmboottime.sh - measure boot-to-desktop for a PuralvOS ISO under KVM.
#
# The live image writes "PURALVOS_DESKTOP_READY <uptime>" to /dev/ttyS0 from
# an autostart entry inside the real Plasma session (see tools/build-live.sh).
# This boots the ISO with the CD throttled to a chosen throughput, which is
# the closest a KVM host can get to a USB stick: without it every measurement
# is the host's NVMe and the number says nothing about the laptop.
#
# Usage: kvmboottime.sh ISO [RUNNAME] [MB_PER_SEC] [CAP_SECONDS]
#
# Defaults: 25 MB/s (USB 2.0 in practice), 600 s cap.
set -u

ISO=${1:?usage: kvmboottime.sh ISO [RUNNAME] [MB_PER_SEC] [CAP_SECONDS]}
RUN=${2:-boottime}
MBPS=${3:-25}
CAP=${4:-600}

OUT=/tmp/opencode/kvmrun/$RUN
rm -rf "$OUT"; mkdir -p "$OUT"
SERIAL=$OUT/serial.log
QMP=$OUT/qmp.sock
PIDFILE=$OUT/qemu.pid

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "FATAL: /dev/kvm unavailable" >&2; exit 2; }
pkill -f "qemu-system-x86_64.*name $RUN" 2>/dev/null
sleep 1

BPS=$((MBPS * 1024 * 1024))
VNCD=$(( 10 + ($$ % 400) ))
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
START=$(date +%s.%N)

qemu-system-x86_64 \
	-enable-kvm -machine pc,accel=kvm -cpu host \
	-m ${KVM_MEM:-4096} -smp ${KVM_CPUS:-2} \
	-bios /usr/share/ovmf/OVMF.fd \
	-drive file="$ISO",format=raw,if=none,id=cd0,readonly=on,cache=none,throttling.bps-total=$BPS \
	-device ide-cd,drive=cd0,bootindex=1 -boot order=d \
	-vga std -device intel-hda -device hda-duplex \
	-display none -vnc 127.0.0.1:${VNCD} \
	-qmp "unix:$QMP,server=on,wait=off" \
	-serial "file:$SERIAL" \
	-pidfile "$PIDFILE" -daemonize -name "$RUN" \
	>"$OUT/qemu-stderr.log" 2>&1 || { echo "FATAL: qemu failed"; cat "$OUT/qemu-stderr.log" >&2; exit 2; }

QPID=$(cat "$PIDFILE")
echo "booting $(basename "$ISO") at ${MBPS} MB/s (plain 2 CPUs, no host cache)"

DEADLINE=$(( $(date +%s) + CAP ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
	line=$(grep -a -m1 'PURALVOS_DESKTOP_READY' "$SERIAL" 2>/dev/null || true)
	if [ -n "$line" ]; then
		END=$(date +%s.%N)
		GUEST=$(printf '%s\n' "$line" | grep -o 'PURALVOS_DESKTOP_READY [0-9.]*' | awk '{print $2}')
		READ=$(python3 - "$QMP" <<'PYEOF' 2>/dev/null || true
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
f = s.makefile("rwb")
f.write(b'{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(b'{"execute":"query-blockstats"}\n'); f.flush()
r = json.loads(f.readline())
for dev in r.get("return", []):
    st = dev.get("stats", {})
    if st.get("rd_bytes"):
        print(st["rd_bytes"]); break
PYEOF
)
		awk -v a="$START" -v b="$END" -v g="$GUEST" -v r="$READ" 'BEGIN {
			printf "wall  %.1f s  (QEMU start to desktop marker)\n", b-a
			printf "guest %.1f s  (kernel start to desktop marker)\n", g
			if (r != "") printf "read  %.0f MB  (%.1f MB/s average)\n", r/1048576, (r/1048576)/(b-a)
		}'
		kill "$QPID" 2>/dev/null
		exit 0
	fi
	if ! kill -0 "$QPID" 2>/dev/null; then
		echo "FATAL: qemu exited early"; tail -5 "$OUT/qemu-stderr.log" >&2; exit 2
	fi
	sleep 1
done

echo "FATAL: no desktop marker within ${CAP}s (see $SERIAL)" >&2
kill "$QPID" 2>/dev/null
exit 1
