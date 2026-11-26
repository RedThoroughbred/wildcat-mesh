# Wildcat Mesh: Reticulum's RNode interface over the phone's own Bluetooth link.
# Copyright (C) 2026 Seth Egger. GPL-3.0-or-later (see LICENSE). Wildcat's own glue.
#
# RNS loads this file from <configdir>/interfaces/ through its custom interface mechanism
# (`type = WildcatRNodeInterface` in the config) and calls `interface_class(owner, config)`.
#
# It is the stock RNS RNodeInterface, unmodified, with one thing swapped: where it would open a
# serial port, a TCP socket or a bleak Bluetooth connection, it opens a WildcatPipe to the app's
# CoreBluetooth link instead. Detecting the RNode, checking its firmware, setting and validating
# the radio, airtime limits, the KISS read loop and reconnecting all stay RNodeInterface's own.
#
# The config's port is `ble://...`, so RNodeInterface uses its Bluetooth timings (5 s to detect,
# 2 s after setting the radio, 1 s before validating it) and calls close()/cleanup() on the pipe
# when it detaches.
import time

from RNS.Interfaces.RNodeInterface import RNodeInterface
from wildcat_reticulum import rnode_pipe


class WildcatRNodeInterface(RNodeInterface):
    def open_port(self):
        # RNodeInterface's own BLE path sets this read timeout for partial frames; Bluetooth
        # notifications can split a KISS frame with a gap between the halves.
        self.timeout = 1250
        # A fresh pipe on every open: after a dropped link, RNodeInterface's reconnect loop calls
        # open_port again and must not find the old, closed one.
        self.ble = rnode_pipe.WildcatPipe(rnode_pipe.TRANSPORT)
        self.serial = self.ble
        deadline = time.time() + self.ble.CONNECT_TIMEOUT
        while not self.ble.connected and time.time() < deadline:
            time.sleep(0.25)

    def __str__(self):
        return f"WildcatRNodeInterface[{self.name}]"


interface_class = WildcatRNodeInterface
