# Wildcat Mesh: the bridge between the app and the Reticulum stack.
# Copyright (C) 2026 Seth Egger. GPL-3.0-or-later (see LICENSE).
"""Runs the official, unmodified Reticulum stack (RNS) and LXMF in the app's embedded CPython and talks
to the Swift side in JSON. This is Wildcat's own glue: it uses RNS and LXMF through their public
APIs and contains none of their code.

Swift submits commands (JSON objects with an ``op``) from any thread; they run in order on the
Python main thread, the one that initialised the interpreter, because RNS and LXMF install signal
handlers when they start and Python only allows that there. Everything the bridge has to say goes
out through ``emit`` as JSON objects with an ``event``.

Commands::

    {"op": "start", "storage": "<dir>", "display_name": "...", "identity": "<128 hex>" | null,
     "loglevel": 4, "heartbeat": false, "tcp": [{"name": "...", "host": "...", "port": 4242}],
     "rnode": {"frequency": 914875000, "bandwidth": 125000, "txpower": 7,
               "spreadingfactor": 8, "codingrate": 5} | null}
    {"op": "announce"}
    {"op": "send", "id": "<local id>", "to": "<32 hex>", "text": "...", "method": "direct" | "opportunistic"}
    {"op": "stop"}
    {"op": "persist"}

Reticulum itself can only be created once in a process. So ``stop`` detaches the interfaces (an
RNode gets "radio off" and "leave") and leaves Reticulum and the LXMF router idle, and a later
``start`` writes the new config and attaches the interfaces again, with whatever radio settings it
names. Both use Reticulum's own interface management (``detach_interface``, ``attach_interface``).
The identity and the display name are those of the first start. ``persist`` saves what Reticulum
has learnt (paths, known destinations): the app sends it when it leaves the foreground, because iOS
ends an app without telling it.

Events: ready, identity (a new key for the Keychain), started, interfaces, announce, announced,
message (in and out), message_state, log, error, stopped, heartbeat.
"""
import json
import os
import queue
import shutil
import sys
import threading
import time
import traceback

from . import rnode_pipe

#: How long a send waits for a path to an unknown destination before giving up.
PATH_TIMEOUT = 20.0
#: How often the watcher reports interface and outbound message changes.
WATCH_INTERVAL = 1.0
#: The RNode's section in the Reticulum config (and so its interface's name).
RNODE_NAME = "RNode over Bluetooth"
#: With "heartbeat": true in start, an event this often: shows when Python ran and when it didn't
#: (the app suspended in the background).
HEARTBEAT_INTERVAL = 5.0

_STATE_NAMES = {
    0x00: "generating", 0x01: "outbound", 0x02: "sending", 0x04: "sent", 0x08: "delivered",
    0xFD: "rejected", 0xFE: "cancelled", 0xFF: "failed",
}


_METHOD_NAMES = {0x01: "opportunistic", 0x02: "direct", 0x03: "propagated", 0x05: "paper"}
_UNVERIFIED = {0x01: "source unknown", 0x02: "signature invalid"}


def state_name(state):
    return _STATE_NAMES.get(state, f"state {state}")


def rns_config(config):
    """The Reticulum config file for a start command: a standalone instance (no shared instance,
    no transport), only the interfaces Wildcat asked for."""
    loglevel = int(config.get("loglevel", 4))
    lines = [
        "[reticulum]",
        "  enable_transport = No",
        "  share_instance = No",
        "  panic_on_interface_error = No",
        "",
        "[logging]",
        f"  loglevel = {loglevel}",
        "",
        "[interfaces]",
    ]
    for i, t in enumerate(config.get("tcp") or []):
        name = _clean_name(t.get("name") or f"TCP {i + 1}")
        lines += [
            f"  [[{name}]]",
            "    type = TCPClientInterface",
            "    interface_enabled = Yes",
            f"    target_host = {_clean_value(str(t['host']))}",
            f"    target_port = {int(t['port'])}",
            "",
        ]
    r = config.get("rnode")
    if r:
        lines += [
            f"  [[{RNODE_NAME}]]",
            "    type = WildcatRNodeInterface",
            "    interface_enabled = Yes",
            "    port = ble://wildcat",
            f"    frequency = {int(r['frequency'])}",
            f"    bandwidth = {int(r['bandwidth'])}",
            f"    txpower = {int(r['txpower'])}",
            f"    spreadingfactor = {int(r['spreadingfactor'])}",
            f"    codingrate = {int(r['codingrate'])}",
            "",
        ]
    return "\n".join(lines) + "\n"


