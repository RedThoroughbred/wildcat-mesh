import Foundation

/// What we know about a MeshCore companion node, built from its frames. Pure:
/// the link feeds frames in and sends the commands that come out.
public struct MeshCoreSession: Sendable {
    public struct Channel: Equatable, Sendable {
        public var index: Int
        public var name: String
        public var secret: Data
    }

    public struct Chat: Equatable, Sendable, Identifiable, Codable {
        public enum Direction: Equatable, Sendable, Codable { case received, sent }
        public var id: UUID
        public var direction: Direction
        public var origin: MeshCore.Message.Origin
        public var text: String
        public var at: Date
        public var hops: Int?
        public var snr: Double?
        /// For sent direct messages: the ack tag to watch for, then confirmation.
        public var ack: UInt32?
        public var confirmed = false
        /// 1 = a repeater CLI reply (shown in its console, not in chats).
        public var textType: UInt8?

        // Message details. Every one is optional: older saves (and messages whose
        // packet wasn't heard, like ones synced after a reconnect) simply lack them.

        /// The local node it came through (or went out on): its public key in hex.
        public var radio: String?
        /// When this phone got it. `at` is the sender's clock, which can be off.
        public var receivedAt: Date?
        /// Signal of the packet that carried it (from the node's RX log).
        public var rssi: Int?
        /// Relay hashes it came through, oldest first (1-3 bytes each).
        public var path: [Data]?
        /// Sent by flood (false: along a known direct route).
        public var flood: Bool?
        /// Bytes on air (as heard for received, as sent for sent) and the time that
        /// takes with the node's radio settings.
        public var size: Int?
        public var airtimeMs: Int?
        /// MeshCore's packet hash (hex), the same for every copy of the packet.
        public var packetHash: String?
        /// Sent channel messages: repeaters heard passing it on (distinct last hops),
        /// and their hashes.
        public var heardBy: Int?
        public var heardFrom: [Data]?
        /// Sent direct messages: the confirmation's round trip.
        public var roundTripMs: Int?
        /// A bridged line: where it was really said.
        public var bridged: BridgeOrigin?
        /// The packet as heard (only with "Keep raw packets" on).
        public var raw: Data?
        /// Room server posts: the first 4 bytes of the author's public key (the
        /// origin is the room). `MeshCoreSession.author(of:)` names them.
        public var author: Data?
        /// Sent direct messages: where delivery stands (nil for chats saved before
        /// 1.1; `confirmed` and `ack` still say what they always did).
        public var delivery: Delivery?

        /// A sent direct message's progress. Attempts count from 0 (the first try).
        public enum Delivery: Equatable, Sendable, Codable {
            /// Handed to the node, waiting for it to say it's on air.
            case sending(attempt: Int)
            /// On air (by flood, or along a known route), waiting for the recipient's confirmation.
            case sent(attempt: Int, flood: Bool)
            case delivered
            case failed(Failure)

            public var attempt: Int? {
                switch self {
                case .sending(let a), .sent(let a, _): return a
                default: return nil
                }
            }
        }

        public enum Failure: Equatable, Sendable, Codable {
            /// No confirmation after every attempt (the last ones by flood).
            case noConfirmation(attempts: Int)
            /// The node never said the message went out.
            case nodeDidNotAnswer
            /// The node refused it (firmware error code: 2 unknown contact, 3 queue full).
            case rejected(code: Int?)

            /// A line for the chat.
            public var reason: String {
                switch self {
                case .noConfirmation(let n): return "No confirmation after \(n) tries"
                case .nodeDidNotAnswer: return "Your node didn't send it"
                case .rejected(2): return "Your node doesn't know this contact"
                case .rejected(3): return "Your node's send queue is full"
                case .rejected: return "Your node refused it"
                }
            }
        }

