import Foundation

/// Where a bridged line was really said. On the wire a bridged line stays plain text
/// with a tag ("[MT] STAY: hi" came from Meshtastic, "[MC] MAYA: hi" from MeshCore) so
/// any app can read it and no bridge relays it back; this is the same thing as data.
public struct BridgeOrigin: Codable, Equatable, Sendable {
    public enum Network: String, Codable, Sendable {
        case meshtastic, meshcore

        public var title: String { self == .meshtastic ? "Meshtastic" : "MeshCore" }
        public var tag: String { self == .meshtastic ? BridgeOrigin.tagMeshtastic : BridgeOrigin.tagMeshCore }
    }

    public static let tagMeshtastic = "[MT]"
    public static let tagMeshCore = "[MC]"

    /// The network it was first said on.
    public var network: Network
    /// The sender there, when known: a Meshtastic "!xxxxxxxx" or a MeshCore key prefix in hex.
    public var senderID: String?
    public var senderName: String
    /// The channel it was said on (its name there), when known.
    public var channel: String?
    /// Hops it travelled on that network before the bridge heard it.
    public var hops: Int?
    /// The bridge's radio that heard it on that network (Meshtastic "!…" or MeshCore key hex).
    public var heardBy: String?
    /// The node that re-posted it here: a Meshtastic "!…" or a MeshCore node's name.
    public var via: String?

    public init(network: Network, senderID: String? = nil, senderName: String, channel: String? = nil,
                hops: Int? = nil, heardBy: String? = nil, via: String? = nil) {
        self.network = network
        self.senderID = senderID
        self.senderName = senderName
        self.channel = channel
        self.hops = hops
        self.heardBy = heardBy
        self.via = via
    }

    enum CodingKeys: String, CodingKey { case network, senderID, senderName, channel, hops, heardBy, via }

    /// Tolerant: a bad or missing detail is dropped. An unknown network fails the whole
    /// origin (the message then keeps no origin rather than a wrong one).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decode(Network.self, forKey: .network)
        senderID = try? c.decodeIfPresent(String.self, forKey: .senderID)
        senderName = (try? c.decodeIfPresent(String.self, forKey: .senderName)) ?? ""
        channel = try? c.decodeIfPresent(String.self, forKey: .channel)
        hops = try? c.decodeIfPresent(Int.self, forKey: .hops)
        heardBy = try? c.decodeIfPresent(String.self, forKey: .heardBy)
        via = try? c.decodeIfPresent(String.self, forKey: .via)
    }

    /// "[MT] STAY: hi" -> STAY on Meshtastic, "hi". MeshCore channel text starts with the
    /// posting node's name ("Bag: [MC] MAYA: hi"): that name becomes `via` unless given.
    public static func parse(_ text: String, via: String? = nil) -> (origin: BridgeOrigin, text: String)? {
        if let r = tagged(text) { return (BridgeOrigin(network: r.network, senderName: r.sender, via: via), r.text) }
        guard let sep = text.range(of: ": "), text.distance(from: text.startIndex, to: sep.lowerBound) <= 32 else { return nil }
        let poster = String(text[..<sep.lowerBound])
        guard !poster.isEmpty, let r = tagged(String(text[sep.upperBound...])) else { return nil }
        return (BridgeOrigin(network: r.network, senderName: r.sender, via: via ?? poster), r.text)
    }

    private static func tagged(_ text: String) -> (network: Network, sender: String, text: String)? {
        for n in [Network.meshtastic, .meshcore] where text.hasPrefix(n.tag + " ") {
            let rest = text.dropFirst(n.tag.count + 1)
            guard let r = rest.range(of: ": ") else { return (n, "", String(rest)) }
            return (n, String(rest[..<r.lowerBound]), String(rest[r.upperBound...]))
        }
        return nil
    }
}
