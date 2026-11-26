import Foundation
import WildcatRadioCore

/// A pretend mesh for practice (and for App Review, which has no radios): a
/// fox that gets louder as you "walk" towards it, a small Den that answers WG
/// commands the way foxhunt.py does, and a few people chatting on LongFast who
/// answer (and acknowledge) what you send.
@MainActor
final class PracticeMesh {
    static let me = NodeNum(0x00A1_1CE5)
    static let fox = NodeNum(0x9E76_6B18)
    static let den = NodeNum(0x0DE1_0DE1)
    static let lake = NodeNum(0x7A11_0001)
    static let trail = NodeNum(0x7A11_0002)
    static let maya = NodeNum(0x7A11_0003)
    static let kite = NodeNum(0x7A11_0005)
    /// Two small boxes to hide in a practice Hunt game (Small Play 2): they beacon like the fox.
    static let loot = NodeNum(0x7A11_0B01)
    static let gem = NodeNum(0x7A11_0B02)
    static let huntChannel = 1
    static let code = "4821"
    /// Practice chats keep only their newest messages.
    static let keepPerChat = 20

    private(set) var session: MeshSession
    var onEvent: ((MeshSession.Event) -> Void)?
    /// Metres to the fox; shrinks while you "walk".
    private(set) var distance: Double = 420
    /// Metres to the practice pieces: in your hand, more or less.
    private var pieceDistance: [NodeNum: Double] = [loot: 1.5, gem: 2.5]
    private var ticks = 0
    private var timer: Timer?
    private var started: Date?
    private var joined = false
    private var found = false
    private var badCodes = 0
    private var last: Int?
    private var best: Int?
    private var packetID: UInt32 = 1
    /// One reply in flight at a time, so a burst of sends doesn't bring a burst back.
    private var replyAfter = Date.distantPast
    private var replies = 0

    /// Where the Den and two relays sit: a short walk from `center` (the phone's
    /// last position) so Daily Fox works anywhere, else around a public park.
    static func placements(around center: LatLon?) -> [LatLon] {
        guard let center else {
            return [LatLon(lat: 37.7712, lon: -122.4815), LatLon(lat: 37.7680, lon: -122.4935),
                    LatLon(lat: 37.7661, lon: -122.4790)]
        }
        return [Geo.offset(center, distance: 470, bearing: 32), Geo.offset(center, distance: 800, bearing: 273),
                Geo.offset(center, distance: 500, bearing: 110)]
    }

    init(center: LatLon? = nil) {
        var s = MeshSession(configID: 1)
        _ = s.handle(.myInfo(Self.me))
        var you = NodeInfo(num: Self.me, userID: Self.me.id, longName: "Practice Handheld", shortName: "PRAC", snr: nil)
        // Readouts for the Meshtastic tab's node card (App Review has no radio).
        you.metrics = DeviceMetrics(batteryLevel: 82, voltage: 3.98, channelUtilization: 4.2, airUtilTx: 0.6,
                                    uptime: 3 * 86_400 + 4 * 3600)
        _ = s.handle(.nodeInfo(you))
        _ = s.handle(.nodeInfo(NodeInfo(num: Self.fox, userID: Self.fox.id, longName: "Zeus the Fox", shortName: "ZEUZ", snr: nil)))
        // The Den and two relays have positions (the fox stays hidden).
        func placed(_ num: UInt32, _ long: String, _ short: String, _ p: LatLon) -> NodeInfo {
            var n = NodeInfo(num: NodeNum(num), userID: NodeNum(num).id, longName: long, shortName: short, snr: 6)
            n.position = Coordinate(latitude: p.lat, longitude: p.lon)
            n.lastHeard = Date()
            n.hopsAway = 0
            return n
        }
        let spots = Self.placements(around: center)
        _ = s.handle(.nodeInfo(placed(Self.den.raw, "Wildcat Den", "DEN", spots[0])))
        _ = s.handle(.nodeInfo(placed(Self.lake.raw, "Lakeside Node", "LAKE", spots[1])))
        _ = s.handle(.nodeInfo(placed(Self.trail.raw, "Trail Relay", "TRL", spots[2])))
        // MAYA is on both networks: People merges her Meshtastic handheld with her MeshCore node.
        var maya = NodeInfo(num: Self.maya, userID: Self.maya.id, longName: "MAYA Handheld", shortName: "MAYA", snr: 7)
        maya.lastHeard = Date()
        maya.hopsAway = 1
        _ = s.handle(.nodeInfo(maya))
        // KITE is two hops out; the practice MeshCore bridge carries one of her lines.
        var kite = NodeInfo(num: Self.kite, userID: Self.kite.id, longName: "KITE Handheld", shortName: "KITE", snr: -4)
        kite.lastHeard = Date().addingTimeInterval(-900)
        kite.hopsAway = 2
        _ = s.handle(.nodeInfo(kite))
        for (num, long, short, battery) in [(Self.loot, "Loot Box", "LOOT", 88), (Self.gem, "Gem Box", "GEM", 76)] {
            var n = NodeInfo(num: num, userID: num.id, longName: long, shortName: short, snr: 9)
            n.lastHeard = Date()
            n.hopsAway = 0
            n.metrics = DeviceMetrics(batteryLevel: battery, voltage: 3.9, channelUtilization: nil, airUtilTx: nil, uptime: 7200)
            _ = s.handle(.nodeInfo(n))
        }
        _ = s.handle(.channel(ChannelInfo(index: 0, name: "", role: .primary)))
        _ = s.handle(.channel(ChannelInfo(index: Self.huntChannel, name: "WGHUNT", role: .secondary)))
        _ = s.handle(.configComplete(1))
        session = s
    }

