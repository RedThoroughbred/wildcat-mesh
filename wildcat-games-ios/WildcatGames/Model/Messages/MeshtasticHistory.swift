import Foundation
import WildcatRadioCore

/// One Meshtastic radio's chats, as saved on the phone (`meshtastic-<node>.json`):
/// its messages, read marks, the channels it had when last connected, and its name.
struct MeshtasticHistory: Codable {
    /// A channel's slot, name and identity (never its key).
    struct SavedChannel: Codable, Equatable {
        var slot: Int
        var name: String
        var key: ChannelKey
        var primary: Bool
    }

    var messages: [ChatMessage] = []
    /// Last time each conversation was read, keyed by `Conversation.key`.
    var lastRead: [String: Date] = [:]
    var channels: [SavedChannel] = []
    /// The node's own long name, when known.
    var node: String?

    init(messages: [ChatMessage] = [], lastRead: [String: Date] = [:], channels: [SavedChannel] = [], node: String? = nil) {
        self.messages = messages
        self.lastRead = lastRead
        self.channels = channels
        self.node = node
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        lastRead = try c.decodeIfPresent([String: Date].self, forKey: .lastRead) ?? [:]
        channels = (try? c.decodeIfPresent([SavedChannel].self, forKey: .channels)) ?? []
        node = try? c.decodeIfPresent(String.self, forKey: .node)
    }

    /// Only the name, for listing other radios' saves without reading every message.
    struct Head: Decodable {
        var node: String?
    }

    // MARK: Files

    /// Which radio's history was shown last (UserDefaults), for reading it before a connection.
    static let lastArchiveKey = "meshtastic.lastArchive"

    /// The history whose radio isn't known (saved before messages recorded their radio).
    static let unknownNode = "unknown"

    /// "meshtastic-716c668c.json" for "!716c668c".
    static func fileName(node id: String) -> String {
        "meshtastic-" + (id.hasPrefix("!") ? String(id.dropFirst()) : id) + ".json"
    }

