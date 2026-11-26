import Foundation
import Observation
import UserNotifications
import WildcatRadioCore

struct ChatMessage: Codable, Equatable, Identifiable {
    enum Status: Equatable, Codable {
        case received
        case sending
        /// A neighbour rebroadcast it (implicit ack): it went out on the mesh.
        case sent
        /// The recipient acknowledged it.
        case delivered
        case failed(String)
    }

    var id = UUID()
    var packetID: UInt32
    var from: String
    var conversation: Conversation
    var text: String
    var time: Date
    var outgoing: Bool
    var status: Status
    var replyTo: UInt32?
    /// Emoji -> the node ids that reacted with it.
    var reactions: [String: [String]] = [:]
    var snr: Double?
    var rssi: Int?
    var hops: Int?
    var viaMQTT: Bool = false

    // Message details. All optional: older saves (and practice messages) lack them.

    /// The local node it came through or went out on ("!xxxxxxxx").
    var radio: String?
    /// When the node received it (its own clock); `time` is when this phone got it,
    /// later when the node held it while the phone was away.
    var receivedAt: Date?
    /// Hop limit it started with and had left; hops = start - limit.
    var hopStart: Int?
    var hopLimit: Int?
    /// Low byte of the node that relayed it to us last (the firmware keeps only that byte).
    var relayNode: UInt32?
    /// Estimated bytes on air (16-byte header + the encrypted payload) and time on air.
    var size: Int?
    var airtimeMs: Int?
    /// Sent direct messages: from sending to the recipient's ack.
    var roundTripMs: Int?
    /// A bridged line: where it was really said.
    var bridged: BridgeOrigin?
    /// The MeshPacket as the node handed it over (only with "Keep raw packets" on).
    var raw: Data?
    /// Said on the practice mesh: shown while practice runs, never saved.
    var practice = false
}

extension ChatMessage {
    /// Fields with a default may be missing (saved by another version): they
    /// take the default instead of making the whole history unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        packetID = try c.decode(UInt32.self, forKey: .packetID)
        from = try c.decode(String.self, forKey: .from)
        conversation = try c.decode(Conversation.self, forKey: .conversation)
        text = try c.decode(String.self, forKey: .text)
        time = try c.decode(Date.self, forKey: .time)
        outgoing = try c.decode(Bool.self, forKey: .outgoing)
        status = try c.decode(Status.self, forKey: .status)
        replyTo = try c.decodeIfPresent(UInt32.self, forKey: .replyTo)
        reactions = try c.decodeIfPresent([String: [String]].self, forKey: .reactions) ?? [:]
        snr = try c.decodeIfPresent(Double.self, forKey: .snr)
        rssi = try c.decodeIfPresent(Int.self, forKey: .rssi)
        hops = try c.decodeIfPresent(Int.self, forKey: .hops)
        viaMQTT = try c.decodeIfPresent(Bool.self, forKey: .viaMQTT) ?? false
        // Details: a bad value loses that detail, never the message.
        radio = try? c.decodeIfPresent(String.self, forKey: .radio)
        receivedAt = try? c.decodeIfPresent(Date.self, forKey: .receivedAt)
        hopStart = try? c.decodeIfPresent(Int.self, forKey: .hopStart)
        hopLimit = try? c.decodeIfPresent(Int.self, forKey: .hopLimit)
        relayNode = try? c.decodeIfPresent(UInt32.self, forKey: .relayNode)
        size = try? c.decodeIfPresent(Int.self, forKey: .size)
        airtimeMs = try? c.decodeIfPresent(Int.self, forKey: .airtimeMs)
        roundTripMs = try? c.decodeIfPresent(Int.self, forKey: .roundTripMs)
        bridged = try? c.decodeIfPresent(BridgeOrigin.self, forKey: .bridged)
        raw = try? c.decodeIfPresent(Data.self, forKey: .raw)
    }

    enum CodingKeys: String, CodingKey {
        case id, packetID, from, conversation, text, time, outgoing, status, replyTo, reactions, snr, rssi, hops, viaMQTT
        case radio, receivedAt, hopStart, hopLimit, relayNode, size, airtimeMs, roundTripMs, bridged, raw
    }
}

