#!/usr/bin/env python
# Wildcat Mesh: a throwaway LXMF peer on the Mac for testing the Reticulum spike without a radio.
# Copyright (C) 2026 Seth Egger. GPL-3.0-or-later.
#
# Runs the official RNS + LXMF (the Mac venv) as a standalone instance in its own config directory,
# with ONE interface: a TCP server on 127.0.0.1 (loopback only). No AutoInterface, no RNode, no
# shared instance, so nothing goes out on the LAN or over LoRa and Seth's ~/.reticulum is untouched.
# The iPhone Simulator reaches it at 127.0.0.1:<port> (the simulator shares the Mac's loopback).
#
#   /Volumes/Code-Docker/reticulum/venv/bin/python tools/reticulum/lxmf_peer.py --port 4243 --echo
#
# Prints one JSON object per line: started (its LXMF address), announce (heard), message (received),
# sent / delivered / failed (its own messages). With --echo it answers every message with
# "echo: <text>". With --send-to <address> it sends --text to that address once it is reachable.
import argparse
import json
import os
import shutil
import sys
import tempfile
import threading
import time

import RNS
import LXMF


def out(**event):
    event.setdefault("at", round(time.time(), 3))
    print(json.dumps(event), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4243)
    ap.add_argument("--listen", default="127.0.0.1",
                    help="the address to listen on; this Mac's Wi-Fi address lets a real phone on the same network reach it "
                         "(the internet link test). Default: loopback only")
    ap.add_argument("--name", default="Mac test peer")
    ap.add_argument("--echo", action="store_true", help="answer every message with 'echo: <text>'")
    ap.add_argument("--announce-every", type=float, default=30.0)
    ap.add_argument("--send-to", help="an LXMF address to send --text to once it is known")
    ap.add_argument("--text", default="hello from the Mac test peer")
    ap.add_argument("--method", choices=["direct", "opportunistic"], default="direct")
    ap.add_argument("--send-every", type=float, default=0,
                    help="send 'tick N' to the last LXMF address that announced, every this many seconds")
    ap.add_argument("--timeout", type=float, default=0, help="exit after this many seconds (0 = run until Ctrl-C)")
    ap.add_argument("--configdir", help="keep state here (default: a fresh temporary directory)")
    ap.add_argument("--use-config", metavar="DIR",
                    help="run an existing Reticulum config dir AS IS instead of the loopback-only one (e.g. "
                         "/Volumes/Code-Docker/reticulum/rnode2 for the Mac's RNode: THAT TRANSMITS over LoRa). "
                         "Its config file is never written; LXMF state goes in DIR/wildcat-lxmf-peer.")
    ap.add_argument("--loglevel", type=int, default=2)
    args = ap.parse_args()

    if args.use_config:
        configdir = args.use_config
        if not os.path.isfile(os.path.join(configdir, "config")):
            sys.exit(f"no Reticulum config in {configdir}")
        lxmf_storage = os.path.join(configdir, "wildcat-lxmf-peer")
    else:
        configdir = args.configdir or tempfile.mkdtemp(prefix="wildcat-lxmf-peer-")
        os.makedirs(configdir, exist_ok=True)
        with open(os.path.join(configdir, "config"), "w") as f:
            f.write("[reticulum]\n  enable_transport = No\n  share_instance = No\n  panic_on_interface_error = No\n"
                    f"[logging]\n  loglevel = {args.loglevel}\n"
                    "[interfaces]\n"
                    "  [[Loopback TCP server]]\n    type = TCPServerInterface\n    interface_enabled = Yes\n"
                    f"    listen_ip = {args.listen}\n    listen_port = {args.port}\n")
        lxmf_storage = os.path.join(configdir, "lxmf")

    RNS.Reticulum(configdir=configdir, loglevel=args.loglevel)
    identity = RNS.Identity()
    router = LXMF.LXMRouter(identity=identity, storagepath=lxmf_storage)
    me = router.register_delivery_identity(identity, display_name=args.name)
    out(event="started", address=me.hash.hex(), name=args.name, port=args.port,
        rns=RNS.__version__, lxmf=LXMF.__version__, crypto=RNS.Cryptography.Provider.backend())

    def send(to_hash, text):
        identity = RNS.Identity.recall(to_hash)
        if identity is None:
            RNS.Transport.request_path(to_hash)
            deadline = time.time() + 20
            while identity is None and time.time() < deadline:
                time.sleep(0.25)
                identity = RNS.Identity.recall(to_hash)
        if identity is None:
            out(event="failed", to=to_hash.hex(), text=text, reason="no path")
            return
        dest = RNS.Destination(identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
        method = LXMF.LXMessage.OPPORTUNISTIC if args.method == "opportunistic" else LXMF.LXMessage.DIRECT
        m = LXMF.LXMessage(dest, me, text, "", desired_method=method)
        m.register_delivery_callback(lambda m: out(event="delivered", to=to_hash.hex(), text=text))
        m.register_failed_callback(lambda m: out(event="failed", to=to_hash.hex(), text=text, reason="lxmf"))
        router.handle_outbound(m)
        out(event="sent", to=to_hash.hex(), text=text, method=args.method)

    def received(m):
        text = m.content_as_string()
        out(event="message", **{"from": m.source_hash.hex()}, text=text, signature_validated=bool(m.signature_validated))
        if args.echo:
            threading.Thread(target=send, args=(m.source_hash, f"echo: {text}"), daemon=True).start()

    router.register_delivery_callback(received)

    sent_to = set()
    last_announcer = []

    class Announces:
        aspect_filter = "lxmf.delivery"

        def received_announce(self, destination_hash, announced_identity, app_data):
            out(event="announce", hash=destination_hash.hex(), name=LXMF.display_name_from_app_data(app_data),
                hops=RNS.Transport.hops_to(destination_hash))
            last_announcer[:] = [destination_hash]
            if args.send_to and destination_hash.hex() == args.send_to and args.send_to not in sent_to:
                sent_to.add(args.send_to)
                threading.Thread(target=send, args=(destination_hash, args.text), daemon=True).start()

    RNS.Transport.register_announce_handler(Announces())

    started = time.time()
    next_announce = started + 2
    next_tick, tick = started + args.send_every, 0
    try:
        while args.timeout <= 0 or time.time() - started < args.timeout:
            if time.time() >= next_announce:
                router.announce(me.hash)
                out(event="announced", address=me.hash.hex())
                next_announce = time.time() + args.announce_every
            if args.send_every > 0 and last_announcer and time.time() >= next_tick:
                tick += 1
                next_tick = time.time() + args.send_every
                threading.Thread(target=send, args=(last_announcer[0], f"tick {tick}"), daemon=True).start()
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    out(event="exiting")
    if not args.configdir and not args.use_config:
        shutil.rmtree(configdir, ignore_errors=True)
    os._exit(0)


if __name__ == "__main__":
    main()
