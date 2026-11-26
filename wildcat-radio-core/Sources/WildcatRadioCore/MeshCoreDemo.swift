import Foundation

/// A pretend MeshCore node for practice, App Review and screenshots: made-up
/// contacts, channels and messages around `center` (the phone's last position, so
/// the map and hunts work anywhere), else a public park. Nothing is transmitted.
extension MeshCoreSession {
    public static func demo(now: Date = Date(), center: Coordinate? = nil) -> MeshCoreSession {
        typealias P = MeshCorePractice
        var s = MeshCoreSession()
        let park = center ?? P.park
        func near(_ dLat: Double, _ dLon: Double) -> Coordinate {
            Coordinate(latitude: park.latitude + dLat, longitude: park.longitude + dLon)
        }

        _ = s.handle(.selfInfo(MeshCore.SelfInfo(advertType: 1, txPower: 22, maxTxPower: 22, publicKey: P.key(0xB0), position: nil,
                                                 frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5,
                                                 name: "Practice Node")), now: now)
        _ = s.handle(.deviceInfo(MeshCore.DeviceInfo(firmwareCode: 9, maxContacts: 350, maxChannels: 40, buildDate: "practice",
                                                     manufacturer: "Wildcat practice", version: "v1.17.1")), now: now)
        _ = s.handle(.channelInfo(index: 0, name: "Public", secret: Data(count: 16)), now: now)
        _ = s.handle(.channelInfo(index: 1, name: "WGBRIDGE", secret: Data(repeating: 0x5A, count: 16)), now: now)
        _ = s.handle(.battery(millivolts: 3910, usedKB: 12, totalKB: 1000), now: now)
        // Route from us outward (one hash per repeater), as the node stores it.
        let contacts: [(UInt8, MeshCore.Contact.Kind, String, [UInt8], Coordinate?, TimeInterval)] = [
            (0x1C, .repeater, "Hilltop Repeater", [], near(0.004, 0.006), 300),
            (0x2A, .repeater, "Riverside RPT", [0x1C], near(-0.006, -0.009), 1500),
            (0x4D, .repeater, "Windmill RPT", [0x1C], near(0.0011, -0.0225), 900),
            (0x3E, .room, "Park Room Server", [0x1C], near(0.001, -0.003), 3600),
            (0x51, .chat, "MAYA Field Unit", [0x1C], nil, 600),
            (0x66, .chat, "DEX Trail Node", [0x1C, 0x2A], nil, 5400),
            (0x73, .chat, "SAGE Base Camp", [], nil, 1200),
        ]
        for (b, kind, name, path, pos, ago) in contacts {
            var c = MeshCore.Contact(publicKey: P.key(b), kind: kind, flags: 0, pathLength: path.count, name: name,
                                     lastAdvert: now.addingTimeInterval(-ago), position: pos, lastModified: nil)
            c.path = Data(path)
            _ = s.handle(.contact(c), now: now)
        }
        // The hidden fox: a repeater with no position and no known route, for the hunt.
        _ = s.handle(.contact(MeshCore.Contact(publicKey: P.key(P.fox.byte), kind: .repeater, flags: 0, pathLength: nil,
                                               name: P.fox.name, lastAdvert: now.addingTimeInterval(-240), position: nil,
                                               lastModified: nil)), now: now)
        // Heard but not added (auto-add off): writing to NOVA adds her to the node first.
        _ = s.handle(.newAdvert(MeshCore.Contact(publicKey: P.key(P.nova.byte), kind: .chat, flags: 0, pathLength: nil,
                                                 name: P.nova.name, lastAdvert: now.addingTimeInterval(-700), position: nil,
                                                 lastModified: nil)), now: now)

        // History: each message is fed the way a real node reports it (the packet heard
        // on air, then the message), so it carries signal, path, size and packet hash.
        var engine = MeshCorePractice(now: now, seed: 0x5EED)
        func feed() { for d in engine.drain() { _ = s.handle(d.frame, now: d.at) } }
        func heard(_ p: P.Person, _ text: String, channel: Int?, ago: TimeInterval) {
            engine.incoming(p, text: text, channel: channel, at: now.addingTimeInterval(-ago), session: s)
            feed()
        }
        func said(_ text: String, channel: Int, ago: TimeInterval, repeats: Int) {
            let at = Date(timeIntervalSince1970: now.addingTimeInterval(-ago).timeIntervalSince1970.rounded(.down))
            _ = s.sent(text, to: .channel(channel), at: at)
            engine.echo(channel: channel, text: text, at: at, repeats: repeats, session: s)
            feed()
        }
        func said(_ text: String, to p: P.Person, ago: TimeInterval, ack: UInt32, roundTripMs: UInt32) {
            let at = Date(timeIntervalSince1970: now.addingTimeInterval(-ago).timeIntervalSince1970.rounded(.down))
            let id = s.sent(text, to: .contact(P.key(p.byte).prefix(6)), at: at)
            s.attachAck(ack, to: id)
            _ = s.handle(.sendConfirmed(ack: ack, roundTripMs: roundTripMs), now: at.addingTimeInterval(Double(roundTripMs) / 1000))
        }

        heard(P.maya, "Morning mesh! Anyone up by the lake?", channel: 0, ago: 2400)
        heard(P.dex, "Heard you through Hilltop, 2 hops", channel: 0, ago: 2100)
        heard(P.bridge, "\(BridgeOrigin.tagMeshtastic) KITE: Hi from the LongFast crowd 👋 anyone on MeshCore?", channel: 0, ago: 1500)
        if let i = s.chats.lastIndex(where: { $0.bridged != nil }) {
            s.setBridged(BridgeOrigin(network: .meshtastic, senderID: "!7a110005", senderName: "KITE", channel: "LongFast",
                                      hops: 2, via: P.bridge.name), on: s.chats[i].id)
        }
        heard(P.maya, "Leaving a Geo Gift by the windmill 🎁", channel: nil, ago: 1260)
        said("Nice! What's the code?", to: P.maya, ago: 1200, ack: 0x7AC0_0001, roundTripMs: 1840)
        heard(P.maya, "It's on the lid. Don't tell DEX 😄", channel: nil, ago: 1140)
        heard(P.sage, "Hilltop solar reads 4.1 V, looking good", channel: 0, ago: 1080)
        heard(P.maya, "Bridge is up, say hi to the Meshtastic side 👋", channel: 1, ago: 1000)
        said("On my way, bringing the spare antenna", channel: 0, ago: 780, repeats: 3)
        heard(P.maya, "Meet at the windmill at noon?", channel: 0, ago: 420)
        said("Found it 🎉", to: P.maya, ago: 300, ack: 0x7AC0_0002, roundTripMs: 2260)
        heard(P.dex, "Copy, 20 min out", channel: 0, ago: 180)

        for i in 0..<42 { _ = s.handle(.rxLog(snr: 6, rssi: -80 - (i % 20), raw: Data([0x11, 0x00])), now: now) }
        s.markReady()
        return s
    }
}

