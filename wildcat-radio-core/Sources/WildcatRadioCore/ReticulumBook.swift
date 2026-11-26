import Foundation

// What the app keeps of Reticulum messaging between runs: the people heard and the conversations.
// Plain Codable values that take new fields through `decodeIfPresent`, so a file written by an
// older build always loads in a newer one. The identity key is not here: it lives in the Keychain.

extension Reticulum {
    /// Where an outgoing message is, in Wildcat's words (LXMF has more states; these are the ones a
    /// person can tell apart).
    public enum Delivery: String, Codable, Equatable, Sendable {
        case queued
        /// Asking the network where the destination is.
        case findingPath
        case sending
        /// On its way with no answer expected yet (a single packet, sent without a link).
        case sent
        case delivered
        case failed
        /// An incoming message.
        case received

        /// The bridge's state names (LXMF's, plus "queued" and "path" from the bridge itself).
        public init(bridge state: String) {
            switch state {
            case "queued", "generating": self = .queued
            case "path": self = .findingPath
            case "outbound", "sending": self = .sending
            case "sent": self = .sent
            case "delivered": self = .delivered
            case "received": self = .received
            default: self = .failed       // failed, rejected, cancelled, and anything new
            }
        }

        public init(from decoder: Decoder) throws {
            self = Delivery(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
        }

        /// Nothing more will happen to it.
        public var isFinal: Bool { self == .delivered || self == .failed || self == .received }

        public var word: String {
            switch self {
            case .queued: return "Queued"
            case .findingPath: return "Finding a path"
            case .sending: return "Sending"
            case .sent: return "Sent"
            case .delivered: return "Delivered"
            case .failed: return "Not delivered"
            case .received: return "Received"
            }
        }
    }

    /// Why a message wasn't delivered, when Wildcat knows.
    public enum Failure: String, Codable, Equatable, Sendable {
        /// Nobody answered the path request: the destination hasn't announced where this phone hears it.
        case noPath
        /// The other end asks for a stamp (proof of work), which this build can't make on iOS.
        case needsStamp
        /// The other end refused it.
        case rejected
        /// Sent, and no delivery proof came back in time.
        case noAnswer
        /// Reticulum was stopped, or the app closed, before it went out.
        case interrupted

        public init(from decoder: Decoder) throws {
            self = Failure(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .noAnswer
        }

        /// The bridge's reason codes on a failed message.
        public init?(bridge reason: String?) {
            switch reason {
            case "no_path": self = .noPath
            case "stamp": self = .needsStamp
            case "rejected": self = .rejected
            case "cancelled", "interrupted": self = .interrupted
            case "failed", "timeout": self = .noAnswer
            default: return nil
            }
        }

        public var line: String {
            switch self {
            case .noPath:
                return "No path: they haven't announced where this phone can hear them. Ask them to announce, then try again."
            case .needsStamp:
                return "They only accept messages with a stamp. Wildcat on iPhone can't make stamps yet."
            case .rejected:
                return "Their end refused the message."
            case .noAnswer:
                return "No answer from their end. They may be out of range or switched off."
            case .interrupted:
                return "Reticulum stopped before this went out."
            }
        }
    }

    /// How far an incoming message's sender is proven.
    public enum Trust: String, Codable, Equatable, Sendable {
        /// Signed by the address it claims to come from.
        case verified
        /// The sender's key isn't known yet (no announce heard from them), so the signature couldn't be checked.
        case unknownSender
        /// The signature is wrong. Wildcat drops these.
        case badSignature

        public init(from decoder: Decoder) throws {
            self = Trust(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknownSender
        }

        /// From the bridge's `signature_validated` and `unverified` fields.
        public init(validated: Bool, reason: String?) {
            if validated { self = .verified }
            else if reason == "signature invalid" { self = .badSignature }
            else { self = .unknownSender }
        }

        /// The note under a message that isn't verified.
        public var note: String? {
            switch self {
            case .verified: return nil
            case .unknownSender: return "Unverified: no announce heard from this sender yet, so the signature couldn't be checked."
            case .badSignature: return "Signature invalid."
            }
        }
    }