        public init(id: UUID, direction: Direction, origin: MeshCore.Message.Origin, text: String, at: Date,
                    hops: Int? = nil, snr: Double? = nil, ack: UInt32? = nil, confirmed: Bool = false, textType: UInt8? = nil) {
            self.id = id
            self.direction = direction
            self.origin = origin
            self.text = text
            self.at = at
            self.hops = hops
            self.snr = snr
            self.ack = ack
            self.confirmed = confirmed
            self.textType = textType
        }

        /// Channel text starts with the sender's name: "MAYA: hi" -> "MAYA".
        public var channelSender: String? {
            guard case .channel = origin, direction == .received, let r = text.range(of: ": "),
                  text.distance(from: text.startIndex, to: r.lowerBound) <= 32 else { return nil }
            let name = String(text[..<r.lowerBound])
            return name.isEmpty ? nil : name
        }

        enum CodingKeys: String, CodingKey {
            case id, direction, origin, text, at, hops, snr, ack, confirmed, textType
            case radio, receivedAt, rssi, path, flood, size, airtimeMs, packetHash, heardBy, heardFrom, roundTripMs, bridged, raw
            case author, delivery
        }
    }

    public enum Event: Equatable, Sendable {
        case ready
        case message(Chat)
        case contactsChanged
        case heard(snr: Double, rssi: Int, raw: Data)
        case confirmed(ack: UInt32, roundTripMs: UInt32)
        case login(prefix: Data, ok: Bool, isAdmin: Bool)
        case status(prefix: Data, MeshCore.RepeaterStatus)
        case trace(MeshCore.TraceResult)
        case datagram(channel: Int, dataType: UInt16, payload: Data, snr: Double)
        /// A sent direct message's delivery changed (sending again, on air, delivered, failed).
        case delivery(id: UUID, Chat.Delivery)
    }

    public private(set) var me: MeshCore.SelfInfo?
    public private(set) var device: MeshCore.DeviceInfo?
    public private(set) var contacts: [Data: MeshCore.Contact] = [:]
    public private(set) var channels: [Int: Channel] = [:]
    public private(set) var chats: [Chat] = []
    public private(set) var batteryMillivolts: Int?
    /// Packets the node heard on air (its RX log), and when the last one came.
    public private(set) var heardPackets = 0
    public private(set) var lastHeard: Date?
    public private(set) var isReady = false
    static let keepChats = 1000
    /// Attach the raw packet to each message (a debug setting: it makes saves bigger).
    public var keepsRaw = false
    /// Recent packets heard on air, for pairing with the messages they carried.
    public private(set) var heardLog = MeshCoreHeardLog()
    /// Sent channel messages whose repeats we're still listening for.
    public private(set) var echoWatches: [MeshCoreEchoWatch] = []
    /// Public keys of the contacts in the node's own table (listed by it, or added
    /// since). Any other contact was only heard (a new advert while auto-add is off)
    /// or remembered from a save: the node can't message it until it's added.
    public private(set) var onNode: Set<Data> = []
    /// Direct messages still waiting to be confirmed (or retried).
    var outbox: [DirectSend] = []

    /// How many times a direct message is sent before it's given up: twice along the
    /// known route, then (after resetting the path) once by flood.
    public static let directAttempts = 3
    /// Added to the firmware's own estimate before a send counts as unconfirmed.
    static let ackMargin: TimeInterval = 2
    /// Used when the firmware gives no estimate.
    static let defaultAckTimeout: TimeInterval = 12
    /// How long the node has to say a send went out (it may wait behind other commands).
    static let nodeAnswerTimeout: TimeInterval = 30

    /// A direct message in flight: what was sent, the acks each attempt expects, and
    /// when the current attempt runs out.
    struct DirectSend: Equatable, Sendable {
        var chat: UUID
        var to: Data
        var text: String
        var at: Date
        var attempt = 0
        var acks: [UInt32] = []
        /// The node has said the current attempt is on air.
        var onAir = false
        var flood = false
        var deadline: Date
        /// Already added the contact after the node said it didn't know it.
        var readded = false

        func matches(_ c: MeshCore.Command) -> Bool {
            guard case .sendText(let to, let text, let at, let attempt) = c else { return false }
            return to.prefix(6) == self.to && text == self.text && Int(at.timeIntervalSince1970) == Int(self.at.timeIntervalSince1970)
                && attempt == self.attempt
        }

