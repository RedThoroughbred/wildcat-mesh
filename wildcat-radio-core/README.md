# WildcatRadioCore

The native Swift core of the Wildcat Games iPhone app (the "Radio Core" in
`wildcat-games/ARCHITECTURE.md`). No UI; usable from a SwiftUI app or a
Capacitor plugin.

- **MeshCodec**: the Meshtastic phone API (`FromRadio` / `ToRadio`) for the
  fields the games use: packets with RSSI/SNR/hops/relay node, text, position,
  node info, channels, config complete; text, want_config and heartbeat out.
  Our own small protobuf reader/writer, written from the wire format; tests
  compare against bytes produced by the official Meshtastic package
  (`Tests/.../Fixtures/make_fixtures.py`, run with the Den's venv).
  Also acks/naks with their reason, replies, reactions, traceroute and
  position beacons.
- **MeshSession**: the node database, channels and ready state built from frames.
- **MeshLink**: CoreBluetooth link to the hunter's own node (subscribe FromNum,
  want_config, drain FromRadio; remembers the last node).
- **WG**: the Wildcat Games text protocol as refereed by the Den
  (`wildcat-games-app/foxhunt.py`, `wg.py`): hunter commands and every Den reply.
- **FoxTracker**: the live warmer/colder meter from direct-RF packets of the fox,
  and when to report `WG SIG` to the Den.
- **RNode**: the RNode (Reticulum LoRa modem) host protocol: KISS framing, the
  command set, EEPROM/`rnodeconf --info` parsing, radio parameters and stats, with
  frames captured from a real RAK4631 (`Fixtures/rnode-wisblock.json`).
  **RNodeSession** walks connect → detect → info → parameters; **RNodeLink** is the
  CoreBluetooth link (Nordic UART, PIN pairing). Phase 1: read and tune, no TX.
  **RNodeBLELog** writes every CoreBluetooth event the link sees to `Documents/rnode-ble.log`
  (on in DEBUG builds on iOS, or with `-RNodeDiag`), for pairing trouble.
  **Host mode** (`attachHost`/`hostWrite`/`detachHost`): a host program on the phone (the
  Reticulum stack, branch `reticulum-spike`) drives the RNode through the link. Its bytes go out in
  Bluetooth-sized writes (flow-controlled), everything the RNode sends goes back untouched, the
  console's own commands pause, and the session keeps decoding the stream for the console.
- **ReticulumPacket**: "Heard on air". Reads the outer header of the Reticulum packets an RNode
  hears (kind, destination hash, hops, header type and transport id, context; masked IFAC packets
  and unreadable bytes with a reason), written from the wire format in the Reticulum manual. Golden
  vectors are built and judged by the RNS library itself (`Fixtures/make_reticulum_fixtures.py` →
  `reticulum-packets.json`). Nothing past the header is read: no RNS or LXMF code is ported to
  Swift, and none should be (the Reticulum author treats machine translations as derivative works
  whose licence grant is void). `RNodeSession` keeps the newest 200 heard packets with counts,
  announcers by destination, LoRa frames and estimated airtime.

```
swift test
```

## License

GPL-3.0-or-later, like Meshtastic. Free and open: fork it, build on it, make
games and hardware for it. See [LICENSE](LICENSE).

[LICENSE-EXCEPTION](LICENSE-EXCEPTION) is a GPLv3 section 7 additional permission:
it allows combining this code with the Reticulum stack (RNS and LXMF), which has
its own licence.