    func start() {
        onEvent?(.myNode(Self.me))
        onEvent?(.ready)
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Signal at `d` metres: a rough log-distance model plus a little fading.
    static func rssi(at d: Double, fade: Double) -> Int {
        Int((-38 - 26 * log10(max(d, 1)) + fade).rounded())
    }

    private func tick() {
        if joined && !found {
            // Walk ~9 m per tick, sometimes the wrong way for a moment.
            distance = max(3, distance + (Double.random(in: 0...1) < 0.2 ? 12 : -9))
        }
        let rssi = Self.rssi(at: distance, fade: Double.random(in: -3...3))
        let snr = Float(max(-18, min(12, Double(rssi + 100) / 3)))
        // The fox beacons a position packet, heard directly (0 hops).
        deliver(MeshPacket(from: Self.fox, to: .broadcast, channel: 0, id: nextID(), rxTime: Date(), rxSNR: snr,
                           rxRSSI: rssi, hopLimit: 3, hopStart: 3, viaMQTT: false, relayNode: nil,
                           portnum: .position, rawPortnum: 3, text: nil, position: nil, isEncrypted: false))
        // The practice pieces beacon every other tick, from close by.
        ticks += 1
        guard ticks % 2 == 0 else { return }
        for (piece, d) in pieceDistance {
            let r = Self.rssi(at: d, fade: Double.random(in: -2...2))
            deliver(MeshPacket(from: piece, to: .broadcast, channel: 0, id: nextID(), rxTime: Date(),
                               rxSNR: Float(max(-18, min(12, Double(r + 100) / 3))), rxRSSI: r, hopLimit: 3, hopStart: 3,
                               viaMQTT: false, relayNode: nil, portnum: .position, rawPortnum: 3, text: nil, position: nil,
                               isEncrypted: false))
        }
    }

    private func nextID() -> UInt32 {
        packetID &+= 1
        return packetID
    }

    private func deliver(_ p: MeshPacket) { onEvent?(.packet(p)) }

    /// The Den's answer arrives a moment later, as a DM from the Den.
    private func reply(_ text: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.timer != nil else { return }
            self.deliver(MeshPacket(from: Self.den, to: Self.me, channel: Self.huntChannel, id: self.nextID(),
                                    rxTime: Date(), rxSNR: 4, rxRSSI: -97, hopLimit: 2, hopStart: 3, viaMQTT: false,
                                    relayNode: nil, portnum: .text, rawPortnum: 1, text: text, position: nil,
                                    isEncrypted: false))
        }
    }

    private var clock: String {
        guard let started else { return "T+0M" }
        return "T+\(Int(Date().timeIntervalSince(started) / 60))M"
    }

    // MARK: Chat

