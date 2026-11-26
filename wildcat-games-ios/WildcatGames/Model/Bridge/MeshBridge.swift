import Foundation
import Observation
import WildcatRadioCore

/// Relays text between a Meshtastic channel and a MeshCore channel through this
/// phone, which is connected to one node on each network. Bridged lines carry a
/// tag ("[MT] STAY: hi", "[MC] MAYA: Howdy") so they never bounce back; the
/// messages it posts also carry where each line was said as data (`BridgeOrigin`).
@MainActor
@Observable
final class MeshBridge {
    struct Line: Identifiable, Equatable, Codable {
        enum Way: String, Equatable, Codable { case toMeshCore, toMeshtastic }
        var id = UUID()
        var way: Way
        var text: String
        var at: Date
        /// A direct message instead of the bridged channel: a MeshCore contact's key
        /// prefix, or a Meshtastic node number.
        var dmMeshCore: Data? = nil
        var dmMeshtastic: NodeNum? = nil
        /// Who said it, where (nil for gifts).
        var origin: BridgeOrigin? = nil

        init(way: Way, text: String, at: Date, dmMeshCore: Data? = nil, dmMeshtastic: NodeNum? = nil, origin: BridgeOrigin? = nil) {
            self.way = way
            self.text = text
            self.at = at
            self.dmMeshCore = dmMeshCore
            self.dmMeshtastic = dmMeshtastic
            self.origin = origin
        }