    /// Someone heard announcing an LXMF address (or written to by address).
    public struct Contact: Codable, Equatable, Identifiable, Sendable {
        /// The LXMF address: 32 hex digits.
        public var hash: String
        public var name: String?
        public var hops: Int?
        public var firstHeard: Date?
        public var lastHeard: Date?
        public var announces: Int
        /// The stamp cost their announce asks for (nil or 0: none).
        public var stampCost: Int?
        public var id: String { hash }

        public init(hash: String, name: String? = nil, hops: Int? = nil, firstHeard: Date? = nil, lastHeard: Date? = nil,
                    announces: Int = 0, stampCost: Int? = nil) {
            self.hash = hash
            self.name = name
            self.hops = hops
            self.firstHeard = firstHeard
            self.lastHeard = lastHeard
            self.announces = announces
            self.stampCost = stampCost
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hash = try c.decode(String.self, forKey: .hash)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            hops = try c.decodeIfPresent(Int.self, forKey: .hops)
            firstHeard = try c.decodeIfPresent(Date.self, forKey: .firstHeard)
            lastHeard = try c.decodeIfPresent(Date.self, forKey: .lastHeard)
            announces = try c.decodeIfPresent(Int.self, forKey: .announces) ?? 0
            stampCost = try c.decodeIfPresent(Int.self, forKey: .stampCost)
        }

        /// The announced name, or the short address when there is none.
        public var title: String {
            let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? Reticulum.shortAddress(hash) : n
        }
        public var needsStamp: Bool { (stampCost ?? 0) > 0 }
    }

    public struct Message: Codable, Equatable, Identifiable, Sendable {
        /// Outgoing: Wildcat's own id. Incoming: the LXMF message hash (so a repeat is one message).
        public var id: String
        public var incoming: Bool
        /// The other end's LXMF address.
        public var peer: String
        public var text: String
        public var at: Date
        public var delivery: Delivery
        public var failure: Failure?
        /// Incoming only.
        public var trust: Trust?
        public var read: Bool

        public init(id: String, incoming: Bool, peer: String, text: String, at: Date, delivery: Delivery,
                    failure: Failure? = nil, trust: Trust? = nil, read: Bool = true) {
            self.id = id
            self.incoming = incoming
            self.peer = peer
            self.text = text
            self.at = at
            self.delivery = delivery
            self.failure = failure
            self.trust = trust
            self.read = read
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            incoming = try c.decodeIfPresent(Bool.self, forKey: .incoming) ?? false
            peer = try c.decode(String.self, forKey: .peer)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(timeIntervalSince1970: 0)
            delivery = try c.decodeIfPresent(Delivery.self, forKey: .delivery) ?? (incoming ? .received : .failed)
            failure = try c.decodeIfPresent(Failure.self, forKey: .failure)
            trust = try c.decodeIfPresent(Trust.self, forKey: .trust)
            read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? true
        }
    }

    /// One conversation's row: who, the latest message, how many unread.
    public struct Conversation: Equatable, Identifiable, Sendable {
        public var peer: String
        public var contact: Contact?
        public var last: Message
        public var unread: Int
        public var id: String { peer }
        public var title: String { contact?.title ?? Reticulum.shortAddress(peer) }
    }

    /// Everything saved: the people heard and every message, oldest first.
    public struct Book: Codable, Equatable, Sendable {
        public var contacts: [Contact]
        public var messages: [Message]

        /// The most kept: the oldest messages, and the contacts heard longest ago that have no
        /// conversation, go first.
        public static let messageLimit = 2000
        public static let contactLimit = 300
        /// The longest text kept from one incoming message (LXMF can carry far more over a link).
        public static let textLimit = 4000

        public init(contacts: [Contact] = [], messages: [Message] = []) {
            self.contacts = contacts
            self.messages = messages
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
            messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        }

        public func contact(_ hash: String) -> Contact? { contacts.first { $0.hash == hash } }