    /// A chat message from the app: the Den reads WG commands as before; our own node
    /// hears a neighbour repeat it (sent), a DM's recipient acknowledges it (delivered),
    /// and someone answers a few seconds later. Returns the packet id.
    func send(text: String, to: NodeNum, channel: Int, isReaction: Bool = false) -> UInt32 {
        let id = nextID()
        receive(text: text, channel: channel)
        let direct = to != .broadcast
        later(.milliseconds(Int.random(in: 700...1200))) { $0.ack(id, from: Self.me) }
        if direct, to != Self.den, to != Self.fox {
            later(.milliseconds(Int.random(in: 1600...3000))) { $0.ack(id, from: to) }
        }
        let now = Date()
        guard !isReaction, !text.hasPrefix("WG "), !text.hasPrefix(BridgeOrigin.tagMeshCore), now >= replyAfter,
              let reply = Self.reply(to: to, channel: channel, turn: replies) else { return id }
        replies += 1
        let wait = Double.random(in: 5...9)
        replyAfter = now.addingTimeInterval(wait)
        later(.milliseconds(Int(wait * 1000))) { $0.deliver($0.chat(reply.text, from: reply.from, to: direct ? Self.me : .broadcast, channel: channel)) }
        return id
    }

    /// Who answers and what: DMs from the node you wrote to, the Primary channel from whoever's around.
    static func reply(to: NodeNum, channel: Int, turn: Int) -> (from: NodeNum, text: String)? {
        if to != .broadcast {
            let lines: [NodeNum: [String]] = [
                maya: ["Sounds good! See you by the windmill", "Ha, nice one 😄", "On my way"],
                kite: ["Hi from two hops out 👋", "Copy that"],
                lake: ["Lakeside here, loud and clear"],
                trail: ["Relay's fine, battery 4.1 V"],
            ]
            guard let options = lines[to] else { return nil }
            return (to, options[turn % options.count])
        }
        guard channel == 0 else { return nil }
        let lines: [(NodeNum, String)] = [
            (lake, "Loud and clear at the lake 👍"),
            (kite, "Got you, 2 hops via Lakeside"),
            (maya, "Copy! Fox hunt later?"),
            (trail, "Heard you on the trail relay"),
        ]
        let pick = lines[turn % lines.count]
        return (pick.0, pick.1)
    }

    /// How each practice node is heard: hops taken (of 3) and the relay's low byte.
    private static let heard: [NodeNum: (snr: Float, rssi: Int, hops: Int, relay: UInt32?)] = [
        lake: (5.5, -92, 1, 0x02),
        trail: (9.25, -78, 1, 0x01),
        maya: (7.0, -84, 1, 0x01),
        kite: (-4.25, -112, 2, 0x01),
    ]

    private func chat(_ text: String, from: NodeNum, to: NodeNum, channel: Int) -> MeshPacket {
        let h = Self.heard[from] ?? (6, -90, 1, nil)
        var p = MeshPacket(from: from, to: to, channel: channel, id: nextID(), rxTime: Date(),
                           rxSNR: h.snr + Float(Int.random(in: -2...2)) * 0.25, rxRSSI: h.rssi + Int.random(in: -2...2),
                           hopLimit: 3 - h.hops, hopStart: 3, viaMQTT: false, relayNode: h.relay, portnum: .text,
                           rawPortnum: 1, text: text, position: nil, isEncrypted: false)
        p.dataSize = MeshCodec.textDataSize(text)
        return p
    }

    private func ack(_ id: UInt32, from: NodeNum) {
        var p = MeshPacket(from: from, to: Self.me, id: nextID(), rxTime: Date(), portnum: .routing)
        p.requestID = id
        p.routingError = RoutingError.none
        deliver(p)
    }