/// Drives the pretend practice node: answers what the app sends and fills the air with
/// made-up traffic, as the frames a real companion would send, so the session handles
/// them the same way (signal, paths, repeats and round trips all come out as on a real
/// mesh). Pure and clock-driven: the link calls `step(now:session:)` every second, and
/// tests call it with any clock they like.
public struct MeshCorePractice: Sendable {
    /// Someone on the pretend mesh and how the practice node hears them.
    public struct Person: Equatable, Sendable {
        public var byte: UInt8
        public var name: String
        /// Relay hashes their packets come through, oldest first.
        public var path: [UInt8]
        public var snr: Double
        public var rssi: Int
    }

    static let maya = Person(byte: 0x51, name: "MAYA Field Unit", path: [0x1C], snr: 6.5, rssi: -84)
    static let dex = Person(byte: 0x66, name: "DEX Trail Node", path: [0x2A, 0x1C], snr: -3.0, rssi: -109)
    static let sage = Person(byte: 0x73, name: "SAGE Base Camp", path: [], snr: 11.25, rssi: -62)
    /// A MeshCore node that re-posts Meshtastic lines (not a contact).
    static let bridge = Person(byte: 0x88, name: "Park Bridge", path: [0x4D], snr: 2.25, rssi: -101)
    /// Heard, not added: the practice node refuses to DM her until she's added.
    static let nova = Person(byte: 0x95, name: "NOVA Hiker", path: [0x2A], snr: 1.5, rssi: -104)
    /// The repeater to hunt: no position, heard straight from wherever it hides.
    static let fox = Person(byte: 0xF0, name: "Practice Fox RPT", path: [], snr: 0, rssi: -106)
    static let people = [maya, dex, sage, nova]

