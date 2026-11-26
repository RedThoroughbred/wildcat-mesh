#!/usr/bin/env python
# Wildcat Mesh: tests for the Reticulum bridge and the RNode interface adapter, on the Mac.
# Copyright (C) 2026 Seth Egger. GPL-3.0-or-later.
#
# Runs against the official RNS 1.5.7 / LXMF 1.2.0 in the Mac venv, offline and radio-free:
#
#   /Volumes/Code-Docker/reticulum/venv/bin/python -m unittest tools/reticulum/test_bridge.py -v
#
# - the Reticulum config the bridge writes (only what was asked for, nothing shared, no transport)
# - WildcatPipe against a fake transport
# - the stock RNodeInterface, through WildcatRNodeInterface and the pipe, against a fake RNode that
#   answers the RNode host protocol: it comes online, sends packets as KISS data frames, hands
#   received ones to Reticulum, goes offline when the link drops and comes back when it returns
# - the bridge itself (in a subprocess, as the app runs it) exchanging LXMF messages with an LXMF
#   peer over loopback TCP
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PYDIR = os.path.normpath(os.path.join(HERE, "..", "..", "Reticulum", "python"))
sys.path.insert(0, PYDIR)
sys.path.insert(0, HERE)

import RNS  # noqa: E402
from RNS.vendor.configobj import ConfigObj  # noqa: E402
import wildcat_reticulum as wr  # noqa: E402
from wildcat_reticulum import check_rnode, interface_names, rns_config, rnode_pipe  # noqa: E402

from fake_rnode import FakeRNode, kiss  # noqa: E402


class Owner:
    """Stands in for RNS.Transport: what an interface hands up."""

    def __init__(self):
        self.inbound_packets = []

    def inbound(self, data, interface):
        self.inbound_packets.append(bytes(data))