        var command: MeshCore.Command { .sendText(to: to, text: text, at: at, attempt: attempt) }
    }

    /// This node's public key in hex (a chat's `radio`).
    public var radioID: String? { me.map { $0.publicKey.map { String(format: "%02x", $0) }.joined() } }

    public init() {}

    /// The handshake the firmware expects, in order.
    public static func startup(appName: String = "Wildcat", at date: Date = Date(), maxChannels: Int = 8) -> [MeshCore.Command] {
        [.appStart(name: appName), .deviceQuery, .setDeviceTime(date), .getContacts, .getBatteryAndStorage]
            + (0..<maxChannels).map { .getChannel(index: $0) } + [.syncNextMessage]
    }

    /// True when `frame` is the (last) answer to `command`, freeing the queue.
    /// Strict: only the answer types this command can produce count, so frames
    /// meant for another app connected to the same node never jam the queue.
    public static func completes(_ command: MeshCore.Command, with frame: MeshCore.Frame) -> Bool {
        if case .error = frame { return true }
        switch (command, frame) {
        case (.appStart, .selfInfo), (.deviceQuery, .deviceInfo), (.getContacts, .endOfContacts),
             (.getBatteryAndStorage, .battery), (.syncNextMessage, .message), (.syncNextMessage, .noMoreMessages), (.syncNextMessage, .channelData),
             (.sendText, .sent), (.login, .sent), (.statusRequest, .sent), (.remoteCommand, .sent), (.logout, .ok), (.trace, .sent):
            return true
        case (.getChannel(let i), .channelInfo(let j, _, _)):
            return i == j
        case (.setDeviceTime, .ok), (.setChannel, .ok), (.sendChannelText, .ok), (.sendSelfAdvert, .ok),
             (.setName, .ok), (.setRadio, .ok), (.setTxPower, .ok), (.setPosition, .ok), (.setOtherParams, .ok),
             (.removeContact, .ok), (.resetPath, .ok), (.setPIN, .ok), (.sendChannelData, .ok), (.addContact, .ok):
            return true
        default:
            return false   // pushes, and answers to someone else's questions
        }
    }

    public func contact(prefix: Data) -> MeshCore.Contact? {
        contacts.values.first { $0.publicKey.starts(with: prefix) }
    }

    /// True when the node itself holds this contact (it can message it).
    public func isOnNode(_ c: MeshCore.Contact) -> Bool { onNode.contains(c.publicKey) }

    /// Contacts the node doesn't hold: heard (auto-add off) or remembered from a save.
    public var heardOnly: [MeshCore.Contact] { contacts.values.filter { !onNode.contains($0.publicKey) } }

    /// Who wrote a room server post: a contact's name when we know them, this node's
    /// own name for our posts, else the key prefix in hex. Nil for other chats.
    public func author(of chat: Chat) -> String? {
        guard let a = chat.author, !a.isEmpty else { return nil }
        if let me, me.publicKey.starts(with: a) { return me.name.nonEmpty ?? "You" }
        return contact(prefix: a)?.name.nonEmpty ?? a.map { String(format: "%02x", $0) }.joined()
    }

    /// Contacts whose public key starts with `hash` (who a trace hop was).
    public func contacts(hash: Data) -> [MeshCore.Contact] {
        contacts.values.filter { $0.publicKey.starts(with: hash) }
    }

    /// Chats that belong in conversations (not repeater console replies).
    public var conversationChats: [Chat] { chats.filter { $0.textType != 1 } }

    public func label(_ origin: MeshCore.Message.Origin) -> String {
        switch origin {
        case .channel(let i): return channels[i]?.name.nonEmpty ?? (i == 0 ? "Public" : "Channel \(i)")
        case .contact(let p): return contact(prefix: p)?.name ?? p.map { String(format: "%02x", $0) }.joined()
        }
    }