    /// Where practice happens when the app gives no centre (a public park).
    public static let park = Coordinate(latitude: 37.7694, longitude: -122.4862)
    /// How far the fox hides from the centre, and in which direction.
    static let foxOffset = (metres: 420.0, bearing: 200.0)

    /// The newest chats kept per conversation while practising.
    public static let keepPerChat = 20
    /// Made-up channel chatter: how often and how much per run (gentle on purpose).
    static let chatterEvery: TimeInterval = 150
    static let maxChatter = 3

    static let channelReplies: [(Person, String)] = [
        (maya, "Loud and clear 👍"),
        (dex, "Got you via Riverside, 2 hops"),
        (sage, "Copy that. Coffee's on at base camp ☕"),
        (maya, "Heading to the windmill, see you there"),
        (dex, "Signal's great by the lake today"),
    ]
    static let directReplies: [UInt8: [String]] = [
        0x51: ["On it!", "See you at the windmill 🌷", "Ha, nice one"],
        0x66: ["Copy, out on the trail till 3", "Roger that"],
        0x73: ["Base camp here, all good", "Copy, over"],
        0x95: ["Thanks for adding me! Out on the ridge 🥾", "Copy that"],
    ]
    static let chatterLines: [(Person, String)] = [
        (sage, "Anyone up for a fox hunt later?"),
        (bridge, "\(BridgeOrigin.tagMeshtastic) KITE: LongFast is busy today, 14 nodes heard"),
        (maya, "New Geo Gift dropped near the bison paddock 🎁"),
    ]

    /// The made-up 32-byte key of a practice node; its first byte is its hash.
    static func key(_ b: UInt8) -> Data { Data([b] + (1..<32).map { UInt8(($0 * 37 + Int(b)) & 0xFF) }) }

    struct Due: Sendable {
        var at: Date
        var frame: MeshCore.Frame
    }

    /// The pretend node's own settings and tables, as the app changes them (copied
    /// from the demo session at the first command).
    struct Node: Sendable {
        var me: MeshCore.SelfInfo
        var device: MeshCore.DeviceInfo?
        var channels: [Int: MeshCoreSession.Channel]
        var contacts: [Data: MeshCore.Contact]
        var battery: Int
        var pin: UInt32 = 0
    }

    private var node: Node?
    private var due: [Due] = []
    private var rng: SplitMix
    private var nextAmbient: Date
    private var nextChatter: Date
    private var nextFox: Date
    private var foxCount = 0
    /// Where the fox hides (for a player whose position the app passes in).
    public let foxSpot: Coordinate
    /// Where the player is (the app's location); nil: pretend to walk once hunting.
    public var walker: Coordinate?
    /// Pretend metres to the fox when there's no `walker`; shrinks while hunting.
    public private(set) var walkedDistance = MeshCorePractice.foxOffset.metres
    /// The fox has been pinged: the pretend walk has begun.
    public private(set) var hunting = false
    private var ambientCount = 0
    private var advertCount = 0
    private var chatter = 0
    private var replies = 0
    /// One reply in flight at a time: sending a burst doesn't bring a burst back.
    private var replyAfter: Date = .distantPast
    private var ack: UInt32 = 0x7AC0_1000

    public init(now: Date = Date(), seed: UInt64 = UInt64.random(in: 1...UInt64.max), center: Coordinate? = nil) {
        rng = SplitMix(seed: seed)
        nextAmbient = now.addingTimeInterval(0.5)
        nextChatter = now.addingTimeInterval(Self.chatterEvery)
        nextFox = now.addingTimeInterval(2)
        foxSpot = PracticeGeo.offset(center ?? Self.park, metres: Self.foxOffset.metres, bearing: Self.foxOffset.bearing)
    }