def interface_names(config):
    """The names of the interfaces ``rns_config`` writes for a start command, in order."""
    names = [_clean_name(t.get("name") or f"TCP {i + 1}") for i, t in enumerate(config.get("tcp") or [])]
    if config.get("rnode"):
        names.append(RNODE_NAME)
    return names


#: What an RNode's radio can be set to (the limits RNS's RNodeInterface checks before it goes
#: online). Outside them the interface never starts, so the bridge says so first.
RNODE_LIMITS = {
    "frequency": (137_000_000, 3_000_000_000),
    "bandwidth": (7_800, 1_625_000),
    "txpower": (0, 37),
    "spreadingfactor": (5, 12),
    "codingrate": (5, 8),
}


def can_make_stamps(platform=None):
    """LXMF 1.2.0 makes a stamp in one process on Windows and macOS and forks worker processes
    everywhere else. iOS (sys.platform "ios") is "everywhere else", and iOS forbids fork."""
    return (platform or sys.platform) != "ios"


def stamp_block(router, to, platform=None):
    """The stamp cost that stops a message to `to` from this platform, or None when it can go:
    stamps can be made here, the other end asks for none, or it gave this phone a ticket."""
    if can_make_stamps(platform):
        return None
    cost = router.get_outbound_stamp_cost(to)
    if not cost:
        return None
    if router.get_outbound_ticket(to) is not None:
        return None
    return cost


def check_rnode(r):
    """Raises ValueError with a plain line when a start command's radio settings can't work."""
    for key, (low, high) in RNODE_LIMITS.items():
        if key not in r:
            raise ValueError(f"The radio settings have no {key}")
        value = int(r[key])
        if not low <= value <= high:
            raise ValueError(f"The radio's {key} is {value}: it has to be between {low} and {high}")


def _clean_name(s):
    # ConfigObj section names: no brackets, no newlines.
    return "".join(c for c in s if c not in "[]\r\n") or "Interface"


def _clean_value(s):
    if any(c in s for c in "\r\n#=[]\"'"):
        raise ValueError(f"Unsafe config value: {s!r}")
    return s