    public mutating func markReady() { isReady = true }
    /// Brings back what an app saved for this node: older chats go first (deduplicated
    /// against anything already synced), and contacts the node no longer lists are
    /// kept as remembered ones.
    public mutating func restore(chats saved: [Chat], contacts savedContacts: [MeshCore.Contact]) {
        let seen = Set(chats.map { "\($0.origin)|\($0.direction)|\($0.text)|\(Int($0.at.timeIntervalSince1970))" })
        let older = saved.filter { !seen.contains("\($0.origin)|\($0.direction)|\($0.text)|\(Int($0.at.timeIntervalSince1970))") }
        chats = Array((older + chats).suffix(Self.keepChats))
        for c in savedContacts where contacts[c.publicKey] == nil { contacts[c.publicKey] = c }
    }

    public mutating func forget(contact key: Data) { contacts[key] = nil; onNode.remove(key) }
    public mutating func forget(channel index: Int) { channels[index] = nil }

    /// Remember a message this phone sent.
    public mutating func sent(_ text: String, to origin: MeshCore.Message.Origin, at: Date) -> UUID {
        var c = Chat(id: UUID(), direction: .sent, origin: origin, text: text, at: at)
        c.radio = radioID
        if case .channel(let i) = origin {
            echoWatches.removeAll { !$0.isOpen(at: at) }
            echoWatches.append(MeshCoreEchoWatch(chat: c.id, channel: i, sentAt: at, text: text))
        }
        append(c)
        return c.id
    }

    /// Marks a chat as a bridged line (the bridge knows where it was said).
    public mutating func setBridged(_ origin: BridgeOrigin, on id: UUID) {
        if let i = chats.lastIndex(where: { $0.id == id }) { chats[i].bridged = origin }
    }

    public mutating func attachAck(_ ack: UInt32, to id: UUID) {
        if let i = chats.lastIndex(where: { $0.id == id }) { chats[i].ack = ack }
    }

    public mutating func appendChat(_ c: Chat) { append(c) }

    /// Keeps only the newest `n` chats of each conversation (the practice node's short memory).
    public mutating func trimChats(keepingPerConversation n: Int) {
        var left: [MeshCore.Message.Origin: Int] = [:]
        var keep = [Bool](repeating: false, count: chats.count)
        for i in chats.indices.reversed() {
            let k = left[chats[i].origin, default: n]
            keep[i] = k > 0
            left[chats[i].origin] = k - 1
        }
        guard keep.contains(false) else { return }
        chats = chats.indices.filter { keep[$0] }.map { chats[$0] }
    }

    private mutating func append(_ c: Chat) {
        chats.append(c)
        if chats.count > Self.keepChats { chats.removeFirst(chats.count - Self.keepChats) }
    }