    /// Frames waiting for their moment.
    public var pendingCount: Int { due.count }

    /// The pretend node's settings as the app last changed them (nil before any command).
    public var me: MeshCore.SelfInfo? { node?.me }
    /// The Bluetooth PIN the app last set (0 = the firmware's default).
    public var pin: UInt32 { node?.pin ?? 0 }

    /// Metres between the player and the fox.
    public var distanceToFox: Double { walker.map { PracticeGeo.distance($0, foxSpot) } ?? walkedDistance }

    /// The pretend node's state, made from the demo session the first time.
    private mutating func state(_ s: MeshCoreSession) -> Node {
        if let node { return node }
        let me = s.me ?? MeshCore.SelfInfo(advertType: 1, txPower: 22, maxTxPower: 22, publicKey: Self.key(0xB0), position: nil,
                                           frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5, name: "Practice Node")
        let n = Node(me: me, device: s.device, channels: s.channels, contacts: s.contacts.filter { s.onNode.contains($0.key) },
                     battery: s.batteryMillivolts ?? 3910)
        node = n
        return n
    }

    private static let unknown = 2, illegal = 6   // ERR_CODE_NOT_FOUND, ERR_CODE_ILLEGAL_ARG

    /// What the node answers right away to a command, as the companion firmware
    /// (v1.17.1 MyMesh::handleCmdFrame) would: settings change the pretend node and
    /// are checked the same way. Repeats, confirmations and replies follow from `step`.
    public mutating func command(_ c: MeshCore.Command, session s: MeshCoreSession, now: Date) -> [MeshCore.Frame] {
        var n = state(s)
        defer { node = n }
        let maxChannels = n.device?.maxChannels ?? 8
        switch c {
        case .appStart:
            return [.selfInfo(n.me)]
        case .deviceQuery:
            return n.device.map { [.deviceInfo($0)] } ?? [.error(code: 1)]
        case .getBatteryAndStorage:
            return [.battery(millivolts: n.battery, usedKB: 12, totalKB: 1000)]
        case .syncNextMessage:
            return [.noMoreMessages]
        case .getContacts:
            let list = n.contacts.values.sorted { $0.name < $1.name }
            return [.contactsStart(count: list.count)] + list.map { .contact($0) } + [.endOfContacts]
        case .getChannel(let i):
            guard i >= 0, i < maxChannels else { return [.error(code: Self.unknown)] }
            let ch = n.channels[i]
            return [.channelInfo(index: i, name: ch?.name ?? "", secret: ch?.secret ?? Data(count: 16))]
        case .setChannel(let i, let name, let secret):
            guard i >= 0, i < maxChannels else { return [.error(code: Self.unknown)] }
            let key = Data(secret.prefix(16)) + Data(count: max(0, 16 - secret.count))
            n.channels[i] = name.isEmpty && key.allSatisfy({ $0 == 0 }) ? nil
                : MeshCoreSession.Channel(index: i, name: String(decoding: Data(name.utf8).prefix(31), as: UTF8.self), secret: key)
            return [.ok]
        case .setName(let name):
            n.me.name = String(decoding: Data(name.utf8).prefix(31), as: UTF8.self)
            return [.ok]
        case .setRadio(let f, let bw, let sf, let cr):
            // Same limits as CMD_SET_RADIO_PARAMS: 150-2500 MHz, 7-500 kHz, SF 5-12, CR 5-8.
            guard (150...2500).contains(f), (7...500).contains(bw), (5...12).contains(sf), (5...8).contains(cr)
            else { return [.error(code: Self.illegal)] }
            n.me.frequency = (f * 1000).rounded() / 1000
            n.me.bandwidth = (bw * 1000).rounded() / 1000
            n.me.spreadingFactor = sf
            n.me.codingRate = cr
            return [.ok]
        case .setTxPower(let p):
            guard p >= -9, p <= n.me.maxTxPower else { return [.error(code: Self.illegal)] }
            n.me.txPower = p
            return [.ok]
        case .setPosition(let p):
            guard abs(p.latitude) <= 90, abs(p.longitude) <= 180 else { return [.error(code: Self.illegal)] }
            n.me.position = p.latitude == 0 && p.longitude == 0 ? nil : p
            return [.ok]
        case .setOtherParams(let manual, let tele, let loc, let acks):
            n.me.manualAddContacts = manual
            n.me.telemetryModes = tele
            n.me.advertLocationPolicy = loc
            n.me.multiAcks = acks
            return [.ok]
        case .setPIN(let pin):
            guard pin == 0 || (100_000...999_999).contains(pin) else { return [.error(code: Self.illegal)] }
            n.pin = pin
            return [.ok]
        case .addContact(let contact):
            n.contacts[contact.publicKey] = contact
            return [.ok]
        case .removeContact(let key):
            return n.contacts.removeValue(forKey: key) == nil ? [.error(code: Self.unknown)] : [.ok]
        case .resetPath(let key):
            guard n.contacts[key] != nil else { return [.error(code: Self.unknown)] }
            n.contacts[key]?.pathLength = nil
            n.contacts[key]?.path = Data()
            return [.ok]
        case .statusRequest(let key):
            guard let target = n.contacts[key] else { return [.error(code: Self.unknown)] }
            ack &+= 1
            if key == Self.key(Self.fox.byte) { hunting = true }
            statusReply(from: target, me: n.me, at: now.addingTimeInterval(rng.double(1.2...2.4)))
            return [.sent(flood: target.pathLength == nil, ack: ack, timeout: 6000)]
        case .sendChannelText(let ch, let text, let at):
            echo(channel: ch, text: text, at: at, repeats: rng.chance(0.5) ? 3 : 2, session: s)
            if wantsReply(text, now: now), let pick = Self.channelReplies[safe: replies % Self.channelReplies.count] {
                replies += 1
                let t = now.addingTimeInterval(rng.double(5...9))
                incoming(pick.0, text: pick.1, channel: ch, at: t, session: s)
                replyAfter = t
            }
            return [.ok]
        case .sendText(let to, let text, _, let attempt):
            // Like the firmware: only contacts in the node's own table can be messaged.
            guard let contact = n.contacts.values.first(where: { $0.prefix == to.prefix(6) }) else {
                return [.error(code: Self.unknown)]
            }
            ack &+= 1
            let a = ack
            let rtt = UInt32(rng.int(1400...3200))
            // DEX is two weak hops out: his first try never comes back, so practice shows a retry.
            let lost = contact.publicKey.first == Self.dex.byte && attempt == 0
            if !lost { schedule(now.addingTimeInterval(Double(rtt) / 1000), .sendConfirmed(ack: a, roundTripMs: rtt)) }
            if !lost, wantsReply(text, now: now), let p = Self.people.first(where: { Self.key($0.byte).prefix(6) == to.prefix(6) }),
               let lines = Self.directReplies[p.byte], !lines.isEmpty {
                replies += 1
                let t = now.addingTimeInterval(rng.double(5...9))
                incoming(p, text: lines[replies % lines.count], channel: nil, at: t, session: s)
                replyAfter = t
            }
            return [.sent(flood: contact.pathLength == nil, ack: a, timeout: 8000)]
        case .sendSelfAdvert, .setDeviceTime:
            return [.ok]
        default:
            return []
        }
    }