class Bridge:
    def __init__(self, emit, transport=None, interface_source=None):
        """``emit(dict)`` sends an event to the app. ``transport`` is the RNode byte transport
        (see rnode_pipe). ``interface_source`` is the path of WildcatRNodeInterface.py."""
        self.emit = emit
        self.transport = transport
        self.interface_source = interface_source or os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "WildcatRNodeInterface.py")
        self.commands = queue.Queue()
        self.reticulum = None
        self.router = None
        self.identity = None
        self.delivery = None
        self.state = "idle"          # idle, starting, running, stopped (Reticulum idle, no interfaces)
        self.attached = []           # the names of the interfaces attached now
        self.display_name = None
        self.storage = None
        self.outbound = {}           # local id -> [LXMessage, last state reported]
        self.lock = threading.Lock()
        self.watcher = None
        self.last_interfaces = None
        self.last_counters = None
        self.next_counters = 0.0
        self.heartbeat = False
        # RNS announce handler: only LXMF delivery destinations (people, not nodes).
        self.aspect_filter = "lxmf.delivery"

    # MARK: Command loop

    def submit(self, command):
        """Any thread: queue a command (a JSON string or a dict) for the main loop."""
        self.commands.put(command)

    def run(self):
        """The Python main thread: run commands until a None arrives."""
        self.emit({"event": "ready", "python": sys.version.split()[0], "platform": sys.platform})
        while True:
            c = self.commands.get()
            if c is None:
                break
            self.handle(c)

    def handle(self, c):
        try:
            if isinstance(c, (str, bytes)):
                c = json.loads(c)
            op = c.get("op")
            if op == "start":
                self.start(c)
            elif op == "announce":
                self.announce()
            elif op == "send":
                self.send(c)
            elif op == "stop":
                self.stop()
            elif op == "persist":
                self.persist()
            else:
                self.emit({"event": "error", "message": f"Unknown command {op!r}"})
        except Exception as e:
            if self.state == "starting":
                # A start that failed part-way: Reticulum may exist already, so the next start attaches.
                self.state = "idle" if self.reticulum is None else "stopped"
            self.emit({"event": "error", "message": f"{type(e).__name__}: {e}", "trace": traceback.format_exc()})

    # MARK: Start and stop

    def start(self, c):
        if self.state == "stopped":
            return self.restart(c)
        if self.state != "idle":
            raise RuntimeError("Reticulum is already running")
        import RNS
        import LXMF

        storage = c["storage"]
        configdir = os.path.join(storage, "rns")
        self._write_config(configdir, c)

        # From here on RNS has started: it can't be created again in this process (see restart).
        self.state = "starting"
        self.storage = storage
        t0 = time.time()
        self.reticulum = RNS.Reticulum(configdir=configdir, loglevel=int(c.get("loglevel", 4)), logdest=self._log)
        t1 = time.time()

        key = c.get("identity")
        if key:
            self.identity = RNS.Identity.from_bytes(bytes.fromhex(key))
            if self.identity is None:
                raise ValueError("The stored identity key could not be loaded")
        else:
            self.identity = RNS.Identity()
            # The app keeps the private key (in the Keychain), never this bridge.
            self.emit({"event": "identity", "private_key": self.identity.get_private_key().hex(),
                       "identity_hash": self.identity.hash.hex()})

        self.display_name = c.get("display_name") or None
        self.router = LXMF.LXMRouter(identity=self.identity, storagepath=os.path.join(storage, "lxmf"))
        self.delivery = self.router.register_delivery_identity(self.identity, display_name=self.display_name)
        self.router.register_delivery_callback(self._delivered_to_us)
        t2 = time.time()
        self.attached = interface_names(c)
        self._run(c, {"reticulum": round((t1 - t0) * 1000), "lxmf": round((t2 - t1) * 1000)})

    def restart(self, c):
        """Start after a stop: Reticulum and the router are still there; attach the interfaces this
        start names, from a freshly written config."""
        if os.path.normpath(c["storage"]) != os.path.normpath(self.storage):
            raise RuntimeError("Reticulum is already set up with another storage folder")
        self._write_config(os.path.join(self.storage, "rns"), c)
        self.state = "starting"
        t0 = time.time()
        self.attached = []
        for name in interface_names(c):
            # True: attached. Anything else: RNS has logged why (the log events).
            if self.reticulum.attach_interface(name) is True:
                self.attached.append(name)
        self._run(c, {"reticulum": round((time.time() - t0) * 1000), "lxmf": 0})

    def _write_config(self, configdir, c):
        os.makedirs(os.path.join(configdir, "interfaces"), exist_ok=True)
        r = c.get("rnode")
        if r:
            check_rnode(r)
            if self.transport is None:
                raise RuntimeError("No Bluetooth transport for the RNode")
            rnode_pipe.TRANSPORT = self.transport
            shutil.copyfile(self.interface_source, os.path.join(configdir, "interfaces", "WildcatRNodeInterface.py"))
        with open(os.path.join(configdir, "config"), "w") as f:
            f.write(rns_config(c))

    def _run(self, c, timings):
        """Reticulum is up with its interfaces: say so, and say which interface didn't make it."""
        import RNS
        import LXMF
        RNS.Transport.register_announce_handler(self)
        self.state = "running"
        self.heartbeat = bool(c.get("heartbeat"))
        self.last_interfaces = self.last_counters = None
        self.emit({
            "event": "started",
            "address": self.delivery.hash.hex(),
            "identity_hash": self.identity.hash.hex(),
            "display_name": self.display_name,
            "rns": RNS.__version__,
            "lxmf": LXMF.__version__,
            "crypto": RNS.Cryptography.Provider.backend(),
            "python": sys.version.split()[0],
            "timings_ms": timings,
            "rnode": c.get("rnode") or None,
        })
        present = {getattr(i, "name", None) for i in list(RNS.Transport.interfaces)}
        for name in interface_names(c):
            if name not in present:
                self.attached = [n for n in self.attached if n != name]
                self.emit({"event": "error", "interface": name,
                           "message": f"{name} didn't start. The log says why."})
        self.watcher = threading.Thread(target=self._watch, daemon=True, name="wildcat-watch")
        self.watcher.start()

    def stop(self):
        if self.state != "running":
            self.emit({"event": "stopped", "state": self.state})
            return
        import RNS
        self.state = "stopped"
        if self.watcher is not None:
            self.watcher.join(timeout=WATCH_INTERVAL * 3)
        try:
            RNS.Transport.deregister_announce_handler(self)
        except Exception:
            pass
        # Close the open links first, while their interfaces can still carry the goodbye: LXMF would
        # otherwise keep using a link whose interface is gone after the next start.
        for link in list(RNS.Transport.active_links):
            try:
                link.teardown()
            except Exception:
                pass
        time.sleep(0.3)
        # Each interface detaches the way RNS detaches it at exit (an RNode gets "radio off" and
        # "leave"). Reticulum and the LXMF router stay, with nothing to talk through.
        for name in self.attached:
            try:
                self.reticulum.detach_interface(name)
            except Exception as e:
                self.emit({"event": "error", "message": f"Detaching {name}: {e}"})
        self.attached = []
        self.persist()
        self.emit({"event": "interfaces", "list": []})
        self.emit({"event": "stopped", "state": self.state})

    def persist(self):
        """Save what Reticulum and LXMF keep between runs (they do it themselves only now and then,
        and at a normal exit, which an iOS app doesn't get)."""
        if self.reticulum is None:
            return
        import RNS
        for save in (RNS.Transport.persist_data, RNS.Identity.persist_data,
                     getattr(self.router, "save_locally_delivered_transient_ids", None)):
            try:
                if save is not None:
                    save()
            except Exception as e:
                self.emit({"event": "error", "message": f"Saving Reticulum's state: {e}"})

    # MARK: Announces

    def announce(self):
        self._require_running()
        self.router.announce(self.delivery.hash)
        self.emit({"event": "announced", "address": self.delivery.hash.hex(), "at": time.time()})

    def received_announce(self, destination_hash, announced_identity, app_data):
        """RNS calls this (on its transport thread) for every lxmf.delivery announce it hears."""
        import RNS
        import LXMF
        try:
            name = LXMF.display_name_from_app_data(app_data)
        except Exception:
            name = None
        try:
            stamp_cost = LXMF.stamp_cost_from_app_data(app_data)
        except Exception:
            stamp_cost = None
        hops = RNS.Transport.hops_to(destination_hash)
        self.emit({"event": "announce", "hash": destination_hash.hex(), "name": name, "stamp_cost": stamp_cost,
                   "hops": hops if hops != RNS.Transport.PATHFINDER_M else None, "at": time.time()})

    # MARK: Messages

    def send(self, c):
        self._require_running()
        import RNS
        import LXMF
        local_id = str(c.get("id") or os.urandom(8).hex())
        text = str(c.get("text", ""))
        to = bytes.fromhex(c["to"])
        if len(to) != RNS.Reticulum.TRUNCATED_HASHLENGTH // 8:
            raise ValueError("An LXMF address is 32 hex digits")
        method = LXMF.LXMessage.OPPORTUNISTIC if c.get("method") == "opportunistic" else LXMF.LXMessage.DIRECT
        self.emit({"event": "message", "direction": "out", "id": local_id, "to": to.hex(), "text": text,
                   "method": "opportunistic" if method == LXMF.LXMessage.OPPORTUNISTIC else "direct",
                   "state": "queued", "at": time.time()})

        def go():
            identity = RNS.Identity.recall(to)
            # A path learnt before a stop points at an interface that is gone: drop it and ask again.
            stale = (identity is not None and RNS.Transport.has_path(to)
                     and RNS.Transport.next_hop_interface(to) not in RNS.Transport.interfaces)
            if stale:
                self.reticulum.drop_path(to)
            if identity is None or stale:
                RNS.Transport.request_path(to)
                self.emit({"event": "message_state", "id": local_id, "state": "path",
                           "detail": "asking the network for a path"})
                deadline = time.time() + PATH_TIMEOUT
                while (identity is None or not RNS.Transport.has_path(to)) and time.time() < deadline:
                    time.sleep(0.25)
                    identity = RNS.Identity.recall(to)
            if identity is None:
                self.emit({"event": "message_state", "id": local_id, "state": "failed", "reason": "no_path",
                           "detail": "no path: the destination hasn't announced where this phone can hear it"})
                return
            cost = stamp_block(self.router, to)
            if cost is not None:
                # Handing it to LXMF would fork a stamp worker, which iOS doesn't allow: say so instead.
                self.emit({"event": "message_state", "id": local_id, "state": "failed", "reason": "stamp",
                           "detail": "they ask for a stamp (cost %d), which this iPhone build can't make" % cost})
                return
            destination = RNS.Destination(identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            lxm = LXMF.LXMessage(destination, self.delivery, text, "", desired_method=method)
            lxm.register_delivery_callback(lambda m: self._report(local_id, m))
            lxm.register_failed_callback(lambda m: self._report(local_id, m))
            with self.lock:
                self.outbound[local_id] = [lxm, None]
            self.router.handle_outbound(lxm)
            self._report(local_id, lxm)

        threading.Thread(target=go, daemon=True, name="wildcat-send").start()

    def _report(self, local_id, lxm):
        with self.lock:
            entry = self.outbound.get(local_id)
            name = state_name(lxm.state)
            if entry is None or entry[1] == name:
                return
            entry[1] = name
        event = {"event": "message_state", "id": local_id, "state": name}
        if name in ("rejected", "cancelled"):
            event["reason"] = name
        if lxm.hash is not None:
            event["hash"] = lxm.hash.hex()
        self.emit(event)

    def _delivered_to_us(self, lxm):
        """LXMF calls this for every message delivered to this phone's address."""
        self.emit({
            "event": "message", "direction": "in",
            "hash": lxm.hash.hex() if lxm.hash else None,
            "from": lxm.source_hash.hex() if lxm.source_hash else None,
            "title": lxm.title_as_string() if lxm.title else "",
            "text": lxm.content_as_string() if lxm.content else "",
            "at": lxm.timestamp or time.time(),
            "signature_validated": bool(lxm.signature_validated),
            # Why not, when not: the sender's identity isn't known yet (no announce heard), or a bad signature.
            "unverified": _UNVERIFIED.get(lxm.unverified_reason) if not lxm.signature_validated else None,
            "method": _METHOD_NAMES.get(lxm.method, str(lxm.method)),
        })

    # MARK: Watching

    def _watch(self):
        import RNS
        next_beat = 0.0
        while self.state == "running":
            try:
                if self.heartbeat and time.time() >= next_beat:
                    next_beat = time.time() + HEARTBEAT_INTERVAL
                    self.emit({"event": "heartbeat", "at": time.time()})
                interfaces = []
                for i in list(RNS.Transport.interfaces):
                    interfaces.append({"name": str(i), "online": bool(getattr(i, "online", False)),
                                       "rxb": int(getattr(i, "rxb", 0)), "txb": int(getattr(i, "txb", 0))})
                summary = [(i["name"], i["online"]) for i in interfaces]
                counters = [(i["rxb"], i["txb"]) for i in interfaces]
                changed = summary != self.last_interfaces
                if changed or (counters != self.last_counters and time.time() >= self.next_counters):
                    self.last_interfaces, self.last_counters = summary, counters
                    self.next_counters = time.time() + 5.0
                    self.emit({"event": "interfaces", "list": interfaces})
                with self.lock:
                    pending = list(self.outbound.items())
                for local_id, (lxm, _) in pending:
                    self._report(local_id, lxm)
            except Exception as e:
                self.emit({"event": "error", "message": f"watch: {e}"})
            time.sleep(WATCH_INTERVAL)

    def _log(self, line):
        self.emit({"event": "log", "line": line})

    def _require_running(self):
        if self.state != "running":
            raise RuntimeError("Reticulum isn't running")


# MARK: The app's entry points (called from C)

_bridge = None


def main():
    """The app's Python main thread calls this after initialising the interpreter. Blocks."""
    global _bridge
    import _wildcat
    _bridge = Bridge(emit=lambda e: _wildcat.emit(json.dumps(e)), transport=_wildcat)
    _bridge.run()


def submit(command_json):
    """Any thread (the app holds the GIL while it calls this): queue a command."""
    if _bridge is None:
        raise RuntimeError("The bridge isn't running yet")
    _bridge.submit(command_json)
