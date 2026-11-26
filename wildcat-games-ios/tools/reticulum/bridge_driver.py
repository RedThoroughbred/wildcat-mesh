#!/usr/bin/env python
# Wildcat Mesh: run the app's Reticulum bridge on the Mac, the way the app runs it.
# Copyright (C) 2026 Seth Egger. GPL-3.0-or-later.
#
# The same Reticulum/python/wildcat_reticulum code the phone runs, on the Mac venv's Python: the
# bridge's command loop on the main thread, commands read from stdin (one JSON object per line) on
# another thread, events printed to stdout as JSON lines. test_bridge.py drives it; it is also
# handy by hand:
#
#   venv/bin/python tools/reticulum/bridge_driver.py
#   {"op": "start", "storage": "/tmp/wc", "display_name": "Driver", "tcp": [{"host": "127.0.0.1", "port": 4243}]}
#   {"op": "announce"}
#
# With --fake-rnode the bridge gets a pretend RNode (fake_rnode.py) as its Bluetooth transport, and
# every setting Reticulum writes to it is printed as a "fake_rnode" event. No radio is involved.
import json
import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "Reticulum", "python"))

from wildcat_reticulum import Bridge  # noqa: E402

_print_lock = threading.Lock()


def emit(event):
    if event.get("event") == "log" and not os.environ.get("WILDCAT_DRIVER_LOGS"):
        return
    with _print_lock:
        # sys.__stdout__: Reticulum's exit handler swaps sys.stdout for /dev/null.
        sys.__stdout__.write(json.dumps(event) + "\n")
        sys.__stdout__.flush()


transport = None
if "--fake-rnode" in sys.argv:
    sys.path.insert(0, HERE)
    from fake_rnode import FakeRNode  # noqa: E402

    class ReportingRNode(FakeRNode):
        def _frame(self, cmd, payload):
            super()._frame(cmd, payload)
            if cmd != 0x00:
                emit({"event": "fake_rnode", "cmd": cmd, "value": int.from_bytes(payload, "big") if payload else None})

    transport = ReportingRNode()

bridge = Bridge(emit=emit, transport=transport)


def read_commands():
    for line in sys.stdin:
        line = line.strip()
        if line:
            bridge.submit(line)
    bridge.submit(None)


threading.Thread(target=read_commands, daemon=True).start()
bridge.run()
os._exit(0)