    /// Everything due by `now`, oldest first, plus a made-up packet on air every few
    /// seconds and (rarely) a line of channel chatter.
    public mutating func step(now: Date, session s: MeshCoreSession) -> [MeshCore.Frame] {
        if now >= nextAmbient {
            ambient(now: now, session: s)
            // A quick burst at the start so the live strip isn't empty, then every 4-7 s.
            nextAmbient = now.addingTimeInterval(ambientCount < 3 ? 1 : rng.double(4...7))
        }
        if now >= nextFox {
            foxTransmits(now: now, session: s)
            nextFox = now.addingTimeInterval(rng.double(4...6))
        }
        if now >= nextChatter {
            nextChatter = now.addingTimeInterval(Self.chatterEvery)
            if chatter < Self.maxChatter, now >= replyAfter, let pick = Self.chatterLines[safe: chatter] {
                chatter += 1
                incoming(pick.0, text: pick.1, channel: 0, at: now, session: s)
            }
        }
        let ready = due.filter { $0.at <= now }
        due.removeAll { $0.at <= now }
        return ready.map(\.frame)
    }

    /// Everything scheduled, whenever it's due (seeding history).
    mutating func drain() -> [Due] {
        defer { due = [] }
        return due
    }

    private func wantsReply(_ text: String, now: Date) -> Bool {
        !text.hasPrefix("WG ") && !text.hasPrefix(BridgeOrigin.tagMeshtastic) && now >= replyAfter
    }