def wait_for(predicate, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


class ConfigTests(unittest.TestCase):
    def test_only_the_interfaces_asked_for(self):
        text = rns_config({"loglevel": 3, "tcp": [{"name": "Mac", "host": "127.0.0.1", "port": 4243}],
                           "rnode": {"frequency": 914875000, "bandwidth": 125000, "txpower": 7,
                                     "spreadingfactor": 8, "codingrate": 5}})
        c = ConfigObj(text.splitlines())
        self.assertEqual(c["reticulum"]["share_instance"], "No")
        self.assertEqual(c["reticulum"]["enable_transport"], "No")
        self.assertEqual(sorted(c["interfaces"].keys()), ["Mac", "RNode over Bluetooth"])
        self.assertEqual(c["interfaces"]["Mac"]["type"], "TCPClientInterface")
        self.assertEqual(c["interfaces"]["Mac"]["target_port"], "4243")
        r = c["interfaces"]["RNode over Bluetooth"]
        self.assertEqual(r["type"], "WildcatRNodeInterface")
        self.assertTrue(r["port"].startswith("ble://"), "Bluetooth timings in RNodeInterface")
        self.assertEqual(r["frequency"], "914875000")
        self.assertNotIn("AutoInterface", text)

    def test_no_radio_unless_asked_and_no_injection(self):
        text = rns_config({"tcp": []})
        self.assertNotIn("WildcatRNodeInterface", text)
        self.assertEqual(list(ConfigObj(text.splitlines())["interfaces"].keys()), [])
        with self.assertRaises(ValueError):
            rns_config({"tcp": [{"host": "x\n  [[Evil]]", "port": 1}]})
        self.assertIn("[[Bad name]]", rns_config({"tcp": [{"name": "Bad [name]", "host": "h", "port": 1}]}))


    def test_names_and_radio_limits(self):
        radio = {"frequency": 914875000, "bandwidth": 125000, "txpower": 7, "spreadingfactor": 8, "codingrate": 5}
        self.assertEqual(interface_names({"tcp": [{"name": "Bad [name]", "host": "h", "port": 1}, {"host": "h", "port": 2}],
                                          "rnode": radio}), ["Bad name", "TCP 2", "RNode over Bluetooth"])
        self.assertEqual(interface_names({}), [])
        check_rnode(radio)
        for key, bad in (("frequency", 100_000_000), ("bandwidth", 5), ("txpower", 38), ("spreadingfactor", 13), ("codingrate", 4)):
            with self.assertRaises(ValueError, msg=key):
                check_rnode({**radio, key: bad})
        with self.assertRaises(ValueError):
            check_rnode({k: v for k, v in radio.items() if k != "txpower"})


class StampTests(unittest.TestCase):
    """LXMF forks to make stamps, which iOS forbids: the bridge refuses instead of trying."""

    class Router:
        def __init__(self, cost=None, ticket=None):
            self.cost, self.ticket = cost, ticket

        def get_outbound_stamp_cost(self, destination_hash):
            return self.cost

        def get_outbound_ticket(self, destination_hash):
            return self.ticket

    def test_only_ios_is_stopped_and_only_by_a_real_cost(self):
        to = bytes(16)
        self.assertFalse(wr.can_make_stamps("ios"))
        self.assertTrue(wr.can_make_stamps("darwin"))
        self.assertEqual(wr.stamp_block(self.Router(cost=8), to, platform="ios"), 8)
        self.assertIsNone(wr.stamp_block(self.Router(cost=8), to, platform="darwin"))
        self.assertIsNone(wr.stamp_block(self.Router(cost=None), to, platform="ios"))
        self.assertIsNone(wr.stamp_block(self.Router(cost=0), to, platform="ios"))
        self.assertIsNone(wr.stamp_block(self.Router(cost=8, ticket=b"t" * 16), to, platform="ios"),
                          "a ticket from the other end stands in for the stamp")

    def test_the_real_router_has_the_calls_the_check_uses(self):
        import LXMF
        self.assertTrue(callable(getattr(LXMF.LXMRouter, "get_outbound_stamp_cost", None)))
        self.assertTrue(callable(getattr(LXMF.LXMRouter, "get_outbound_ticket", None)))


class PipeTests(unittest.TestCase):
    def test_pipe_moves_bytes_and_follows_the_link(self):
        t = FakeRNode()
        t.rx += b"stale"
        p = rnode_pipe.WildcatPipe(t)
        self.assertEqual(t.rnode_available(), 0, "a new pipe drops stale bytes")
        self.assertTrue(p.is_open)
        self.assertFalse(p.in_waiting)
        t._reply(b"\xc0\x08\x46\xc0")
        self.assertTrue(p.in_waiting)
        self.assertEqual(p.read(2), b"\xc0\x08")
        self.assertEqual(p.read(10), b"\x46\xc0")
        self.assertEqual(p.write(kiss(0x08, b"\x73")), 4)
        self.assertEqual(t.frames[-1], (0x08, b"\x73"))
        t.connected = False
        self.assertFalse(p.is_open)
        self.assertEqual(p.write(b"\xc0\x00\x01\xc0"), 0, "nothing goes out on a dropped link")
        t.connected = True
        p.close()
        self.assertFalse(p.is_open, "closed stays closed")
        with self.assertRaises(IOError):
            rnode_pipe.WildcatPipe(None)


class RNodeInterfaceTests(unittest.TestCase):
    """The stock RNodeInterface through the adapter, against the fake RNode."""

    @classmethod
    def setUpClass(cls):
        # Interfaces need a Reticulum instance: a throwaway one with no interfaces of its own.
        configdir = tempfile.mkdtemp(prefix="wildcat-iface-test-")
        with open(os.path.join(configdir, "config"), "w") as f:
            f.write("[reticulum]\n  enable_transport = No\n  share_instance = No\n[logging]\n  loglevel = 1\n[interfaces]\n")
        RNS.Reticulum(configdir=configdir, loglevel=1)

    def load(self, rnode, owner):
        rnode_pipe.TRANSPORT = rnode
        # Exactly how RNS loads an external interface (Reticulum._synthesize_interface... exec).
        g = {"Interface": RNS.Interfaces.Interface.Interface, "RNS": RNS}
        with open(os.path.join(PYDIR, "WildcatRNodeInterface.py")) as f:
            exec(f.read(), g)
        cls = g["interface_class"]
        return cls(owner, {"name": "Test RNode", "port": "ble://wildcat", "frequency": 914875000, "bandwidth": 125000,
                           "txpower": 7, "spreadingfactor": 8, "codingrate": 5})

    def test_comes_online_sends_receives_and_reconnects(self):
        rnode, owner = FakeRNode(), Owner()
        iface = self.load(rnode, owner)
        self.assertTrue(wait_for(lambda: iface.online, 15), "configured and powered up through the pipe")
        self.assertEqual(str(iface), "WildcatRNodeInterface[Test RNode]")
        self.assertTrue(iface.use_ble, "RNodeInterface's Bluetooth timings")
        cmds = rnode.commands()
        for c in (0x08, 0x50, 0x48, 0x49, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06):
            self.assertIn(c, cmds, f"RNodeInterface sent 0x{c:02x}")
        self.assertEqual(rnode.frames[cmds.index(0x01)][1], (914875000).to_bytes(4, "big"))
        self.assertEqual(rnode.frames[cmds.index(0x06)][1], b"\x01", "radio on")
        self.assertAlmostEqual(iface.bitrate_kbps, 3.12, places=1)

        # Out: a Reticulum packet becomes one KISS data frame, escaped.
        packet = bytes([0x01, 0x00]) + bytes(range(16)) + b"\x00" + bytes([0xC0, 0xDB, 0x42] * 10)
        iface.process_outgoing(packet)
        self.assertTrue(wait_for(lambda: rnode.transmitted, 2))
        self.assertEqual(rnode.transmitted[-1], packet)
        self.assertEqual(iface.txb, len(packet))

        # In: what the RNode hears reaches Reticulum, with its RSSI and SNR.
        heard = bytes([0x00, 0x00]) + bytes([0xAB] * 16) + b"\x00" + b"\xC0hello\xDB"
        rnode.hear(heard, rssi=-99, snr=7.25)
        self.assertTrue(wait_for(lambda: owner.inbound_packets, 3))
        self.assertEqual(owner.inbound_packets[-1], heard)
        self.assertEqual(iface.r_stat_rssi, -99)
        self.assertEqual(iface.r_stat_snr, 7.25)

        # The Bluetooth link drops: the interface goes offline, then reconnects and reconfigures.
        detects = cmds.count(0x08)
        rnode.connected = False
        self.assertTrue(wait_for(lambda: not iface.online, 3), "offline when the link drops")
        rnode.connected = True
        self.assertTrue(wait_for(lambda: iface.online, 25), "back online once the link returns")
        self.assertGreater(rnode.commands().count(0x08), detects, "detected the RNode again")

        # Detach: radio off, then leave.
        iface.detach()
        tail = rnode.commands()[-3:]
        self.assertIn(0x0A, tail, "leave")
        self.assertIn((0x06, b"\x00"), rnode.frames[-4:], "radio off")


class BridgeRoundTripTests(unittest.TestCase):
    """The bridge as the app runs it (bridge_driver.py: command loop on the main thread), exchanging
    LXMF messages with lxmf_peer.py over loopback TCP. No radio involved."""

    PY = sys.executable

    def setUp(self):
        self.events = []
        self.lock = threading.Lock()
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            try:
                p.kill()
            except Exception:
                pass

    def spawn(self, tag, args, stdin=False):
        p = subprocess.Popen([self.PY] + args, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.procs.append(p)

        def pump():
            for line in p.stdout:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                e["_src"] = tag
                with self.lock:
                    self.events.append(e)
        threading.Thread(target=pump, daemon=True).start()
        return p

    def find(self, src, timeout, **match):
        def hit():
            with self.lock:
                for e in self.events:
                    if e["_src"] == src and all(e.get(k) == v for k, v in match.items()):
                        return e
            return None
        end = time.time() + timeout
        while time.time() < end:
            e = hit()
            if e:
                return e
            time.sleep(0.1)
        self.fail(f"no {src} event {match} in {timeout} s; saw {[(e['_src'], e.get('event')) for e in self.events]}")

    def test_announce_send_deliver_and_reply(self):
        port = 42000 + os.getpid() % 1000
        self.spawn("peer", [os.path.join(HERE, "lxmf_peer.py"), "--port", str(port), "--echo",
                            "--announce-every", "4", "--timeout", "120"])
        peer = self.find("peer", 20, event="started")
        app = self.spawn("app", [os.path.join(HERE, "bridge_driver.py")], stdin=True)

        def cmd(c):
            app.stdin.write(json.dumps(c) + "\n")
            app.stdin.flush()

        storage = tempfile.mkdtemp(prefix="wildcat-bridge-test-")
        cmd({"op": "start", "storage": storage, "display_name": "Wildcat test", "loglevel": 2, "heartbeat": True,
             "tcp": [{"name": "Mac peer", "host": "127.0.0.1", "port": port}]})
        self.find("app", 20, event="ready")
        identity = self.find("app", 20, event="identity")
        started = self.find("app", 20, event="started")
        self.assertEqual(len(identity["private_key"]), 128, "64-byte key for the Keychain")
        self.assertEqual(started["identity_hash"], identity["identity_hash"])
        self.assertEqual(started["rns"], "1.5.7")
        self.assertEqual(started["lxmf"], "1.2.0")
        self.find("app", 10, event="heartbeat")

        cmd({"op": "announce"})
        heard = self.find("peer", 20, event="announce", hash=started["address"])
        self.assertEqual(heard["name"], "Wildcat test")
        self.find("app", 20, event="announce", hash=peer["address"], name="Mac test peer")

        cmd({"op": "send", "id": "m1", "to": peer["address"], "text": "hello from the bridge"})
        self.find("app", 5, event="message", direction="out", id="m1", state="queued")
        self.find("peer", 30, event="message", text="hello from the bridge", **{"from": started["address"]})
        self.find("app", 30, event="message_state", id="m1", state="delivered")
        reply = self.find("app", 30, event="message", direction="in", text="echo: hello from the bridge")
        self.assertEqual(reply["from"], peer["address"])
        self.assertTrue(reply["signature_validated"])

        # An address nobody announced: the bridge asks for a path, then gives up and says why.
        # (Shortened: the full wait is PATH_TIMEOUT.)
        cmd({"op": "send", "id": "m2", "to": "00" * 16, "text": "anyone?"})
        self.find("app", 10, event="message_state", id="m2", state="path")

        # Stop, then start again in the same process: Reticulum stays, its interfaces come back.
        cmd({"op": "stop"})
        self.find("app", 20, event="stopped", state="stopped")
        with self.lock:
            del self.events[:]
        cmd({"op": "announce"})
        self.assertIn("isn't running", self.find("app", 10, event="error")["message"])
        cmd({"op": "start", "storage": storage, "display_name": "Wildcat test", "loglevel": 2,
             "tcp": [{"name": "Mac peer", "host": "127.0.0.1", "port": port}]})
        again = self.find("app", 20, event="started")
        self.assertEqual(again["address"], started["address"], "the same address after a restart")
        cmd({"op": "send", "id": "m3", "to": peer["address"], "text": "hello again"})
        self.find("peer", 40, event="message", text="hello again", **{"from": started["address"]})
        self.find("app", 40, event="message_state", id="m3", state="delivered")
        self.find("app", 40, event="message", direction="in", text="echo: hello again")
        cmd({"op": "start", "storage": storage, "tcp": []})
        self.assertIn("already running", self.find("app", 10, event="error", message="RuntimeError: Reticulum is already running")["message"])
        cmd({"op": "persist"})
        cmd({"op": "stop"})
        self.find("app", 20, event="stopped", state="stopped")

        # Restart with the saved key: same address.
        app.stdin.close()
        app2 = self.spawn("app2", [os.path.join(HERE, "bridge_driver.py")], stdin=True)
        app2.stdin.write(json.dumps({"op": "start", "storage": storage, "identity": identity["private_key"],
                                     "display_name": "Wildcat test", "tcp": []}) + "\n")
        app2.stdin.flush()
        again = self.find("app2", 20, event="started")
        self.assertEqual(again["address"], started["address"], "the same identity gives the same LXMF address")
        with self.lock:
            self.assertFalse([e for e in self.events if e["_src"] == "app2" and e.get("event") == "identity"],
                             "no new key when one was given")


    def test_rnode_restarts_with_new_settings(self):
        """The bridge with a pretend RNode: start, stop (radio off, leave), start on another
        frequency, and a start with settings no RNode takes is refused before Reticulum sees it."""
        app = self.spawn("app", [os.path.join(HERE, "bridge_driver.py"), "--fake-rnode"], stdin=True)

        def cmd(c):
            app.stdin.write(json.dumps(c) + "\n")
            app.stdin.flush()

        storage = tempfile.mkdtemp(prefix="wildcat-bridge-rnode-")
        radio = {"frequency": 914875000, "bandwidth": 125000, "txpower": 7, "spreadingfactor": 8, "codingrate": 5}
        name = "WildcatRNodeInterface[RNode over Bluetooth]"

        def online(e):
            return any(i["name"] == name and i["online"] for i in e.get("list", []))

        def wait_online(timeout):
            end = time.time() + timeout
            while time.time() < end:
                with self.lock:
                    if any(e["_src"] == "app" and e.get("event") == "interfaces" and online(e) for e in self.events):
                        return
                time.sleep(0.1)
            self.fail(f"the RNode interface never came online: {[e for e in self.events if e.get('event') != 'fake_rnode']}")

        cmd({"op": "start", "storage": storage, "loglevel": 2, "rnode": {**radio, "txpower": 99}})
        self.assertIn("txpower", self.find("app", 20, event="error")["message"])
        with self.lock:
            del self.events[:]

        cmd({"op": "start", "storage": storage, "loglevel": 2, "rnode": radio})
        self.assertEqual(self.find("app", 20, event="started")["rnode"], radio)
        wait_online(25)
        self.find("app", 5, event="fake_rnode", cmd=0x01, value=914875000)
        self.find("app", 5, event="fake_rnode", cmd=0x06, value=1)

        with self.lock:
            del self.events[:]
        cmd({"op": "stop"})
        self.find("app", 20, event="stopped", state="stopped")
        self.find("app", 5, event="fake_rnode", cmd=0x06, value=0)
        self.find("app", 5, event="fake_rnode", cmd=0x0A)
        self.find("app", 5, event="interfaces", list=[])

        with self.lock:
            del self.events[:]
        cmd({"op": "start", "storage": storage, "loglevel": 2, "rnode": {**radio, "frequency": 915125000, "spreadingfactor": 9}})
        self.assertEqual(self.find("app", 20, event="started")["rnode"]["frequency"], 915125000)
        wait_online(25)
        self.find("app", 5, event="fake_rnode", cmd=0x01, value=915125000)
        self.find("app", 5, event="fake_rnode", cmd=0x04, value=9)
        self.find("app", 5, event="fake_rnode", cmd=0x06, value=1)
        cmd({"op": "stop"})
        self.find("app", 20, event="stopped", state="stopped")


if __name__ == "__main__":
    unittest.main()
