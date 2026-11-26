import CryptoKit
import Foundation
import WildcatRadioCore

/// A Meshtastic channel's identity: its name and key, not the slot it sits in.
/// A channel that moves slot keeps its chat; two different channels that take
/// turns in one slot never share one.
///
/// Stored as one string: `"<name>|<key hash>"`, or `"<name>|?<slot>"` when the
/// key isn't known (practice nodes, and chats saved by older versions by slot
/// alone). A slot-only key heals to the real one when that radio connects.
struct ChannelKey: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    /// A channel whose key is known: the name and the first 8 bytes of SHA-256(PSK).
    init(name: String, psk: Data) {
        let digest = SHA256.hash(data: psk)
        rawValue = name + "|" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A channel known only by its slot (and name, when known).
    init(name: String, slot: Int) {
        rawValue = name + "|?" + String(max(0, slot))
    }

    init(rawValue: String) { self.rawValue = rawValue }

    /// The identity of a channel the node reported. Without its settings (practice) it's a slot key.
    init(info: ChannelInfo) {
        if let raw = info.settings {
            self.init(name: info.name, psk: ChannelSettings(raw: raw).psk)
        } else {
            self.init(name: info.name, slot: info.index)
        }
    }

    private var split: (name: Substring, tail: Substring) {
        guard let bar = rawValue.lastIndex(of: "|") else { return (Substring(rawValue), "") }
        return (rawValue[..<bar], rawValue[rawValue.index(after: bar)...])
    }

    /// The channel's name ("" for an unnamed primary).
    var name: String { String(split.name) }

    /// True when only the slot is known, not the key.
    var isFallback: Bool { split.tail.hasPrefix("?") }

    /// The slot a slot-only key stands for.
    var fallbackSlot: Int? {
        let t = split.tail
        guard t.hasPrefix("?") else { return nil }
        return Int(t.dropFirst())
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One Meshtastic chat: a channel (by identity) or a direct thread with one node.
enum Conversation: Hashable, Codable {
    case channel(ChannelKey)
    /// A direct message thread with one node ("!xxxxxxxx").
    case direct(String)

    /// The channel in `slot` on the connected radio (a slot key; the store resolves it
    /// to the real channel there). For callers that only know the slot: the bridge, tests.
    static func channel(slot: Int, name: String = "") -> Conversation { .channel(ChannelKey(name: name, slot: slot)) }

    /// The key chats are filed under (read marks, notification threads).
    var key: String {
        switch self {
        case .channel(let k): return "ch:" + k.rawValue
        case .direct(let id): return "dm:" + id
        }
    }

    private enum CodingKeys: String, CodingKey { case channel, direct }
    private enum Payload: String, CodingKey { case _0 }

    /// Reads both shapes: `{"channel":{"_0":"name|hash"}}` and the old `{"channel":{"_0":5}}` (a slot key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.channel) {
            let p = try c.nestedContainer(keyedBy: Payload.self, forKey: .channel)
            if let slot = try? p.decode(Int.self, forKey: ._0) {
                self = .channel(ChannelKey(name: "", slot: slot))
            } else {
                self = .channel(try p.decode(ChannelKey.self, forKey: ._0))
            }
        } else {
            let p = try c.nestedContainer(keyedBy: Payload.self, forKey: .direct)
            self = .direct(try p.decode(String.self, forKey: ._0))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .channel(let k):
            var p = c.nestedContainer(keyedBy: Payload.self, forKey: .channel)
            try p.encode(k, forKey: ._0)
        case .direct(let id):
            var p = c.nestedContainer(keyedBy: Payload.self, forKey: .direct)
            try p.encode(id, forKey: ._0)
        }
    }
}