    /// Applies a frame. Returns what happened and any follow-up commands.
    public mutating func handle(_ frame: MeshCore.Frame, now: Date = Date()) -> (events: [Event], follow: [MeshCore.Command]) {
        switch frame {
        case .selfInfo(let s):
            me = s
        case .deviceInfo(let d):
            device = d
            // Startup reads slots 0-7; newer firmware has more (40 on v1.17).
            if d.maxChannels > 8 { return ([], (8..<min(d.maxChannels, 64)).map { .getChannel(index: $0) }) }
        case .contactsStart:
            onNode = []   // a full listing follows
        case .contact(let c):
            contacts[c.publicKey] = c
            onNode.insert(c.publicKey)
            return ([.contactsChanged], [])
        case .newAdvert(let c):
            // Only sent for someone the node did NOT add (BaseChatMesh::onAdvertRecv):
            // auto-add is off, the hop limit was passed, or its table is full.
            contacts[c.publicKey] = c
            onNode.remove(c.publicKey)
            return ([.contactsChanged], [])
        case .contactDeleted(let key):
            onNode.remove(key)
            return ([.contactsChanged], [])
        case .endOfContacts:
            return ([.contactsChanged], [])
        case .channelInfo(let i, let name, let secret):
            if name.isEmpty && secret.allSatisfy({ $0 == 0 }) { channels[i] = nil }
            else { channels[i] = Channel(index: i, name: name, secret: secret) }
        case .battery(let mv, _, _):
            batteryMillivolts = mv
        case .message(let m):
            var chat = Chat(id: UUID(), direction: .received, origin: m.origin, text: m.text, at: m.sent,
                            hops: m.hops, snr: m.snr)
            chat.textType = m.textType
            chat.author = m.author
            chat.radio = radioID
            chat.receivedAt = now
            attachHeard(to: &chat, message: m, now: now)
            if m.textType != 1 {
                var via: String?
                if case .contact = m.origin { via = label(m.origin) }
                chat.bridged = BridgeOrigin.parse(m.text, via: via)?.origin
            }
            append(chat)
            return ([.message(chat)], [.syncNextMessage])   // keep pulling until the queue is empty
        case .messagesWaiting:
            return ([], [.syncNextMessage])
        case .advert(let key):
            if contacts[key] == nil { return ([], [.getContacts]) }
            contacts[key]?.lastAdvert = now
            onNode.insert(key)   // a known contact's advert: the node holds it
            return ([.contactsChanged], [])
        case .sendConfirmed(let ack, let rtt):
            var events: [Event] = [.confirmed(ack: ack, roundTripMs: rtt)]
            // Any attempt's ack counts (an early one can arrive after a retry went out).
            let pending = outbox.firstIndex { $0.acks.contains(ack) }
            let id = pending.map { outbox[$0].chat }
            if let pending { outbox.remove(at: pending) }
            if let i = id.flatMap({ id in chats.lastIndex { $0.id == id } }) ?? chats.lastIndex(where: { $0.ack == ack }) {
                chats[i].confirmed = true
                chats[i].roundTripMs = Int(rtt)
                if chats[i].delivery != nil, chats[i].delivery != .delivered {
                    chats[i].delivery = .delivered
                    events.append(.delivery(id: chats[i].id, .delivered))
                }
            }
            return (events, [])
        case .loginResult(let p, let ok, let admin):
            return ([.login(prefix: p, ok: ok, isAdmin: admin)], [])
        case .status(let p, let s):
            return ([.status(prefix: p, s)], [])
        case .trace(let tr):
            return ([.trace(tr)], [])
        case .channelData(let ch, let dt, let payload, let snr, _):
            // Datagrams queue like messages: keep pulling.
            return ([.datagram(channel: ch, dataType: dt, payload: payload, snr: snr)], [.syncNextMessage])
        case .rxLog(let snr, let rssi, let raw):
            heardPackets &+= 1
            lastHeard = now
            if let e = heardLog.add(snr: snr, rssi: rssi, raw: raw, at: now) { noteEcho(e, now: now) }
            return ([.heard(snr: snr, rssi: rssi, raw: raw)], [])
        default:
            break
        }
        return ([], [])
    }
}

extension MeshCoreSession {
    /// Estimated time on air for `bytes` with this node's radio settings.
    public func airtime(bytes: Int) -> Int? {
        guard let me else { return nil }
        return LoRaAirtime.milliseconds(bytes: bytes, spreadingFactor: me.spreadingFactor, bandwidthKHz: me.bandwidth,
                                        codingRate: me.codingRate)
    }

    /// Fills in what the packet that carried a received message tells us.
    mutating func attachHeard(to chat: inout Chat, message m: MeshCore.Message, now: Date) {
        var secret: Data?
        if case .channel(let i) = m.origin { secret = channels[i]?.secret }
        guard let e = heardLog.match(m, at: now, channelSecret: secret, myHash: me?.publicKey.first) else { return }
        chat.rssi = e.rssi
        if chat.snr == nil { chat.snr = e.snr }
        chat.path = e.packet.path
        chat.flood = e.packet.isFlood
        chat.size = e.raw.count
        chat.airtimeMs = airtime(bytes: e.raw.count)
        chat.packetHash = e.packet.hash
        if keepsRaw { chat.raw = e.raw }
    }

