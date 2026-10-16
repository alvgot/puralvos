#!/usr/bin/env python3
"""Send a key to a running VM through its QMP socket.

An ISO whose GRUB menu waits for a keypress never boots unattended. This is
the smallest thing that fixes that: talk QMP send-key to the VM and press
something.

Usage: qmp-key.py <run-dir> <qcode> [qcode ...]

    qmp-key.py /tmp/opencode/kvmrun/usbase ret
    qmp-key.py /tmp/opencode/kvmrun/usbase kp_enter
    qmp-key.py /tmp/opencode/kvmrun/usbase a b c

QCodes are the names QEMU uses, for example "ret", "esc", "spc", "a".
"""

import json
import os
import socket
import sys


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(15)
        self.sock.connect(path)
        self.buf = b""
        # The greeting arrives unprompted; read it before issuing anything.
        self._read_json()

    def _read_json(self):
        while b"\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("QMP closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\r\n", 1)
        return json.loads(line.decode("utf-8", "replace"))

    def cmd(self, execute, arguments=None):
        msg = {"execute": execute}
        if arguments:
            msg["arguments"] = arguments
        self.sock.sendall((json.dumps(msg) + "\r\n").encode())
        while True:
            reply = self._read_json()
            # Asynchronous events carry no "return" key; skip them.
            if "return" in reply or "error" in reply:
                return reply

    def close(self):
        self.sock.close()


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    run = sys.argv[1]
    keys = sys.argv[2:]
    sock_path = os.path.join(run, "qmp.sock")
    if not os.path.exists(sock_path):
        sys.stderr.write("no QMP socket at %s\n" % sock_path)
        return 1

    q = QMP(sock_path)
    q.cmd("qmp_capabilities")
    q.cmd("send-key", {"keys": [{"type": "qcode", "data": k} for k in keys]})
    q.close()
    print("sent: %s -> %s" % (" ".join(keys), sock_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