/// Every Meshtastic conversation on the player's radio: channels and direct messages,
/// with delivery status, replies and reactions. Each radio keeps its own history on
/// the phone (`meshtastic-<node>.json`); channels are filed by name and key, not slot.
/// While no radio is connected it serves the last radio's saved chats, read-only.
@MainActor
@Observable
final class MessageStore {
    /// A channel row in Messages: its identity, and its slot and name as far as known.
    struct ChannelEntry: Identifiable, Hashable {
        let key: ChannelKey
        /// The slot on the radio (live or as last saved); nil for a channel the radio no longer has.
        var slot: Int?
        var name: String
        var primary = false
        var id: ChannelKey { key }
        var conversation: Conversation { .channel(key) }
    }

    private(set) var messages: [ChatMessage] = []
    /// Sent messages another node confirmed since launch, practice left out (the ratings prompt watches it).
    private(set) var deliveredCount = 0
    private var lastRead: [String: Date] = [:]
    /// The shown history's channels, as of its radio's last connection.
    private(set) var channels: [MeshtasticHistory.SavedChannel] = []
    /// The radio whose history is shown ("!xxxxxxxx"): the connected one, else the last one (nil: none yet).
    private(set) var historyNode: String?
    /// That radio's name, when the save knows it.
    private(set) var historyName: String?
    /// Other radios with saved chats, newest first (id and name).
    private(set) var otherHistories: [(node: String, name: String?)] = []
    /// The conversation on screen (its messages are read as they arrive).
    var open: Conversation?
    var isForeground = true
    /// Blocks and the word filter (set by the app; none in tests).
    @ObservationIgnored var safety: Safety?
    /// Keep each message's raw packet (the "Keep raw packets" debug setting, off by default).
    @ObservationIgnored var keepsRawPackets = false
    static let keepRawKey = "debug.keepRawPackets"
    /// Which radio's history was shown last, for reading it before a connection.
    static let lastArchiveKey = MeshtasticHistory.lastArchiveKey

    @ObservationIgnored private let radio: Radio
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let saver = Debouncer(.seconds(5))
    @ObservationIgnored private var dirty = false
    /// The shown history is the practice mesh's (in memory only).
    @ObservationIgnored private var practiceHistory = false
    /// Messages kept per radio (memory and file); the oldest go first.
    static let limit = 5000
    /// False: messages on the practice mesh are pretend (kept apart, never saved). Tests
    /// that use the practice radio as a stand-in node set it true.
    @ObservationIgnored private let savesPractice: Bool

    init(radio: Radio, folder: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
         defaults: UserDefaults = .standard, savesPractice: Bool = false) {
        self.radio = radio
        self.folder = folder
        self.defaults = defaults
        self.savesPractice = savesPractice
        if let folder {
            MessageMigration.run(folder: folder, cache: MeshtasticCache.load(defaults), defaults: defaults)
        }
        if radio.isReady, let me = radio.session.myNode {
            attach(me.id)
        } else {
            loadLastArchive()
        }
        radio.addListener { [weak self] in self?.handle($0) }
        radio.onPracticeEnd { [weak self] in self?.dropPractice() }
    }

    private var isPractice: Bool { radio.source == .practice && !savesPractice }

    /// The shown history belongs to the connected radio (messages can be sent).
    var isLive: Bool { radio.isReady && radio.session.myNode?.id == historyNode }

    /// No radio connected, showing a saved history (nothing can be sent).
    var isOffline: Bool { !radio.isReady && historyNode != nil }

    /// The shown radio's name, else its id ("earlier radio" for chats saved before radios were recorded).
    var historyLabel: String? {
        guard let historyNode else { return nil }
        if let historyName, !historyName.isEmpty { return historyName }
        return historyNode == MeshtasticHistory.unknownNode ? "earlier radio" : historyNode
    }

    // MARK: Which history

    private func url(_ node: String) -> URL? { folder?.appendingPathComponent(MeshtasticHistory.fileName(node: node)) }