    /// A heard packet that's a repeat of a channel message we sent: count its last hop.
    mutating func noteEcho(_ e: MeshCoreHeardLog.Entry, now: Date) {
        echoWatches.removeAll { !$0.isOpen(at: now) }
        guard e.packet.type == .groupText else { return }
        for w in echoWatches.indices {
            guard echoWatches[w].isEcho(e.packet, secret: channels[echoWatches[w].channel]?.secret),
                  let i = chats.lastIndex(where: { $0.id == echoWatches[w].chat }) else { continue }
            var c = chats[i]
            if c.size == nil {
                c.size = e.packet.originalSize
                c.airtimeMs = airtime(bytes: e.packet.originalSize)
                c.packetHash = e.packet.hash
                c.flood = e.packet.isFlood
                if keepsRaw { c.raw = e.packet.original }
            }
            if let hop = e.packet.lastHop {
                var from = c.heardFrom ?? []
                if !from.contains(hop) { from.append(hop) }
                c.heardFrom = from
                c.heardBy = from.count
            }
            chats[i] = c
            return
        }
    }
}

// MARK: Direct messages: add the contact, confirm, retry, give up

extension MeshCoreSession {
    /// Starts a direct message: remembers it as `.sending(attempt: 0)` and returns the
    /// commands for the node. A contact the node doesn't hold (only heard, or from a
    /// save) is added to it first, or the node would refuse the send.
    public mutating func sendDirect(_ text: String, to contact: MeshCore.Contact, at: Date,
                                    now: Date = Date()) -> (id: UUID, commands: [MeshCore.Command]) {
        let id = sent(text, to: .contact(contact.prefix), at: at)
        setDelivery(.sending(attempt: 0), on: id)
        let d = DirectSend(chat: id, to: contact.prefix, text: text, at: at, deadline: now.addingTimeInterval(Self.nodeAnswerTimeout))
        outbox.append(d)
        if contacts[contact.publicKey] == nil { contacts[contact.publicKey] = contact }
        return (id, (isOnNode(contact) ? [] : [.addContact(contact)]) + [d.command])
    }

    /// Direct messages still waiting for confirmation.
    public var pendingDirectCount: Int { outbox.count }

    /// The node's answer to a command (the link knows which one was in flight).
    /// Keeps track of contacts added or removed and of each direct message's ack.
    public mutating func answered(_ command: MeshCore.Command, with frame: MeshCore.Frame,
                                  now: Date = Date()) -> (events: [Event], follow: [MeshCore.Command]) {
        switch (command, frame) {
        case (.addContact(let c), .ok):
            onNode.insert(c.publicKey)
            if contacts[c.publicKey] == nil { contacts[c.publicKey] = c }
            return ([.contactsChanged], [])
        case (.removeContact(let key), .ok):
            onNode.remove(key)
        case (.sendText, .sent(let flood, let ack, let timeout)):
            guard let k = outbox.firstIndex(where: { $0.matches(command) }) else { break }
            outbox[k].acks.append(ack)
            outbox[k].onAir = true
            outbox[k].flood = flood
            let wait = timeout > 0 ? TimeInterval(timeout) / 1000 : Self.defaultAckTimeout
            outbox[k].deadline = now.addingTimeInterval(wait + Self.ackMargin)
            let d = outbox[k]
            attachAck(ack, to: d.chat)
            if let i = chats.lastIndex(where: { $0.id == d.chat }) { chats[i].flood = flood }
            return ([setDelivery(.sent(attempt: d.attempt, flood: flood), on: d.chat)].compactMap { $0 }, [])
        case (.sendText, .error(let code)):
            guard let k = outbox.firstIndex(where: { $0.matches(command) }) else { break }
            // "Not found": the node lost the contact (or never had it). Add it once and resend.
            if code == 2, !outbox[k].readded, let c = contact(prefix: outbox[k].to) {
                outbox[k].readded = true
                outbox[k].deadline = now.addingTimeInterval(Self.nodeAnswerTimeout)
                onNode.remove(c.publicKey)
                return ([], [.addContact(c), outbox[k].command])
            }
            let d = outbox.remove(at: k)
            return ([setDelivery(.failed(.rejected(code: code)), on: d.chat)].compactMap { $0 }, [])
        default:
            break
        }
        return ([], [])
    }

