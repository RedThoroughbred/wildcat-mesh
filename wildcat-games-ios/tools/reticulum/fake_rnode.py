# Wildcat Mesh: a pretend RNode for the bridge's tests on the Mac. Nothing here touches a radio.
# Copyright (C) 2026 Seth Egger. GPL-3.0-or-later.
import threading

FEND, FESC, TFEND, TFESC = 0xC0, 0xDB, 0xDC, 0xDD


def kiss(cmd, payload=b""):
    out = bytearray([FEND, cmd])
    for b in payload:
        if b == FEND:
            out += bytes([FESC, TFEND])
        elif b == FESC:
            out += bytes([FESC, TFESC])
        else:
            out.append(b)
    out.append(FEND)
    return bytes(out)


class FakeRNode:
    """A transport for WildcatPipe with an RNode on the other end: answers the host protocol the way
    RNode firmware 1.86 on a RAK4631 does (detect, version, platform, MCU, each setting echoed back)
    and keeps what the host transmitted."""

    def __init__(self):
        self.lock = threading.Lock()
        self.rx = bytearray()          # RNode -> host
        self.connected = True
        self.frames = []               # (cmd, payload) the host sent
        self.transmitted = []          # CMD_DATA payloads: packets the host put on air
        self.writes = 0
        self._buf = bytearray()
        self._in_frame = False
        self._esc = False

    # Transport interface
    def rnode_connected(self):
        return self.connected

    def rnode_available(self):
        with self.lock:
            return len(self.rx)

    def rnode_read(self, n):
        with self.lock:
            data = bytes(self.rx[:n])
            del self.rx[:n]
            return data

    def rnode_write(self, data):
        self.writes += 1
        for b in data:
            self._byte(b)
        return len(data)

    def rnode_reset(self):
        with self.lock:
            self.rx.clear()

    # The RNode
    def _byte(self, b):
        if b == FEND:
            if self._in_frame and self._buf:
                self._frame(self._buf[0], bytes(self._buf[1:]))
            self._buf = bytearray()
            self._in_frame = True
            return
        if not self._in_frame:
            return
        if self._esc:
            self._buf.append(FEND if b == TFEND else FESC if b == TFESC else b)
            self._esc = False
        elif b == FESC:
            self._esc = True
        else:
            self._buf.append(b)

    def _reply(self, data):
        with self.lock:
            self.rx += data

    def _frame(self, cmd, payload):
        self.frames.append((cmd, payload))
        if cmd == 0x08 and payload == bytes([0x73]):     # detect
            self._reply(kiss(0x08, bytes([0x46])))
        elif cmd == 0x50:                                 # firmware 1.86
            self._reply(kiss(0x50, bytes([0x01, 0x56])))
        elif cmd == 0x48:                                 # platform nRF52
            self._reply(kiss(0x48, bytes([0x70])))
        elif cmd == 0x49:                                 # MCU nRF52840
            self._reply(kiss(0x49, bytes([0x71])))
        elif cmd in (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0B, 0x0C):
            self._reply(kiss(cmd, payload))               # settings: the RNode answers with the value it now has
        elif cmd == 0x00:
            self.transmitted.append(payload)

    def hear(self, packet, rssi=-101, snr=6.5):
        """A packet arrives over the air: RSSI, SNR, then the data, as the firmware sends them."""
        self._reply(kiss(0x23, bytes([rssi + 157])) + kiss(0x24, int(snr * 4).to_bytes(1, "big", signed=True)) + kiss(0x00, packet))

    def commands(self):
        return [c for c, _ in self.frames]