        enum CodingKeys: String, CodingKey { case id, way, text, at, dmMeshCore, dmMeshtastic, origin }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            way = try c.decode(Way.self, forKey: .way)
            text = try c.decode(String.self, forKey: .text)
            at = try c.decode(Date.self, forKey: .at)
            dmMeshCore = try? c.decodeIfPresent(Data.self, forKey: .dmMeshCore)
            dmMeshtastic = (try? c.decodeIfPresent(UInt32.self, forKey: .dmMeshtastic)).flatMap { $0.map(NodeNum.init) }
            origin = try? c.decodeIfPresent(BridgeOrigin.self, forKey: .origin)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(way, forKey: .way)
            try c.encode(text, forKey: .text)
            try c.encode(at, forKey: .at)
            try c.encodeIfPresent(dmMeshCore, forKey: .dmMeshCore)
            try c.encodeIfPresent(dmMeshtastic?.raw, forKey: .dmMeshtastic)
            try c.encodeIfPresent(origin, forKey: .origin)
        }
    }

    /// Gift and receipt payloads already carried across (each crosses once).
    @ObservationIgnored private var carried: Set<Data> = []

    /// Who to send a DM reply back to on the other network.
    @ObservationIgnored private var replyToMeshtastic: [Data: NodeNum] = [:]   // MeshCore contact -> Meshtastic node
    @ObservationIgnored private var replyToMeshCore: [UInt32: Data] = [:]       // Meshtastic node -> MeshCore contact

    /// "@MAYA hello" -> ("MAYA", "hello").
    nonisolated static func mention(_ text: String) -> (name: String, rest: String)? {
        guard text.hasPrefix("@") else { return nil }
        let body = text.dropFirst()
        guard let sp = body.firstIndex(of: " ") else { return nil }
        let name = String(body[..<sp]), rest = body[body.index(after: sp)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty || rest.isEmpty ? nil : (name, rest)
    }

    /// A name matches when it equals the mention, or its first word does (case-insensitive).
    nonisolated static func matches(_ mention: String, name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let m = mention.lowercased(), n = name.lowercased()
        return n == m || n.split(separator: " ").first.map(String.init) == m
    }

    var enabled = false {
        didSet {
            defaults.set(enabled, forKey: "bridge.enabled")
            if enabled { offReason = nil } else { queue = [] }
        }
    }
    /// The channels are saved by name (the index is only a hint), so another
    /// node or a moved slot can't quietly put the bridge on someone else's channel.
    var meshtasticChannel: Int? {
        didSet {
            defaults.set(meshtasticChannel ?? -1, forKey: "bridge.mt")
            meshtasticName = meshtasticChannel.flatMap { radio.session.channels[$0]?.name }
            defaults.set(meshtasticName, forKey: "bridge.mtName")
            offReason = nil
        }
    }
    var meshcoreChannel: Int? {
        didSet {
            defaults.set(meshcoreChannel ?? -1, forKey: "bridge.mc")
            meshcoreName = meshcoreChannel.flatMap { meshcore.session.channels[$0]?.name }
            defaults.set(meshcoreName, forKey: "bridge.mcName")
            offReason = nil
        }
    }
    @ObservationIgnored private var meshtasticName: String?
    @ObservationIgnored private var meshcoreName: String?
    /// Why the bridge turned itself off (a saved channel is gone or public now).
    private(set) var offReason: String?
    /// What crossed, oldest first; kept across launches (the last `keepLog`).
    private(set) var log: [Line] = []
    static let keepLog = 100
    static let logKey = "bridge.log"

    nonisolated static let tagMT = BridgeOrigin.tagMeshtastic
    nonisolated static let tagMC = BridgeOrigin.tagMeshCore
    static let spacing: Duration = .seconds(3)
    /// Lines waiting to go out; past this the oldest are dropped (a busy channel can't pile up for hours).
    static let maxQueue = 20

    private let radio: Radio
    private let meshcore: MeshCoreLink
    private let messages: MessageStore
    private let defaults: UserDefaults
    @ObservationIgnored private var queue: [Line] = []
    @ObservationIgnored private var sending: Task<Void, Never>?

    init(radio: Radio, meshcore: MeshCoreLink, messages: MessageStore, defaults: UserDefaults = .standard) {
        self.radio = radio
        self.meshcore = meshcore
        self.messages = messages
        self.defaults = defaults
        enabled = defaults.bool(forKey: "bridge.enabled")
        let mt = defaults.object(forKey: "bridge.mt") as? Int ?? -1
        let mc = defaults.object(forKey: "bridge.mc") as? Int ?? -1
        meshtasticChannel = mt >= 0 ? mt : nil
        meshcoreChannel = mc >= 0 ? mc : nil
        meshtasticName = defaults.string(forKey: "bridge.mtName")
        meshcoreName = defaults.string(forKey: "bridge.mcName")
        if let d = defaults.data(forKey: Self.logKey), let saved = try? JSONDecoder().decode([Line].self, from: d) {
            log = Array(saved.suffix(Self.keepLog))
        }
        radio.addListener { [weak self] in self?.fromMeshtastic($0) }
        meshcore.addListener { [weak self] in self?.fromMeshCore($0) }
    }

    /// Both nodes connected, and both chosen channels are there, private, and still the saved ones.
    var isLive: Bool {
        enabled && radio.isReady && meshcore.state.isReady && channelsOK
    }

    private var channelsOK: Bool {
        guard let mt = meshtasticChannel, let mc = meshcoreChannel,
              let a = radio.session.channels[mt], let b = meshcore.session.channels[mc] else { return false }
        return !Self.isPublic(meshtastic: a) && !Self.isPublic(meshcore: b)
            && (meshtasticName == nil || a.name == meshtasticName) && (meshcoreName == nil || b.name == meshcoreName)
    }

    /// The slot holding the saved channel: the hinted index when its name still matches,
    /// else the one slot with that name. Nil when it's gone (or the name is ambiguous).
    nonisolated static func resolve(name: String?, hint: Int?, in channels: [(index: Int, name: String)]) -> Int? {
        guard let name else { return hint.flatMap { h in channels.contains { $0.index == h } ? h : nil } }
        if let hint, channels.contains(where: { $0.index == hint && $0.name == name }) { return hint }
        let matches = channels.filter { $0.name == name }
        return matches.count == 1 ? matches[0].index : nil
    }

    /// With both nodes connected: follows a saved channel that moved slot, and turns
    /// the bridge off (saying why) when one is gone or public.
    private func check() {
        guard enabled, radio.isReady, meshcore.state.isReady else { return }
        let mtList = radio.session.channels.values.map { (index: $0.index, name: $0.name) }
        let mcList = meshcore.session.channels.values.map { (index: $0.index, name: $0.name) }
        guard let mt = Self.resolve(name: meshtasticName, hint: meshtasticChannel, in: mtList) else {
            return turnOff("The Meshtastic channel \(Self.quoted(meshtasticName)) isn't on this node. Choose the channels again.")
        }
        guard let mc = Self.resolve(name: meshcoreName, hint: meshcoreChannel, in: mcList) else {
            return turnOff("The MeshCore channel \(Self.quoted(meshcoreName)) isn't on this node. Choose the channels again.")
        }
        if mt != meshtasticChannel { note("Meshtastic channel moved to slot \(mt)"); meshtasticChannel = mt }
        if mc != meshcoreChannel { note("MeshCore channel moved to slot \(mc)"); meshcoreChannel = mc }
        // Saved before names were kept: remember them now.
        if meshtasticName == nil { meshtasticChannel = mt }
        if meshcoreName == nil { meshcoreChannel = mc }
        if Self.isPublic(meshtastic: radio.session.channels[mt]) {
            return turnOff("The Meshtastic channel \(Self.quoted(meshtasticName)) is public, so the bridge is off.")
        }
        if Self.isPublic(meshcore: meshcore.session.channels[mc]) {
            return turnOff("The MeshCore channel \(Self.quoted(meshcoreName)) is public, so the bridge is off.")
        }
    }

    private static func quoted(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "you chose" }
        return "\"\(name)\""
    }

    private func turnOff(_ why: String) {
        enabled = false
        offReason = why
        note("off: " + why)
    }

    /// Public channels belong to everyone: bridging them floods other people's mesh.
    static func isPublic(meshtastic c: ChannelInfo?) -> Bool {
        guard let s = c?.settings.map(ChannelSettings.init) else { return true }
        return s.keyKind != "private"
    }

    static func isPublic(meshcore c: MeshCoreSession.Channel?) -> Bool {
        guard let c else { return true }
        return c.index == 0 || c.name.lowercased() == "public"
    }

    nonisolated static func isBridged(_ text: String) -> Bool {
        text.contains(tagMT) || text.contains(tagMC)
    }

    /// "[MT] GO: What?" -> ("GO", "Meshtastic", "What?"), for showing relayed lines as arrivals.
    nonisolated static func parse(_ text: String) -> (sender: String, network: String, text: String)? {
        for (tag, network) in [(tagMT, "Meshtastic"), (tagMC, "MeshCore")] where text.hasPrefix(tag + " ") {
            let rest = text.dropFirst(tag.count + 1)
            guard let r = rest.range(of: ": ") else { return (network, network, String(rest)) }
            return (String(rest[..<r.lowerBound]), network, String(rest[r.upperBound...]))
        }
        return nil
    }

    /// Blocked senders never cross, either way (set by the app).
    @ObservationIgnored var safety: Safety?

    /// Bridge decisions for the radio log.
    @ObservationIgnored var onNote: ((String) -> Void)?
    private func note(_ s: String) { onNote?("Bridge " + s) }

    // MARK: Sent from this phone

    /// You typed on a bridged Meshtastic channel in Wildcat: post it to MeshCore too.
    func sentFromHere(meshtastic channel: Int, text: String) {
        guard channel == meshtasticChannel else { return }
        guard isLive else { note("off or not both connected: your Meshtastic message stays on Meshtastic"); return }
        let me = radio.session.myNode.flatMap { radio.session.nodes[$0]?.shortName } ?? "me"
        let origin = BridgeOrigin(network: .meshtastic, senderID: radio.session.myNode?.id, senderName: me,
                                  channel: meshtasticChannelName(channel), heardBy: radio.session.myNode?.id,
                                  via: meshcore.session.me?.name)
        enqueue(Line(way: .toMeshCore, text: "\(Self.tagMT) \(me): \(text)", at: Date(), origin: origin))
    }

    /// You typed on the bridged MeshCore channel in Wildcat: post it to Meshtastic too.
    func sentFromHere(meshcore channel: Int, text: String) {
        guard channel == meshcoreChannel else { return }
        guard isLive else { note("off or not both connected: your MeshCore message stays on MeshCore"); return }
        let me = meshcore.session.me?.name ?? "me"
        let origin = BridgeOrigin(network: .meshcore, senderID: meshcore.session.me.map { MeshCoreStore.hex($0.publicKey.prefix(6)) },
                                  senderName: me, channel: meshcore.session.channels[channel]?.name,
                                  heardBy: meshcore.session.radioID, via: radio.session.myNode?.id)
        enqueue(Line(way: .toMeshtastic, text: "\(Self.tagMC) \(me): \(text)", at: Date(), origin: origin))
    }

    // MARK: Relaying

    /// Geo Gifts (and their opened receipts) cross the bridge too: Meshtastic
    /// PRIVATE_APP on the bridged channel <-> MeshCore datagrams on the bridged channel.
    private func carryGift(_ payload: Data, toMeshCore: Bool) {
        guard isLive, GiftCodec.decode(payload) != nil || GiftCodec.receiptID(payload) != nil,
              carried.insert(payload).inserted, let mt = meshtasticChannel, let mc = meshcoreChannel else { return }
        if toMeshCore {
            guard meshcore.sendData(payload, channel: mc) else { note("gift too big for MeshCore (\(payload.count) bytes)"); return }
            note("carried a gift to MeshCore")
        } else {
            radio.link?.sendPrivate(payload, to: .broadcast, channel: mt)
            note("carried a gift to Meshtastic")
        }
        record(Line(way: toMeshCore ? .toMeshCore : .toMeshtastic, text: "🎁 Geo Gift (\(payload.count) bytes)", at: Date()))
    }

    private func fromMeshtastic(_ e: MeshSession.Event) {
        if case .ready = e { check() } else if enabled, !isLive { check() }
        if isLive, case .packet(let p) = e, p.portnum == .privateApp, p.isBroadcast, p.channel == meshtasticChannel,
           p.from != radio.session.myNode, let payload = p.payload {
            carryGift(payload, toMeshCore: true)
            return
        }
        guard isLive, case .packet(let p) = e, let text = p.text, p.from != radio.session.myNode, !Self.isBridged(text) else { return }
        let who = radio.session.nodes[p.from]?.shortName ?? p.from.short
        if safety?.hides(meshtasticNode: p.from.id, named: who) == true { note("\(who) is blocked: not relayed"); return }
        let origin = BridgeOrigin(network: .meshtastic, senderID: p.from.id, senderName: who,
                                  channel: p.isBroadcast ? meshtasticChannelName(p.channel) : nil, hops: p.hops,
                                  heardBy: radio.session.myNode?.id, via: meshcore.session.me?.name)
        // A direct reply to this node from someone a MeshCore user wrote to: send it back to them.
        if !p.isBroadcast, p.to == radio.session.myNode, let target = replyToMeshCore[p.from.raw] {
            note("DM reply from \(who): relaying to MeshCore")
            enqueue(Line(way: .toMeshCore, text: "\(Self.tagMT) \(who): \(text)", at: Date(), dmMeshCore: target, origin: origin))
            return
        }
        guard p.isBroadcast, p.channel == meshtasticChannel else { return }
        // "@name message" on the bridged channel: a private message to that MeshCore contact.
        if let (name, rest) = Self.mention(text),
           let c = meshcore.session.contacts.values.first(where: { Self.matches(name, name: $0.name) }) {
            note("\(who) mentioned \(c.name): direct message on MeshCore")
            replyToMeshtastic[c.prefix] = p.from
            enqueue(Line(way: .toMeshCore, text: "\(Self.tagMT) \(who): \(rest)", at: Date(), dmMeshCore: c.prefix, origin: origin))
            return
        }
        note("heard \(who) on Meshtastic channel \(p.channel): relaying to MeshCore")
        enqueue(Line(way: .toMeshCore, text: "\(Self.tagMT) \(who): \(text)", at: Date(), origin: origin))
    }

    private func fromMeshCore(_ e: MeshCoreSession.Event) {
        if case .ready = e { check() } else if enabled, !isLive { check() }
        if isLive, case .datagram(let ch, let dt, let payload, _) = e, dt == MeshCore.wildcatDataType, ch == meshcoreChannel {
            carryGift(payload, toMeshCore: false)
            return
        }
        guard isLive, case .message(let chat) = e, chat.direction == .received, chat.textType != 1,
              !Self.isBridged(chat.text) else { return }
        if safety?.hides(chat) == true { note("a blocked sender on MeshCore: not relayed"); return }
        // A direct reply from a MeshCore contact someone on Meshtastic wrote to.
        if case .contact(let prefix) = chat.origin {
            guard let target = replyToMeshtastic[prefix] else { return }
            let who = meshcore.session.label(chat.origin)
            note("DM reply from \(who): relaying to Meshtastic")
            enqueue(Line(way: .toMeshtastic, text: "\(Self.tagMC) \(who): \(chat.text)", at: Date(), dmMeshtastic: target,
                         origin: meshcoreOrigin(chat, sender: who, senderID: MeshCoreStore.hex(prefix))))
            return
        }
        guard chat.origin == .channel(meshcoreChannel ?? -1) else { return }
        // "Sender: @STAY hi" on the bridged channel: a private message to that Meshtastic node.
        if let r = chat.text.range(of: ": ") {
            let sender = String(chat.text[..<r.lowerBound])
            if let (name, rest) = Self.mention(String(chat.text[r.upperBound...])),
               let node = radio.session.nodes.values.first(where: { Self.matches(name, name: $0.shortName) || Self.matches(name, name: $0.longName) }) {
                note("\(sender) mentioned \(node.shortName ?? node.num.id): direct message on Meshtastic")
                if let c = meshcore.session.contacts.values.first(where: { Self.matches(sender, name: $0.name) }) {
                    replyToMeshCore[node.num.raw] = c.prefix
                }
                enqueue(Line(way: .toMeshtastic, text: "\(Self.tagMC) \(sender): \(rest)", at: Date(), dmMeshtastic: node.num,
                             origin: meshcoreOrigin(chat, sender: sender)))
                return
            }
        }
        // MeshCore channel text already reads "Sender: message".
        note("heard MeshCore channel \(meshcoreChannel ?? -1): relaying to Meshtastic")
        enqueue(Line(way: .toMeshtastic, text: "\(Self.tagMC) \(chat.text)", at: Date(),
                     origin: chat.channelSender.map { meshcoreOrigin(chat, sender: $0) }))
    }

    /// A MeshCore line's origin; channel senders are known by name only, so their key
    /// comes from a contact with that name when there's exactly one.
    private func meshcoreOrigin(_ chat: MeshCoreSession.Chat, sender: String, senderID: String? = nil) -> BridgeOrigin {
        var channel: String?
        if case .channel(let i) = chat.origin { channel = meshcore.session.channels[i]?.name }
        let named = meshcore.session.contacts.values.filter { $0.name == sender }
        return BridgeOrigin(network: .meshcore, senderID: senderID ?? (named.count == 1 ? MeshCoreStore.hex(named[0].prefix) : nil),
                            senderName: sender, channel: channel, hops: chat.hops, heardBy: meshcore.session.radioID,
                            via: radio.session.myNode?.id)
    }

    private func meshtasticChannelName(_ i: Int) -> String? {
        guard let name = radio.session.channels[i]?.name else { return nil }
        return name.isEmpty ? (i == 0 ? "Primary" : nil) : name
    }

    private func record(_ l: Line) {
        log.append(l)
        if log.count > Self.keepLog { log.removeFirst(log.count - Self.keepLog) }
        if let d = try? JSONEncoder().encode(log) { defaults.set(d, forKey: Self.logKey) }
    }

    private func enqueue(_ l: Line) {
        queue.append(l)
        if queue.count > Self.maxQueue {
            queue.removeFirst(queue.count - Self.maxQueue)
            note("too much to relay: dropped the oldest waiting line")
        }
        guard sending == nil else { return }
        sending = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let l = self.queue.removeFirst()
                self.send(l)
                try? await Task.sleep(for: Self.spacing)
            }
            self?.sending = nil
        }
    }

    private func send(_ l: Line) {
        guard isLive, let mt = meshtasticChannel, let mc = meshcoreChannel else { return }
        let mcText = l.text.utf8Prefix(MeshCore.maxTextBytes)
        let mtText = l.text.utf8Prefix(MeshCodec.maxTextBytes)
        switch l.way {
        case .toMeshCore:
            let id: UUID
            if let p = l.dmMeshCore, let c = meshcore.session.contact(prefix: p) {
                id = meshcore.send(text: mcText, to: c)
            } else {
                id = meshcore.send(text: mcText, channel: mc)
            }
            if let o = l.origin { meshcore.setBridged(o, on: id) }
        case .toMeshtastic:
            // Through the message store, so the line shows in Wildcat's Meshtastic threads too.
            if let n = l.dmMeshtastic {
                _ = messages.send(mtText, in: .direct(n.id), bridged: l.origin)
            } else {
                _ = messages.send(mtText, in: .channel(slot: mt), bridged: l.origin)
            }
        }
        note("sent \(l.way == .toMeshCore ? "to MeshCore" : "to Meshtastic") (\(l.text.utf8.count) bytes)")
        record(l)
    }
}