    /// Direct messages whose time ran out: sent again (the attempt counter goes up;
    /// after the second failed attempt the path is reset so the next one floods),
    /// or given up after `directAttempts`. Call it about once a second.
    public mutating func tick(now: Date = Date()) -> (events: [Event], follow: [MeshCore.Command]) {
        var events: [Event] = [], follow: [MeshCore.Command] = [], kept: [DirectSend] = []
        for var d in outbox {
            guard d.deadline <= now else { kept.append(d); continue }
            guard d.attempt + 1 < Self.directAttempts else {
                let why: Chat.Failure = d.acks.isEmpty ? .nodeDidNotAnswer : .noConfirmation(attempts: d.attempt + 1)
                if let e = setDelivery(.failed(why), on: d.chat) { events.append(e) }
                continue
            }
            d.attempt += 1
            if d.attempt == 2, d.onAir, !d.flood, let c = contact(prefix: d.to) {
                follow.append(.resetPath(publicKey: c.publicKey))   // the route may be gone: flood next
            }
            d.onAir = false
            d.deadline = now.addingTimeInterval(Self.nodeAnswerTimeout)
            kept.append(d)
            follow.append(d.command)
            if let e = setDelivery(.sending(attempt: d.attempt), on: d.chat) { events.append(e) }
        }
        outbox = kept
        return (events, follow)
    }

    /// Sets a chat's delivery; the event to publish when it changed.
    @discardableResult
    mutating func setDelivery(_ d: Chat.Delivery, on id: UUID) -> Event? {
        guard let i = chats.lastIndex(where: { $0.id == id }), chats[i].delivery != d else { return nil }
        chats[i].delivery = d
        if d == .delivered { chats[i].confirmed = true }
        return .delivery(id: id, d)
    }
}

extension MeshCoreSession.Chat {
    /// Fields with a default may be missing (saved by an older or newer version),
    /// so adding one never makes a whole chat history unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        direction = try c.decode(Direction.self, forKey: .direction)
        origin = try c.decode(MeshCore.Message.Origin.self, forKey: .origin)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Date.self, forKey: .at)
        hops = try c.decodeIfPresent(Int.self, forKey: .hops)
        snr = try c.decodeIfPresent(Double.self, forKey: .snr)
        ack = try c.decodeIfPresent(UInt32.self, forKey: .ack)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        textType = try c.decodeIfPresent(UInt8.self, forKey: .textType)
        // Details: a bad value loses that detail, never the chat.
        radio = try? c.decodeIfPresent(String.self, forKey: .radio)
        receivedAt = try? c.decodeIfPresent(Date.self, forKey: .receivedAt)
        rssi = try? c.decodeIfPresent(Int.self, forKey: .rssi)
        path = try? c.decodeIfPresent([Data].self, forKey: .path)
        flood = try? c.decodeIfPresent(Bool.self, forKey: .flood)
        size = try? c.decodeIfPresent(Int.self, forKey: .size)
        airtimeMs = try? c.decodeIfPresent(Int.self, forKey: .airtimeMs)
        packetHash = try? c.decodeIfPresent(String.self, forKey: .packetHash)
        heardBy = try? c.decodeIfPresent(Int.self, forKey: .heardBy)
        heardFrom = try? c.decodeIfPresent([Data].self, forKey: .heardFrom)
        roundTripMs = try? c.decodeIfPresent(Int.self, forKey: .roundTripMs)
        bridged = try? c.decodeIfPresent(BridgeOrigin.self, forKey: .bridged)
        raw = try? c.decodeIfPresent(Data.self, forKey: .raw)
        author = try? c.decodeIfPresent(Data.self, forKey: .author)
        delivery = try? c.decodeIfPresent(Delivery.self, forKey: .delivery)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