    /// Switches to `node`'s history: the connected radio's (loaded from its file, or started
    /// empty), or the practice mesh's made-up one.
    private func attach(_ node: String) {
        if historyNode == node, practiceHistory == isPractice { return }
        flush()
        historyNode = node
        if isPractice {
            practiceHistory = true
            apply(MeshtasticHistory(messages: PracticeMesh.history(), node: "Practice Handheld"))
        } else {
            practiceHistory = false
            apply(load(node) ?? adoptUnknown(for: node) ?? MeshtasticHistory())
            defaults.set(node, forKey: Self.lastArchiveKey)
        }
        refreshChannels()
        heal()
        listOthers()
    }

    private func apply(_ h: MeshtasticHistory) {
        // Referee lines saved by older builds ("WG …") aren't chats.
        messages = Array(h.messages.filter { $0.outgoing || !$0.text.hasPrefix("WG ") }.suffix(Self.limit))
        // Anything still "sending" from a previous run never got an answer.
        for i in messages.indices where messages[i].status == .sending { messages[i].status = .failed("No answer") }
        lastRead = h.lastRead
        channels = h.channels
        historyName = h.node
        dirty = false
    }

    private func load(_ node: String) -> MeshtasticHistory? {
        guard let u = url(node) else { return nil }
        // An unreadable file is set aside (….json.bad-…), never overwritten.
        return SaveFile.load(MeshtasticHistory.self, from: u, decoder: MeshtasticHistory.decoder())
    }

    /// Chats saved before messages recorded their radio belong to the first real radio
    /// that connects without a history of its own: its file takes them over.
    private func adoptUnknown(for node: String) -> MeshtasticHistory? {
        guard node != MeshtasticHistory.unknownNode, let from = url(MeshtasticHistory.unknownNode), let to = url(node),
              FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else { return nil }
        try? FileManager.default.moveItem(at: from, to: to)
        return load(node)
    }

    /// Writes the shown real history now if it changed, before switching away or quitting.
    private func flush() {
        saver.cancel()
        guard dirty, !practiceHistory, let historyNode, let u = url(historyNode) else { return }
        SaveFile.writeNow(history(), to: u, encoder: MeshtasticHistory.encoder())
        dirty = false
    }

    /// The last radio's file: the one used last, or (saved before that was noted) the newest.
    private func lastArchiveNode() -> String? {
        if let n = defaults.string(forKey: Self.lastArchiveKey), let u = url(n), FileManager.default.fileExists(atPath: u.path) { return n }
        return savedNodes().first
    }