    private mutating func schedule(_ at: Date, _ frame: MeshCore.Frame) {
        // Kept in time order (equal times keep the order they were added).
        let i = due.firstIndex { $0.at > at } ?? due.count
        due.insert(Due(at: at, frame: frame), at: i)
    }

    private static func secs(_ d: Date) -> UInt32 { UInt32(clamping: Int64(d.timeIntervalSince1970)) }

    /// Repeaters passing on a channel message we sent: each copy ends with a different repeater.
    mutating func echo(channel: Int, text: String, at: Date, repeats: Int, session s: MeshCoreSession) {
        guard let secret = s.channels[channel]?.secret,
              let payload = MeshCoreChannelCrypto.encrypt(.init(timestamp: Self.secs(at), flags: 0,
                                                                text: "\(s.me?.name ?? "Practice Node"): \(text)"), secret: secret)
        else { return }
        let copies: [(path: [UInt8], snr: Double, rssi: Int)] = [([0x1C], 9.25, -71), ([0x2A], 3.5, -96), ([0x1C, 0x4D], 1.75, -103)]
        for (k, c) in copies.prefix(max(0, repeats)).enumerated() {
            schedule(at.addingTimeInterval(1.1 + Double(k) * 1.4 + rng.double(0...0.4)),
                     .rxLog(snr: c.snr, rssi: c.rssi, raw: Self.groupText(path: c.path, payload: payload)))
        }
    }

    /// Someone's message reaching the node at `at`: the packet heard on air, then the message.
    mutating func incoming(_ p: Person, text: String, channel: Int?, at: Date, session s: MeshCoreSession) {
        let sent = Date(timeIntervalSince1970: (at.timeIntervalSince1970 - 1).rounded(.down))
        let snr = p.snr + Double(rng.int(-2...2)) * 0.25
        let rssi = p.rssi + rng.int(-2...2)
        let raw: Data
        let origin: MeshCore.Message.Origin
        var line = text
        if let channel {
            line = "\(p.name): \(text)"
            guard let secret = s.channels[channel]?.secret,
                  let payload = MeshCoreChannelCrypto.encrypt(.init(timestamp: Self.secs(sent), flags: 0, text: line), secret: secret)
            else { return }
            raw = Self.groupText(path: p.path, payload: payload)
            origin = .channel(channel)
        } else {
            raw = Self.directText(path: p.path, source: p.byte, destination: s.me?.publicKey.first ?? 0, cipher: rng.bytes(16 + 16 * (text.utf8.count / 16)))
            origin = .contact(Self.key(p.byte).prefix(6))
        }
        schedule(at, .rxLog(snr: snr, rssi: rssi, raw: raw))
        schedule(at.addingTimeInterval(0.3), .message(MeshCore.Message(origin: origin, hops: p.path.count, textType: 0, sent: sent,
                                                                       snr: snr, text: line)))
    }

