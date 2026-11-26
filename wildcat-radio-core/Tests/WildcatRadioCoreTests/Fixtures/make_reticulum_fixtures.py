#!/usr/bin/env python
# Golden vectors for ReticulumPacket (the "Heard on air" header reader), made by the RNS library
# itself and judged by it: every packet below is built through the RNS API and then read back
# with RNS's own inbound path (`RNS.Packet(None, raw).unpack()`), and the fields RNS reads are what
# the Swift decoder must read. Hand-made byte strings (edge cases RNS won't build on its own) get
# RNS's verdict the same way. Nothing here is ported to Swift: Wildcat reads the header as the
# manual documents it, and these vectors only check that both agree.
#
# Offline: a throwaway Reticulum instance with no interfaces and no shared instance, so nothing
# is sent anywhere (no radio, no network). Writes JSON to stdout:
#
#   cd <scratch dir> && /Volumes/Code-Docker/reticulum/venv/bin/python -I \
#       <this dir>/make_reticulum_fixtures.py > <this dir>/reticulum-packets.json
#
# Identities are random, so every run makes different bytes; the tests read the JSON.
import json, os, sys, tempfile, time
import RNS

def h(b): return b.hex() if b is not None else None

cfgdir = tempfile.mkdtemp(prefix="wildcat-rns-")
with open(os.path.join(cfgdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = No\n  share_instance = No\n[logging]\n  loglevel = 0\n[interfaces]\n")
RNS.Reticulum(configdir=cfgdir, loglevel=0)

def rns_reads(raw):
    """How RNS's inbound path reads `raw`: None when it drops the packet as malformed."""
    p = RNS.Packet(None, raw)
    if not p.unpack(): return None
    return {
        "header_type": p.header_type, "context_flag": p.context_flag, "propagation": p.transport_type,
        "destination_type": p.destination_type, "packet_type": p.packet_type, "hops": p.hops,
        "transport_id": h(p.transport_id), "destination_hash": h(p.destination_hash),
        "context": p.context, "data_length": len(p.data),
    }

vectors = []
def add(name, raw, note, **extra):
    v = {"name": name, "note": note, "raw": h(raw), "length": len(raw), "rns": rns_reads(raw)}
    v.update(extra)
    vectors.append(v)

# 1. What beacon.py sends: an announce for wildcat.beacon with app data, no ratchet, header 1.
identity = RNS.Identity()
beacon = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "wildcat", "beacon")
p = beacon.announce(app_data=b"hello from the Mac #1", send=False); p.pack()
add("announce", p.raw, "beacon.py's announce: SINGLE destination, header 1, app data")

# 2. Announce with ratchets enabled (as every LXMF delivery destination does): context flag set.
rdir = tempfile.mkdtemp(prefix="wildcat-ratchets-")
rdest = RNS.Destination(RNS.Identity(), RNS.Destination.IN, RNS.Destination.SINGLE, "wildcat", "ratchet")
rdest.enable_ratchets(os.path.join(rdir, "ratchets"))
p = rdest.announce(app_data=b"with ratchet", send=False); p.pack()
add("announce_ratchet", p.raw, "announce from a destination with ratchets: the context flag is set")

# 3. The beacon's announce as a transport node passes it on: header 2, transport id, one hop.
p = beacon.announce(app_data=b"relayed", send=False)
transport_id = RNS.Identity().hash
p2 = RNS.Packet(beacon, p.data, RNS.Packet.ANNOUNCE, header_type=RNS.Packet.HEADER_2, transport_id=transport_id,
                transport_type=RNS.Transport.TRANSPORT, context_flag=p.context_flag)
p2.hops = 1
p2.pack()
add("announce_relayed", p2.raw, "relayed by a transport node: header 2 carries its transport id first")

# 4. Data to a PLAIN destination: not encrypted.
plain = RNS.Destination(None, RNS.Destination.OUT, RNS.Destination.PLAIN, "wildcat", "plain")
p = RNS.Packet(plain, b"plain text on air", create_receipt=False); p.pack()
add("data_plain", p.raw, "data to a PLAIN destination (readable payload)")

# 5. Data to a SINGLE destination: encrypted to its public key.
peer = RNS.Identity(create_keys=False); peer.load_public_key(identity.get_public_key())
single = RNS.Destination(peer, RNS.Destination.OUT, RNS.Destination.SINGLE, "wildcat", "beacon")
p = RNS.Packet(single, b"secret", create_receipt=False); p.pack()
add("data_single", p.raw, "data to a SINGLE destination (encrypted)")

# 6. A path request, built the way Transport.request_path builds one (header 1, broadcast, PLAIN
#    destination rnstransport.path.request, data = wanted destination hash + a random tag).
path_dst = RNS.Destination(None, RNS.Destination.OUT, RNS.Destination.PLAIN, RNS.Transport.APP_NAME, "path", "request")
p = RNS.Packet(path_dst, beacon.hash + RNS.Identity.get_random_hash(), packet_type=RNS.Packet.DATA,
               transport_type=RNS.Transport.BROADCAST, header_type=RNS.Packet.HEADER_1, create_receipt=False)
p.pack()
add("path_request", p.raw, "a path request for the beacon's destination")

# 7. A link request to the beacon (RNS.Link builds and tries to send it; with no interfaces it goes nowhere).
link = RNS.Link(single)
add("link_request", link.packet.raw, "a link request to the beacon's destination")
link.teardown()

# 8. A proof for the encrypted data packet (what the destination sends back to confirm delivery).
proof_target = RNS.Packet(single, b"prove me", create_receipt=False); proof_target.pack()
proof_data = proof_target.get_hash() + identity.sign(proof_target.get_hash())
proof = RNS.Packet(proof_target.generate_proof_destination(), proof_data, RNS.Packet.PROOF, create_receipt=False)
proof.pack()
add("proof", proof.raw, "a delivery proof for a data packet")

# 9. The beacon's announce on an interface with an access code (IFAC): RNS masks the header and
#    payload and inserts the code; only the flag bit stays in the clear.
class FakeInterface:
    ifac_size = 16
    ifac_identity = RNS.Identity()
    ifac_key = RNS.Cryptography.hkdf(length=64, derive_from=b"wildcat" + b"passphrase", salt=RNS.Reticulum.IFAC_SALT, context=None)
p = beacon.announce(app_data=b"behind an access code", send=False); p.pack()
masked = RNS.Transport.handle_outgoing_ifac(FakeInterface, p.raw)
add("ifac_masked", masked, "an announce behind an interface access code", ifac=True)

# Hand-made headers: the edges of the documented layout, and what RNS makes of them.
dest = bytes(range(1, 17))
tid = bytes([0xAA] * 16)
def hdr(flags, hops=0, transport=False, context=0, data=b"\x42"):
    return bytes([flags, hops]) + (tid if transport else b"") + dest + bytes([context]) + data
add("min_type1", hdr(0x00), "header 1 with a single data byte: the shortest packet")
add("no_data", hdr(0x00, data=b""), "header 1 and context, nothing after: RNS drops it")
add("hops_127", hdr(0x00, hops=127), "127 hops: still accepted")
add("hops_128", hdr(0x00, hops=128), "128 hops: RNS drops it")
add("type2_short", hdr(0x40), "header type 2 without room for both addresses")
add("type2_min", hdr(0x40, transport=True), "header type 2 with both addresses and one data byte")
add("link_proof_flags", hdr(0b0000_1111, hops=3, context=0xFF), "PROOF to a LINK destination, LRPROOF context")
add("group_path_response", hdr(0b0000_0100, context=0x0B), "data to a GROUP destination, path response context")
add("context_flag_data", hdr(0b0010_0000), "context flag set on a data packet")
add("mtu", hdr(0x08, data=bytes(500 - 19)), "500 bytes: the Reticulum MTU")
add("two_bytes", bytes([0x01, 0x00]), "two bytes")
add("empty", b"", "nothing")

out = {
    "rns_version": RNS.__version__,
    "made": int(time.time()),
    "path_request_destination": h(path_dst.hash),
    "vectors": vectors,
}
json.dump(out, sys.stdout, indent=1)
print()