        /// An announce was heard. A nameless one keeps the name already known.
        public mutating func heard(hash: String, name: String?, hops: Int?, stampCost: Int?, at: Date) {
            guard Reticulum.address(hash) == hash else { return }
            let clean = name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 }
            if let i = contacts.firstIndex(where: { $0.hash == hash }) {
                if let clean { contacts[i].name = clean }
                contacts[i].hops = hops
                contacts[i].stampCost = stampCost
                contacts[i].lastHeard = at
                contacts[i].announces += 1
            } else {
                contacts.append(Contact(hash: hash, name: clean, hops: hops, firstHeard: at, lastHeard: at, announces: 1, stampCost: stampCost))
                trimContacts()
            }
        }

        /// Adds a message. False when it is already there (the same incoming hash again), has no
        /// usable address, or carries a bad signature: those are never kept.
        @discardableResult
        public mutating func add(_ m: Message) -> Bool {
            guard Reticulum.address(m.peer) == m.peer, m.trust != .badSignature, !messages.contains(where: { $0.id == m.id }) else { return false }
            var m = m
            if m.text.count > Self.textLimit { m.text = String(m.text.prefix(Self.textLimit)) + "…" }
            messages.append(m)
            if messages.count > Self.messageLimit { messages.removeFirst(messages.count - Self.messageLimit) }
            return true
        }

        /// A new state for an outgoing message. A finished message doesn't go back (a late
        /// "sending" after "delivered" changes nothing), except that a delivery proof always counts.
        public mutating func update(id: String, delivery: Delivery, failure: Failure? = nil) {
            guard let i = messages.lastIndex(where: { $0.id == id && !$0.incoming }) else { return }
            if messages[i].delivery.isFinal && delivery != .delivered { return }
            messages[i].delivery = delivery
            messages[i].failure = delivery == .failed ? (failure ?? .noAnswer) : nil
        }

        /// Reticulum stopped (or the app is starting again): what was still on its way won't arrive.
        public mutating func interrupt() {
            for i in messages.indices where !messages[i].incoming && !messages[i].delivery.isFinal && messages[i].delivery != .sent {
                messages[i].delivery = .failed
                messages[i].failure = .interrupted
            }
        }

        public func thread(with peer: String) -> [Message] { messages.filter { $0.peer == peer } }

        /// Conversations, the latest first.
        public var conversations: [Conversation] {
            var byPeer: [String: Conversation] = [:]
            for m in messages {
                let unread = (m.incoming && !m.read) ? 1 : 0
                if var c = byPeer[m.peer] {
                    c.last = m
                    c.unread += unread
                    byPeer[m.peer] = c
                } else {
                    byPeer[m.peer] = Conversation(peer: m.peer, contact: contact(m.peer), last: m, unread: unread)
                }
            }
            return byPeer.values.sorted { ($0.last.at, $0.peer) > ($1.last.at, $1.peer) }
        }

        public var unread: Int { messages.reduce(0) { $0 + (($1.incoming && !$1.read) ? 1 : 0) } }

        public mutating func markRead(peer: String) {
            for i in messages.indices where messages[i].peer == peer && !messages[i].read { messages[i].read = true }
        }

        public mutating func removeConversation(with peer: String) { messages.removeAll { $0.peer == peer } }

        public mutating func forget(contact hash: String) { contacts.removeAll { $0.hash == hash } }

        /// People heard, the most recent first.
        public var heardRecently: [Contact] {
            contacts.sorted { ($0.lastHeard ?? .distantPast, $0.hash) > ($1.lastHeard ?? .distantPast, $1.hash) }
        }

        private mutating func trimContacts() {
            guard contacts.count > Self.contactLimit else { return }
            let talking = Set(messages.map(\.peer))
            let droppable = contacts.filter { !talking.contains($0.hash) }
                .sorted { ($0.lastHeard ?? .distantPast) < ($1.lastHeard ?? .distantPast) }
            let drop = Set(droppable.prefix(contacts.count - Self.contactLimit).map(\.hash))
            contacts.removeAll { drop.contains($0.hash) }
        }
    }
}