    /// A made-up packet on air: mostly adverts (each contact in turn), plus group
    /// texts on channels we don't have and the odd ack.
    private mutating func ambient(now: Date, session s: MeshCoreSession) {
        defer { ambientCount += 1 }
        // The fox keeps its own schedule (its signal follows the player).
        let contacts = s.contacts.values.filter { $0.publicKey.count == 32 && $0.publicKey.first != Self.fox.byte }
            .sorted { $0.name < $1.name }
        switch ambientCount % 5 {
        case 1, 4:
            let path: [UInt8] = [[0x1C], [0x2A, 0x1C], [0x4D], [0x3E, 0x1C]][rng.int(0...3)]
            let payload = Data([0x7E]) + rng.bytes(2 + 16 * rng.int(1...3))
            schedule(now, .rxLog(snr: rng.double(-6...8).rounded(), rssi: rng.int(-112 ... -80), raw: Self.groupText(path: path, payload: payload)))
        case 3:
            schedule(now, .rxLog(snr: rng.double(0...9).rounded(), rssi: rng.int(-100 ... -70),
                                 raw: Data([0x0D, 1, 0x1C]) + rng.bytes(4)))
        default:
            guard !contacts.isEmpty else { return }
            let c = contacts[advertCount % contacts.count]
            advertCount += 1
            let hops = c.pathLength ?? 0
            let seed = Double((c.publicKey.first ?? 0) % 7)
            let snr = 10.5 - Double(hops) * 5.5 - seed * 0.5 + Double(rng.int(-4...4)) * 0.25
            let rssi = -88 - hops * 9 - Int(seed) + rng.int(-2...2)
            let path = Array(c.path.reversed())
            schedule(now, .rxLog(snr: snr, rssi: rssi, raw: Self.advert(c, at: now, path: path, signature: rng.bytes(64))))
            schedule(now, advertPush(c, session: s))
        }
    }

    /// What the node pushes for an advert: just the key for a contact it holds, the
    /// whole record (0x8A) for one it doesn't (auto-add is off).
    private func advertPush(_ c: MeshCore.Contact, session s: MeshCoreSession) -> MeshCore.Frame {
        let held = node.map { $0.contacts[c.publicKey] != nil } ?? s.onNode.contains(c.publicKey)
        return held ? .advert(publicKey: c.publicKey) : .newAdvert(c)
    }

    // MARK: The fox

    /// Signal at `d` metres: a rough log-distance model plus a little fading (as the
    /// Meshtastic practice fox).
    static func rssi(at d: Double, fade: Double) -> Int { Int((-38 - 26 * log10(max(d, 1)) + fade).rounded()) }
    static func snr(rssi: Int) -> Double { (max(-18, min(12, Double(rssi + 100) / 3)) * 4).rounded() / 4 }

    /// The fox on air every few seconds, heard straight from it: its own zero-hop
    /// advert, or a packet it relayed (it's the last hop). Loud when you're close.
    private mutating func foxTransmits(now: Date, session s: MeshCoreSession) {
        let key = Self.key(Self.fox.byte)
        guard let fox = s.contacts[key] else { return }
        if hunting, walker == nil {
            // A pretend walk towards it, sometimes the wrong way for a moment.
            walkedDistance = max(3, walkedDistance + (rng.chance(0.2) ? 12 : -18))
        }
        let rssi = Self.rssi(at: distanceToFox, fade: rng.double(-3...3))
        let snr = Self.snr(rssi: rssi)
        defer { foxCount += 1 }
        if foxCount % 2 == 0 {
            schedule(now, .rxLog(snr: snr, rssi: rssi, raw: Self.advert(fox, at: now, path: [], signature: rng.bytes(64))))
            schedule(now, advertPush(fox, session: s))
        } else {
            let payload = Data([0x7E]) + rng.bytes(2 + 16 * rng.int(1...2))
            schedule(now, .rxLog(snr: snr, rssi: rssi, raw: Self.groupText(path: [0x2A, Self.fox.byte], payload: payload)))
        }
    }