    /// The node id a history file is for, or nil for any other file.
    static func node(ofFile name: String) -> String? {
        guard name.hasPrefix("meshtastic-"), name.hasSuffix(".json") else { return nil }
        let body = String(name.dropFirst("meshtastic-".count).dropLast(".json".count))
        guard !body.isEmpty, !body.contains(".") else { return nil }
        return body == unknownNode ? body : "!" + body
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

/// Moves the single `messages.json` of older versions (every radio's chats in one file,
/// channels by slot) into one history per radio. Runs once: the old file is kept,
/// renamed `messages.json.migrated-<date>`.
enum MessageMigration {
    /// The old file's shape.
    struct Legacy: Decodable {
        var messages: [ChatMessage] = []
        var lastRead: [String: Date] = [:]

        init(messages: [ChatMessage], lastRead: [String: Date]) {
            self.messages = messages
            self.lastRead = lastRead
        }

        private enum CodingKeys: String, CodingKey { case messages, lastRead }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
            lastRead = try c.decodeIfPresent([String: Date].self, forKey: .lastRead) ?? [:]
        }
    }

    /// The radio each message went through. Received messages (and sends from recent
    /// versions) say so themselves. One that doesn't is given the radio of the message
    /// nearest to it in time that does; with no radio anywhere in the file, the last
    /// node the phone cached, else "unknown".
    static func radio(of index: Int, in messages: [ChatMessage], fallback: String?) -> String {
        if let r = messages[index].radio, !r.isEmpty { return r }
        let t = messages[index].time
        var best: (radio: String, gap: TimeInterval)?
        for m in messages {
            guard let r = m.radio, !r.isEmpty else { continue }
            let gap = abs(m.time.timeIntervalSince(t))
            if best == nil || gap < best!.gap { best = (r, gap) }
        }
        return best?.radio ?? fallback ?? MeshtasticHistory.unknownNode
    }

    /// The old file split into one history per radio. `cache`: the last node's cached
    /// channel names, which give that radio's slot keys their names.
    static func split(_ old: Legacy, cache: MeshtasticCache?) -> [String: MeshtasticHistory] {
        let cachedNode = cache.map { $0.nodeNum.id }
        var out: [String: MeshtasticHistory] = [:]
        for i in old.messages.indices {
            let id = radio(of: i, in: old.messages, fallback: cachedNode)
            var m = old.messages[i]
            if m.radio == nil { m.radio = id == MeshtasticHistory.unknownNode ? nil : id }
            out[id, default: MeshtasticHistory()].messages.append(m)
        }
        // The cached radio's channels: names for its slot keys, and its channel table.
        if let cache, let id = cachedNode, out[id] != nil {
            var names: [Int: String] = [:]
            for ch in cache.channels where !ch.name.isEmpty { names[ch.index] = ch.name }
            out[id]!.messages = out[id]!.messages.map { m in
                guard case .channel(let k) = m.conversation, k.isFallback, k.name.isEmpty,
                      let slot = k.fallbackSlot, let name = names[slot] else { return m }
                var m = m
                m.conversation = .channel(ChannelKey(name: name, slot: slot))
                return m
            }
            out[id]!.channels = cache.channels.map {
                .init(slot: $0.index, name: $0.name, key: ChannelKey(name: $0.name, slot: $0.index), primary: $0.primary)
            }
            out[id]!.node = cache.longName
        }
        // Read marks: "ch5" becomes that history's key for slot 5, "dm!x" stays the same thread.
        for id in out.keys {
            var marks: [String: Date] = [:]
            for (key, date) in old.lastRead {
                for k in newKeys(for: key, in: out[id]!) { marks[k] = max(marks[k] ?? .distantPast, date) }
            }
            out[id]!.lastRead = marks
        }
        return out
    }

    /// The new read-mark keys for an old one, in one history.
    private static func newKeys(for old: String, in h: MeshtasticHistory) -> [String] {
        if old.hasPrefix("ch:") || old.hasPrefix("dm:") { return [old] }
        if old.hasPrefix("dm") { return [Conversation.direct(String(old.dropFirst(2))).key] }
        guard old.hasPrefix("ch"), let slot = Int(old.dropFirst(2)) else { return [] }
        // Every key this history files slot `slot` under (named or not).
        var keys = Set<String>()
        for m in h.messages {
            if case .channel(let k) = m.conversation, k.fallbackSlot == slot { keys.insert(m.conversation.key) }
        }
        for c in h.channels where c.slot == slot { keys.insert(Conversation.channel(c.key).key) }
        if keys.isEmpty { keys.insert(Conversation.channel(slot: slot).key) }
        return Array(keys)
    }

    /// `b` merged into `a`: messages `a` doesn't have yet (by id, or packet and sender), later read marks.
    static func merge(_ a: MeshtasticHistory, _ b: MeshtasticHistory) -> MeshtasticHistory {
        var out = a
        var ids = Set(a.messages.map(\.id))
        var packets = Set(a.messages.map { "\($0.packetID)/\($0.from)" })
        for m in b.messages where !ids.contains(m.id) && !packets.contains("\(m.packetID)/\(m.from)") {
            ids.insert(m.id)
            packets.insert("\(m.packetID)/\(m.from)")
            out.messages.append(m)
        }
        out.messages.sort { $0.time < $1.time }
        for (k, d) in b.lastRead { out.lastRead[k] = max(out.lastRead[k] ?? .distantPast, d) }
        if out.channels.isEmpty { out.channels = b.channels }
        if out.node == nil { out.node = b.node }
        return out
    }

    /// Migrates `folder/messages.json` if it's there. Returns the radios written (nil: nothing to do).
    /// Safe to run again: the old file is renamed, and a second copy merges without duplicates.
    @discardableResult
    static func run(folder: URL, cache: MeshtasticCache?, defaults: UserDefaults, now: Date = Date()) -> [String]? {
        let legacy = folder.appendingPathComponent("messages.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        guard let old = SaveFile.load(Legacy.self, from: legacy, decoder: MeshtasticHistory.decoder()) else { return nil }
        let histories = split(old, cache: cache)
        for (id, h) in histories {
            let url = folder.appendingPathComponent(MeshtasticHistory.fileName(node: id))
            let merged = SaveFile.load(MeshtasticHistory.self, from: url, decoder: MeshtasticHistory.decoder()).map { merge($0, h) } ?? h
            SaveFile.writeNow(merged, to: url, encoder: MeshtasticHistory.encoder())
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let aside = folder.appendingPathComponent("messages.json.migrated-" + f.string(from: now))
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: legacy, to: aside)
        // What to show before a radio connects: the radio with the newest message.
        if defaults.string(forKey: MeshtasticHistory.lastArchiveKey) == nil,
           let newest = histories.max(by: { ($0.value.messages.last?.time ?? .distantPast) < ($1.value.messages.last?.time ?? .distantPast) }) {
            defaults.set(newest.key, forKey: MeshtasticHistory.lastArchiveKey)
        }
        return Array(histories.keys)
    }
}