    /// Every radio with a history file, newest first.
    private func savedNodes() -> [String] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { MeshtasticHistory.node(ofFile: $0.lastPathComponent) != nil }
            .sorted { modified($0) > modified($1) }
            .compactMap { MeshtasticHistory.node(ofFile: $0.lastPathComponent) }
    }

    /// Reads the last radio's save for showing while disconnected.
    private func loadLastArchive() {
        flush()
        practiceHistory = false
        guard let node = lastArchiveNode(), let h = load(node) else {
            historyNode = nil
            apply(MeshtasticHistory())
            listOthers()
            return
        }
        historyNode = node
        apply(h)
        listOthers()
    }

    /// Shows another radio's saved chats (while nothing is connected).
    func show(saved node: String) {
        guard !radio.isReady, node != historyNode, let h = load(node) else { return }
        flush()
        practiceHistory = false
        historyNode = node
        apply(h)
        listOthers()
    }

    private func listOthers() {
        otherHistories = savedNodes().filter { $0 != historyNode }.map { node in
            let name = url(node).flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? MeshtasticHistory.decoder().decode(MeshtasticHistory.Head.self, from: $0) }?.node
            return (node, name)
        }
    }

    /// Practice starts with a short made-up history (a second start begins again).
    private func startPractice() {
        if historyNode == PracticeMesh.me.id, practiceHistory {
            messages = PracticeMesh.history()
            lastRead = [:]
        } else {
            attach(PracticeMesh.me.id)
        }
    }

    private func dropPractice() {
        guard practiceHistory else { return }
        historyNode = nil
        loadLastArchive()
    }

    /// Practice chats keep only their newest few.
    private func trimPractice(_ c: Conversation) {
        let ids = messages.filter { $0.practice && $0.conversation == c }.map(\.id)
        guard ids.count > PracticeMesh.keepPerChat else { return }
        let drop = Set(ids.prefix(ids.count - PracticeMesh.keepPerChat))
        messages.removeAll { drop.contains($0.id) }
    }

    // MARK: Channels

    /// The connected radio's channels, when its history is the one shown.
    private var liveChannels: [ChannelInfo] {
        guard isLive else { return [] }
        return radio.session.channels.values.filter { $0.role != .disabled }.sorted { $0.index < $1.index }
    }

    /// The radio's channel table to resolve slot keys against: the connected radio's, else as last saved.
    private var table: [MeshtasticHistory.SavedChannel] {
        isLive ? liveChannels.map { .init(slot: $0.index, name: $0.name, key: ChannelKey(info: $0), primary: $0.role == .primary) } : channels
    }

    /// The channel a slot key stands for in `table`: by name where one channel has it (it may
    /// have moved slot), else the one in that slot with the same name (or any, unnamed). Nil: none.
    nonisolated static func resolve(_ k: ChannelKey, in table: [MeshtasticHistory.SavedChannel]) -> ChannelKey? {
        guard k.isFallback else { return k }
        if !k.name.isEmpty {
            let named = table.filter { $0.name == k.name }
            if named.count == 1 { return named[0].key }
        }
        if let slot = k.fallbackSlot, let c = table.first(where: { $0.slot == slot }), k.name.isEmpty || c.name == k.name { return c.key }
        return nil
    }

    /// The real channel a slot key stands for on the radio (see `resolve`); other conversations are themselves.
    func resolved(_ c: Conversation) -> Conversation {
        guard case .channel(let k) = c, k.isFallback, let real = Self.resolve(k, in: table) else { return c }
        return .channel(real)
    }

    /// Slot keys in a radio's history (older saves, migrated chats) rewritten to the identity
    /// of the channel now in that slot or with that name, read marks with them. True when anything changed.
    nonisolated static func heal(_ h: inout MeshtasticHistory, channels table: [MeshtasticHistory.SavedChannel]) -> Bool {
        var map: [ChannelKey: ChannelKey] = [:]
        func target(_ k: ChannelKey) -> ChannelKey? {
            if let t = map[k] { return t }
            guard k.isFallback, let real = resolve(k, in: table), real != k else { return nil }
            map[k] = real
            return real
        }
        var changed = false
        for i in h.messages.indices {
            guard case .channel(let k) = h.messages[i].conversation, let real = target(k) else { continue }
            h.messages[i].conversation = .channel(real)
            changed = true
        }
        for (key, date) in h.lastRead where key.hasPrefix("ch:") {
            guard let real = target(ChannelKey(rawValue: String(key.dropFirst(3)))) else { continue }
            let newKey = Conversation.channel(real).key
            h.lastRead[newKey] = max(h.lastRead[newKey] ?? .distantPast, date)
            h.lastRead[key] = nil
            changed = true
        }
        return changed
    }

    /// The channel in `slot` on the connected radio (or, disconnected, as last saved).
    func conversation(slot: Int) -> Conversation? {
        let c = resolved(.channel(slot: slot))
        if isLive { return liveChannels.contains { $0.index == slot } ? c : nil }
        guard case .channel(let k) = c, channels.contains(where: { $0.key == k }) else { return nil }
        return c
    }

    /// The channels of the shown history: the radio's (live, else as last saved) in slot order,
    /// then any with saved chat that the radio no longer has.
    var channelEntries: [ChannelEntry] {
        var out: [ChannelEntry]
        if isLive {
            out = liveChannels.map { ChannelEntry(key: ChannelKey(info: $0), slot: $0.index, name: $0.name, primary: $0.role == .primary) }
            if out.isEmpty { out = [ChannelEntry(key: ChannelKey(name: "", slot: 0), slot: 0, name: "", primary: true)] }
        } else {
            out = channels.sorted { $0.slot < $1.slot }.map { ChannelEntry(key: $0.key, slot: $0.slot, name: $0.name, primary: $0.primary) }
        }
        var known = Set(out.map(\.key))
        for m in messages.reversed() where !isHidden(m) {
            guard case .channel(let k) = resolved(m.conversation), known.insert(k).inserted else { continue }
            out.append(ChannelEntry(key: k, slot: k.fallbackSlot, name: k.name, primary: false))
        }
        return out
    }

    /// Slot and name for a channel conversation (nil for direct ones).
    func entry(for c: Conversation) -> ChannelEntry? {
        guard case .channel(let k) = resolved(c) else { return nil }
        if let info = liveChannels.first(where: { ChannelKey(info: $0) == k }) {
            return ChannelEntry(key: k, slot: info.index, name: info.name, primary: info.role == .primary)
        }
        if !isLive, let saved = channels.first(where: { $0.key == k }) {
            return ChannelEntry(key: k, slot: saved.slot, name: saved.name, primary: saved.primary)
        }
        return ChannelEntry(key: k, slot: isLive ? nil : k.fallbackSlot, name: k.name, primary: false)
    }

    /// The slot a channel conversation sits in on the connected radio (nil: not there, or not connected).
    func slot(of c: Conversation) -> Int? {
        guard isLive, case .channel(let k) = resolved(c) else { return nil }
        return liveChannels.first { ChannelKey(info: $0) == k }?.index
    }

    /// The connected radio's channel table, kept in its history for reading while disconnected.
    private func refreshChannels() {
        guard isLive else { return }
        channels = liveChannels.map { .init(slot: $0.index, name: $0.name, key: ChannelKey(info: $0), primary: $0.role == .primary) }
        if let me = radio.session.myNode, let name = radio.session.nodes[me]?.longName, !name.isEmpty { historyName = name }
    }

    /// Slot keys in this radio's history (older saves, migrated chats) become the real
    /// identity of the channel now in that slot or with that name, read marks with them.
    private func heal() {
        guard isLive else { return }
        var map: [ChannelKey: ChannelKey] = [:]
        func target(_ k: ChannelKey) -> ChannelKey? {
            if let t = map[k] { return t }
            guard k.isFallback, case .channel(let real) = resolved(.channel(k)), real != k else { return nil }
            map[k] = real
            return real
        }
        var changed = false
        for i in messages.indices {
            guard case .channel(let k) = messages[i].conversation, let real = target(k) else { continue }
            messages[i].conversation = .channel(real)
            changed = true
        }
        for (key, date) in lastRead where key.hasPrefix("ch:") {
            let k = ChannelKey(rawValue: String(key.dropFirst(3)))
            guard let real = target(k) else { continue }
            let newKey = Conversation.channel(real).key
            lastRead[newKey] = max(lastRead[newKey] ?? .distantPast, date)
            lastRead[key] = nil
            changed = true
        }
        if let o = open, case .channel(let k) = o, let real = target(k) { open = .channel(real) }
        if changed { scheduleSave() }
    }

    // MARK: Queries

    /// From someone the player blocked: never listed, counted or notified.
    func isHidden(_ m: ChatMessage) -> Bool { safety?.hides(m) ?? false }

    func messages(in c: Conversation) -> [ChatMessage] {
        let rc = resolved(c)
        return messages.filter { resolved($0.conversation) == rc && !isHidden($0) }
    }

    func last(in c: Conversation) -> ChatMessage? {
        let rc = resolved(c)
        return messages.last { resolved($0.conversation) == rc && !isHidden($0) }
    }

    func unread(in c: Conversation) -> Int {
        let rc = resolved(c)
        let since = lastRead[rc.key] ?? lastRead[c.key] ?? .distantPast
        return messages.filter { resolved($0.conversation) == rc && !$0.outgoing && $0.time > since && !isHidden($0) }.count
    }

    var totalUnread: Int {
        Set(messages.map { resolved($0.conversation) }).reduce(0) { $0 + unread(in: $1) }
    }

    var directThreads: [String] {
        var seen = Set<String>()
        return messages.reversed().compactMap { m -> String? in
            guard case .direct(let id) = m.conversation, safety?.hides(meshtasticNode: id) != true,
                  seen.insert(id).inserted else { return nil }
            return id
        }
    }

    func message(packetID: UInt32) -> ChatMessage? { messages.last { $0.packetID == packetID } }

    func markRead(_ c: Conversation) {
        lastRead[resolved(c).key] = Date()
        scheduleSave()
    }

    // MARK: Sending

    /// Sends and records a message; returns false when the node isn't ready or the channel
    /// isn't on it. `bridged`: the bridge is posting a line from the other network.
    @discardableResult
    func send(_ text: String, in c: Conversation, replyTo: UInt32? = nil, bridged: BridgeOrigin? = nil) -> Bool {
        let c = resolved(c)
        guard let (to, channel) = route(c), let me = radio.session.myNode,
              let id = radio.sendText(text, to: to, channel: channel, replyID: replyTo) else { return false }
        var m = ChatMessage(packetID: id, from: me.id, conversation: c, text: text, time: Date(),
                            outgoing: true, status: .sending, replyTo: replyTo)
        m.radio = me.id
        m.size = MeshCodec.headerSize + MeshCodec.textDataSize(text, replyID: replyTo)
        m.airtimeMs = m.size.flatMap { radio.session.lora?.airtime(bytes: $0) ?? (isPractice ? PracticeMesh.airtime(bytes: $0) : nil) }
        m.bridged = bridged
        m.practice = isPractice
        messages.append(m)
        if m.practice { trimPractice(c) }
        trim()
        markRead(c)
        scheduleSave()
        return true
    }

    /// Sends a failed message again (same text, reply and bridge origin); the failed
    /// copy goes. False when it didn't fail or the node isn't ready.
    @discardableResult
    func retry(_ m: ChatMessage) -> Bool {
        guard m.outgoing, case .failed = m.status,
              send(m.text, in: m.conversation, replyTo: m.replyTo, bridged: m.bridged) else { return false }
        messages.removeAll { $0.id == m.id }
        scheduleSave()
        return true
    }

    func react(_ emoji: String, to m: ChatMessage) {
        guard let (to, channel) = route(m.conversation), let me = radio.session.myNode,
              radio.sendText(emoji, to: to, channel: channel, replyID: m.packetID, isReaction: true) != nil,
              let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        messages[i].reactions[emoji, default: []].append(me.id)
        scheduleSave()
    }

    /// Where a message goes on the connected radio; nil for a channel it doesn't have.
    private func route(_ c: Conversation) -> (NodeNum, Int)? {
        switch c {
        case .channel: return slot(of: c).map { (.broadcast, $0) }
        case .direct(let id): return (NodeNum(id: id) ?? .broadcast, 0)
        }
    }

    // MARK: Receiving

    func handle(_ event: MeshSession.Event) {
        switch event {
        case .myNode(let n):
            attach(n.id)
        case .ready:
            if isPractice { startPractice() } else if let me = radio.session.myNode { attach(me.id) }
            refreshChannels()
            heal()
            scheduleSave()
        case .packet(let p):
            receive(p)
        }
    }

    private func receive(_ p: MeshPacket) {
        let me = radio.session.myNode
        if let me, me.id != historyNode || practiceHistory != isPractice { attach(me.id) }
        if p.portnum == .routing, let req = p.requestID, let err = p.routingError {
            if let i = messages.lastIndex(where: { $0.outgoing && $0.packetID == req }) {
                if err.isSuccess {
                    // An ack from our own node means a neighbour repeated it; from
                    // anyone else it's the recipient confirming.
                    let delivered = p.from != me
                    if delivered, messages[i].status != .delivered, !isPractice { deliveredCount += 1 }
                    if delivered || messages[i].status == .sending { messages[i].status = delivered ? .delivered : .sent }
                    if delivered, messages[i].roundTripMs == nil {
                        messages[i].roundTripMs = max(0, Int((Date().timeIntervalSince(messages[i].time) * 1000).rounded()))
                    }
                } else {
                    messages[i].status = .failed(err.explanation)
                }
                scheduleSave()
            }
            return
        }
        guard p.portnum == .text, let text = p.text, p.from != me else { return }
        if p.isReaction, let target = p.replyID {
            if let i = messages.lastIndex(where: { $0.packetID == target }) {
                var who = messages[i].reactions[text, default: []]
                if !who.contains(p.from.id) { who.append(p.from.id) }
                messages[i].reactions[text] = who
                scheduleSave()
            }
            return
        }
        // Fox Hunt referee traffic ("WG …") is machine-to-machine: the hunt screens read it, the radio log shows it,
        // and it never becomes a chat message or an unread badge.
        if text.hasPrefix("WG ") { return }
        let conversation: Conversation
        if !p.isBroadcast, p.to == me {
            conversation = .direct(p.from.id)
        } else {
            conversation = .channel(radio.session.channels[p.channel].map(ChannelKey.init(info:)) ?? ChannelKey(name: "", slot: p.channel))
        }
        if messages.contains(where: { $0.packetID == p.id && $0.from == p.from.id }) { return }
        var m = ChatMessage(packetID: p.id, from: p.from.id, conversation: conversation, text: text, time: Date(),
                            outgoing: false, status: .received, replyTo: p.replyID, snr: p.rxSNR.map(Double.init),
                            rssi: p.rxRSSI, hops: p.hops, viaMQTT: p.viaMQTT)
        m.radio = me?.id
        m.receivedAt = p.rxTime ?? m.time
        m.hopStart = p.hopStart
        m.hopLimit = p.hopLimit
        m.relayNode = p.relayNode.flatMap { $0 == 0 ? nil : $0 }
        m.size = p.airSize
        m.airtimeMs = p.airSize.flatMap { radio.session.lora?.airtime(bytes: $0) ?? (isPractice ? PracticeMesh.airtime(bytes: $0) : nil) }
        m.bridged = BridgeOrigin.parse(text, via: p.from.id)?.origin
        if keepsRawPackets { m.raw = p.raw }
        m.practice = isPractice
        messages.append(m)
        if m.practice { trimPractice(conversation) }
        trim()
        if open.map(resolved) == conversation && isForeground { markRead(conversation) } else { notify(m) }
        scheduleSave()
    }

    private func notify(_ m: ChatMessage) {
        guard !isForeground, !isHidden(m) else { return }
        let content = UNMutableNotificationContent()
        let sender = radio.session.label(for: NodeNum(id: m.from) ?? NodeNum(0))
        switch m.conversation {
        case .direct: content.title = sender
        case .channel(let k):
            let name = entry(for: m.conversation)?.name ?? k.name
            content.title = "\(sender) · \(name.isEmpty ? "Primary" : name)"
        }
        content.body = safety?.shown(m.text) ?? m.text
        content.sound = .default
        content.threadIdentifier = resolved(m.conversation).key
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: m.id.uuidString, content: content, trigger: nil))
    }

    static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Persistence

    private func trim() {
        if messages.count > Self.limit { messages.removeFirst(messages.count - Self.limit) }
    }

    /// What goes in the shown radio's file.
    private func history() -> MeshtasticHistory {
        MeshtasticHistory(messages: messages.filter { !$0.practice }, lastRead: lastRead, channels: channels, node: historyName)
    }

    /// Saves within 5 s, encoding off the main thread (thousands of messages).
    private func scheduleSave() {
        dirty = true
        saver.schedule { [weak self] in
            guard let self, !practiceHistory, let historyNode, let u = url(historyNode) else { return }
            refreshChannels()
            SaveFile.write(history(), to: u, encoder: MeshtasticHistory.encoder)
            dirty = false
        }
    }

    /// Saves right now (the app is going to the background).
    func save() {
        saver.cancel()
        guard !practiceHistory, let historyNode, let u = url(historyNode) else { return }
        refreshChannels()
        SaveFile.writeNow(history(), to: u, encoder: MeshtasticHistory.encoder())
        dirty = false
    }
}
