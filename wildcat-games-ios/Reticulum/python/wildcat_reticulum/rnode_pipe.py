# Wildcat Mesh: the byte stream between Reticulum's RNodeInterface and the phone's Bluetooth link.
# Copyright (C) 2026 Seth Egger. GPL-3.0-or-later (see LICENSE). Wildcat's own glue: it contains no
# Reticulum code and uses RNS only through RNodeInterface's serial-like connection object.
"""RNS's RNodeInterface (official, unmodified) reads and writes an RNode through a serial-like
object: ``is_open``, ``in_waiting``, ``read(n)``, ``write(data)``, ``close()``. Over Bluetooth it
uses its own ``BLEConnection`` (bleak), which can't run on iOS. ``WildcatPipe`` takes that object's
place and moves the bytes through the app's CoreBluetooth link to the RNode (Swift ``RNodeLink``),
by way of a *transport*: the ``_wildcat`` module the app builds into Python, or a fake RNode in tests.

A transport has five functions::

    rnode_connected() -> bool     # the Bluetooth link is up and handed to Reticulum
    rnode_available() -> int      # bytes from the RNode waiting to be read
    rnode_read(n) -> bytes        # up to n of them
    rnode_write(data) -> int      # bytes to the RNode; returns how many were taken
    rnode_reset() -> None         # drop anything stale (a new connection begins)
"""

#: The transport for new pipes. The bridge sets it before Reticulum starts (tests set a fake).
TRANSPORT = None


class WildcatPipe:
    """Stands in for RNS's BLEConnection: the attributes and methods RNodeInterface uses on it."""

    #: How long RNodeInterface's open_port waits for the link (the same as BLEConnection's).
    CONNECT_TIMEOUT = 5.0

    def __init__(self, transport):
        if transport is None:
            raise IOError("No RNode transport: the app hasn't attached its Bluetooth link")
        self.transport = transport
        # BLEConnection's state flags, read by RNodeInterface.
        self.running = True
        self.should_run = True
        self.must_disconnect = False
        self.device_disappeared = False
        self.connect_job_running = False
        transport.rnode_reset()

    @property
    def connected(self):
        return self.should_run and not self.must_disconnect and bool(self.transport.rnode_connected())

    @property
    def is_open(self):
        return self.connected

    @property
    def in_waiting(self):
        return self.transport.rnode_available() > 0

    def read(self, n):
        return self.transport.rnode_read(n)

    def write(self, data):
        if not self.connected:
            return 0
        return self.transport.rnode_write(bytes(data))

    def close(self):
        self.must_disconnect = True

    def cleanup(self):
        self.should_run = False
        self.running = False