    /// A repeater's answer to a status request: its response packet on air, then the status.
    private mutating func statusReply(from c: MeshCore.Contact, me: MeshCore.SelfInfo, at: Date) {
        let isFox = c.publicKey.first == Self.fox.byte
        let hops = c.pathLength ?? 0
        let rssi = isFox ? Self.rssi(at: distanceToFox, fade: rng.double(-3...3)) : -88 - hops * 9 + rng.int(-3...3)
        let snr = isFox ? Self.snr(rssi: rssi) : 10.5 - Double(hops) * 5.5 + Double(rng.int(-4...4)) * 0.25
        // Direct and arrived (no relays left), or flooded back through the route.
        let raw = isFox || hops == 0
            ? Self.response(path: [], route: 2, source: c.publicKey.first ?? 0, destination: me.publicKey.first ?? 0, cipher: rng.bytes(48))
            : Self.response(path: Array(c.path), route: 1, source: c.publicKey.first ?? 0, destination: me.publicKey.first ?? 0,
                            cipher: rng.bytes(48))
        schedule(at, .rxLog(snr: snr, rssi: rssi, raw: raw))
        let up = UInt32(9 * 86_400 + rng.int(0...86_400))
        schedule(at.addingTimeInterval(0.2), .status(prefix: c.prefix, MeshCore.RepeaterStatus(
            batteryMillivolts: isFox ? 3_870 : 4_050, txQueue: 0, noiseFloor: -112, lastRSSI: rssi,
            packetsReceived: 25_310, packetsSent: 18_452, airtimeSeconds: 3_120, uptimeSeconds: up,
            sentFlood: 9_800, sentDirect: 8_652, receivedFlood: 16_400, receivedDirect: 8_910, errors: 0,
            lastSNR: snr, directDuplicates: 140, floodDuplicates: 2_210, receiveAirtimeSeconds: 6_400, receiveErrors: 12)))
    }

    // MARK: Packets (as heard on air, per MeshCorePacket)

    /// RESPONSE (1 << 2), flood (1) or direct (2): destination hash, source hash, MAC (2), ciphertext.
    static func response(path: [UInt8], route: UInt8, source: UInt8, destination: UInt8, cipher: Data) -> Data {
        Data([0x04 | route, UInt8(path.count)] + path + [destination, source, 0x5A, 0xA5]) + cipher
    }

    /// Flood (1) | GRP_TXT (5 << 2).
    static func groupText(path: [UInt8], payload: Data) -> Data { Data([0x15, UInt8(path.count)] + path) + payload }

    /// Flood (1) | TXT_MSG (2 << 2): destination hash, source hash, MAC (2), ciphertext.
    static func directText(path: [UInt8], source: UInt8, destination: UInt8, cipher: Data) -> Data {
        Data([0x09, UInt8(path.count)] + path + [destination, source, 0x5A, 0xA5]) + cipher
    }

    /// Flood (1) | ADVERT (4 << 2): key, timestamp, signature, flags, position, name.
    static func advert(_ c: MeshCore.Contact, at: Date, path: [UInt8], signature: Data) -> Data {
        var d = Data([0x11, UInt8(path.count)] + path)
        d.append(c.publicKey.prefix(32))
        withUnsafeBytes(of: secs(at).littleEndian) { d.append(contentsOf: $0) }
        d.append(signature.prefix(64))
        if signature.count < 64 { d.append(Data(count: 64 - signature.count)) }
        d.append(c.kind.rawValue | 0x80 | (c.position == nil ? 0 : 0x10))
        if let p = c.position {
            let lat = Int32(clamping: Int64((p.latitude * 1e6).rounded())), lon = Int32(clamping: Int64((p.longitude * 1e6).rounded()))
            withUnsafeBytes(of: lat.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: lon.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(Data(c.name.utf8))
        return d
    }
}

/// Just enough geography to place the practice fox and measure the walk to it.
enum PracticeGeo {
    static let earth = 6_371_000.0

    static func offset(_ c: Coordinate, metres: Double, bearing: Double) -> Coordinate {
        let b = bearing * .pi / 180
        let dLat = metres * cos(b) / earth
        let dLon = metres * sin(b) / (earth * max(cos(c.latitude * .pi / 180), 0.01))
        return Coordinate(latitude: c.latitude + dLat * 180 / .pi, longitude: c.longitude + dLon * 180 / .pi)
    }

    /// Haversine metres.
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * r, dLon = (b.longitude - a.longitude) * r
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * r) * cos(b.latitude * r) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earth * asin(min(1, sqrt(h)))
    }
}

/// A small seeded generator, so practice runs are repeatable in tests.
struct SplitMix: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func double(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &self) }
    mutating func chance(_ p: Double) -> Bool { double(0...1) < p }
    mutating func bytes(_ n: Int) -> Data { Data((0..<max(0, n)).map { _ in UInt8.random(in: 0...255, using: &self) }) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