    /// Runs `body` after `delay` while practice is still on.
    private func later(_ delay: Duration, _ body: @escaping (PracticeMesh) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.timer != nil else { return }
            body(self)
        }
    }

    /// Estimated time on air on LongFast (practice has no radio settings to read).
    static func airtime(bytes: Int) -> Int? {
        LoRaAirtime.milliseconds(bytes: bytes, spreadingFactor: 11, bandwidthKHz: 250, codingRate: 5)
    }

    /// What was said before you arrived: a few lines on Primary (LongFast) and a DM
    /// from MAYA, with the details a real node reports. Never saved.
    static func history(now: Date = Date()) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var id: UInt32 = 0x0F00_0000
        func add(_ from: NodeNum, _ text: String, in c: Conversation, ago: TimeInterval) {
            id += 1
            let h = heard[from] ?? (6, -90, 1, nil)
            let t = now.addingTimeInterval(-ago)
            var m = ChatMessage(packetID: id, from: from.id, conversation: c, text: text, time: t, outgoing: false,
                                status: .received, snr: Double(h.snr), rssi: h.rssi, hops: h.hops)
            m.radio = me.id
            m.receivedAt = t
            m.hopStart = 3
            m.hopLimit = 3 - h.hops
            m.relayNode = h.relay
            m.size = MeshCodec.headerSize + MeshCodec.textDataSize(text)
            m.airtimeMs = m.size.flatMap(airtime)
            m.practice = true
            out.append(m)
        }
        func mine(_ text: String, in c: Conversation, ago: TimeInterval, status: ChatMessage.Status, roundTripMs: Int? = nil) {
            id += 1
            var m = ChatMessage(packetID: id, from: me.id, conversation: c, text: text, time: now.addingTimeInterval(-ago),
                                outgoing: true, status: status)
            m.radio = me.id
            m.size = MeshCodec.headerSize + MeshCodec.textDataSize(text)
            m.airtimeMs = m.size.flatMap(airtime)
            m.roundTripMs = roundTripMs
            m.practice = true
            out.append(m)
        }
        let primary = Conversation.channel(slot: 0), dm = Conversation.direct(maya.id)
        add(lake, "Morning! LongFast is quiet today", in: primary, ago: 2000)
        add(kite, "Hi from the LongFast crowd 👋 anyone on MeshCore?", in: primary, ago: 1520)
        add(maya, "Are you coming to the park meetup Saturday?", in: dm, ago: 1200)
        mine("Yes! Bringing the spare antenna", in: dm, ago: 1140, status: .delivered, roundTripMs: 2140)
        add(maya, "Perfect, see you by the windmill", in: dm, ago: 1080)
        add(maya, "Practice fox is out near the lake 🦊", in: primary, ago: 1000)
        mine("Count me in for the fox hunt", in: primary, ago: 600, status: .sent)
        add(trail, "Relay's up on the trail, battery 4.1 V", in: primary, ago: 240)
        return out
    }

    /// What the hunter's app sent over the air.
    func receive(text: String, channel: Int) {
        let t = text.split(separator: " ").map(String.init)
        guard t.count >= 2, t[0] == "WG" else { return }
        var args = Array(t.dropFirst(2))
        if let first = args.first, first.uppercased().hasPrefix("FOX") {
            // A Hunt game's pieces (FOXK711…) have their own referee, never the practice Den.
            if HuntGame.isPieceCode(first) { return }
            args.removeFirst()
        }
        switch t[1] {
        case "JOIN":
            joined = true
            if started == nil { started = Date() }
            let name = args.first ?? "YOU"
            reply("WG OK JOIN FOX7 \(name) 1 HUNTING LIVE FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>")
        case "SIG":
            guard let r = args.first.flatMap({ Int($0) }) else { return }
            let trend: String
            if r >= -75 { trend = "HOT" }
            else if let last { trend = r - last >= 3 ? "WARMER" : r - last <= -3 ? "COLDER" : "STEADY" }
            else { trend = "FIRST" }
            let arrow = last.map { "\($0)>\(r)" } ?? "\(r)"
            last = r
            best = max(best ?? r, r)
            reply("WG W FOX7 \(trend) \(arrow) BEST \(best!) BRG 0\(Int.random(in: 40...55))" + (trend == "HOT" ? " · FOUND <code>" : ""))
        case "FOUND":
            if found { return }
            if args.first == Self.code {
                found = true
                let rf = (best ?? -200) >= -75
                reply("WG OK FOUND FOX7 #1 +\(rf ? 125 : 100) CODE\(rf ? "+RF-B" : "") \(clock)")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.reply("WG END FOX7 YOU WINS 1/1 FOUND")
                }
            } else if args.isEmpty {
                reply("WG NO FOUND FOX7 NEED CODE")
            } else {
                badCodes += 1
                reply(badCodes >= 5 ? "WG NO FOUND FOX7 LOCKED" : "WG NO FOUND FOX7 BADCODE \(badCodes)/5")
            }
        case "HUNT":
            reply("WG HUNT FOX7 LIVE \(clock) 1 HUNTERS \(found ? 1 : 0) FOUND FOX ZEUZ")
        case "LEAVE":
            joined = false
            reply("WG OK LEAVE FOX7")
        default:
            break
        }
    }
}
