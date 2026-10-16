#!/bin/bash
# Interactive KVM session for a dyne:bolic live image.
#
# Boots the ISO under KVM with the serial console on a UNIX socket, so the
# guest can actually be talked to from the host. Used together with the
# hidden "serial shell" GRUB entry in iso/grub.cfg.
#
# Usage: kvmconsole.sh ISO RUNNAME [BOOT_SECONDS]
set -u

ISO=${1:?usage: kvmconsole.sh ISO RUNNAME [BOOT_SECONDS]}
RUN=${2:?usage: kvmconsole.sh ISO RUNNAME [BOOT_SECONDS]}
BOOT_SECONDS=${3:-1800}

OUT=/tmp/opencode/kvmrun/$RUN
rm -rf "$OUT"; mkdir -p "$OUT"
SOCK=$OUT/serial.sock
LOG=$OUT/serial.log
QMP_SOCK=$OUT/qmp.sock
PIDFILE=$OUT/qemu.pid

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
	echo "FATAL: /dev/kvm not available" >&2; exit 2
fi

VNCD=$(( 10 + ($$ % 400) ))
echo "=== booting $ISO as $RUN (vnc :${VNCD}, serial on $SOCK)"

qemu-system-x86_64 \
	-enable-kvm -machine pc,accel=kvm -cpu host \
	-m 4096 -smp 4 \
	-bios /usr/share/ovmf/OVMF.fd \
	-drive file="$ISO",format=raw,if=none,id=cd0,readonly=on \
	-device ide-cd,drive=cd0,bootindex=1 \
	-boot order=d -vga std \
	-device intel-hda -device hda-duplex \
	-device qemu-xhci,id=usb -device usb-tablet \
	-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
	-display none -vnc 127.0.0.1:${VNCD} \
	-qmp "unix:$QMP_SOCK,server=on,wait=off" \
	-serial "unix:$SOCK,server=on,wait=off" \
	-pidfile "$PIDFILE" -daemonize -name "$RUN" \
	>"$OUT/qemu-stderr.log" 2>&1

[ -s "$PIDFILE" ] || { echo "FATAL: qemu failed"; cat "$OUT/qemu-stderr.log" >&2; exit 2; }
QPID=$(cat "$PIDFILE")
echo "qemu pid $QPID"
echo "$QPID" > /tmp/opencode/kvmrun/.$RUN.pid

# One long-lived relay keeps the socket open and mirrors everything to the log,
# so the session can be both watched and typed into.
nohup socat -u UNIX-CONNECT:"$SOCK" - >> "$LOG" 2>/dev/null &
echo "relay started; log: $LOG"

for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 0.5; done

# helper used by the caller
cat > "$OUT/send.sh" <<EOF
#!/bin/bash
# send a line to the guest serial console and show what comes back
printf '%s\n' "\$1" | timeout 5 socat - "UNIX-CONNECT:$SOCK" 2>/dev/null
EOF
chmod +x "$OUT/send.sh"

sleep "$BOOT_SECONDS"
echo "=== session finished: $OUT"
