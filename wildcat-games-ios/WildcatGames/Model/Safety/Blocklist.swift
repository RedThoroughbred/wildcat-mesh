import Foundation

/// Where reports go. Change it here and every report follows.
enum Support {
    static let email = "redthoroughbreds@gmail.com"
    static let site = URL(string: "https://redthoroughbred.github.io/wildcat/")!
    static let privacy = URL(string: "https://redthoroughbred.github.io/wildcat/privacy.html")!
    /// Where the GPL-3.0 source lives (the site's section links each repository).
    static let source = URL(string: "https://redthoroughbred.github.io/wildcat/#source")!
}

/// Someone the player blocked. A Meshtastic node is kept by its node id and a
/// MeshCore contact by its key prefix. Names cover what carries no id: MeshCore
/// channel lines ("MAYA: hi") and lines a bridge relayed ("[MT] STAY: hi").
struct BlockedSender: Codable, Hashable, Identifiable {
    enum Network: String, Codable {
        case meshtastic, meshcore, reticulum

        var name: String {
            switch self {
            case .meshtastic: return "Meshtastic"
            case .meshcore: return "MeshCore"
            case .reticulum: return "Reticulum"
            }
        }
    }

    var network: Network
    /// "!1a2b3c4d" on Meshtastic, the contact's key prefix in hex on MeshCore, the LXMF address
    /// (32 hex digits) on Reticulum, "" when only a name is known.
    var key: String
    /// The names this sender goes by on its network; the first is shown.
    var names: [String]
    var at: Date

    init(network: Network, key: String = "", names: [String], at: Date = Date()) {
        self.network = network
        self.key = key.lowercased()
        var seen = Set<String>()
        self.names = names.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert(Blocklist.norm($0)).inserted }
        self.at = at
    }

    var id: String { "\(network.rawValue):" + (key.isEmpty ? "name:" + Blocklist.norm(names.first ?? "") : key) }
    var name: String { names.first ?? key }

    private enum CodingKeys: String, CodingKey { case network, key, names, at }

    /// Tolerant: a missing or unknown field falls back rather than losing the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = (try? c.decodeIfPresent(Network.self, forKey: .network)) ?? .meshtastic
        key = ((try? c.decodeIfPresent(String.self, forKey: .key)) ?? "").lowercased()
        names = (try? c.decodeIfPresent([String].self, forKey: .names)) ?? []
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? Date()
    }
}

/// Everyone blocked, and the matching rules. Pure value, so it's easy to test.
struct Blocklist: Codable, Equatable {
    private(set) var entries: [BlockedSender] = []

    init(_ entries: [BlockedSender] = []) {
        for e in entries { add(e) }
    }

    private enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let saved = (try? c.decodeIfPresent([BlockedSender].self, forKey: .entries)) ?? []
        // Entries without a key or a name can't match anything.
        entries = saved.filter { !$0.key.isEmpty || !$0.names.isEmpty }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Adds someone, or merges new names into the entry already there.
    mutating func add(_ s: BlockedSender) {
        guard !s.key.isEmpty || !s.names.isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.id == s.id }) {
            entries[i] = BlockedSender(network: s.network, key: s.key, names: entries[i].names + s.names, at: entries[i].at)
        } else {
            entries.append(s)
        }
    }

    mutating func remove(_ s: BlockedSender) {
        entries.removeAll { $0.id == s.id }
    }

    // MARK: Matching

    /// Names compare trimmed, ignoring case and accents.
    static func norm(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    func contains(meshtastic id: String) -> Bool {
        let id = id.lowercased()
        return entries.contains { $0.network == .meshtastic && !$0.key.isEmpty && $0.key == id }
    }

    /// MeshCore keys are compared by prefix, so a 6-byte prefix matches a full key.
    func contains(meshcore keyHex: String) -> Bool {
        let k = keyHex.lowercased()
        guard k.count >= 8 else { return false }
        return entries.contains { $0.network == .meshcore && $0.key.count >= 8 && ($0.key.hasPrefix(k) || k.hasPrefix($0.key)) }
    }

    /// Reticulum senders are blocked by their LXMF address, whole: a name proves nothing there
    /// (anyone can announce any name), and the address is what a message is signed for.
    func contains(reticulum address: String) -> Bool {
        let a = address.lowercased()
        return entries.contains { $0.network == .reticulum && !$0.key.isEmpty && $0.key == a }
    }

    func contains(name: String, on network: BlockedSender.Network) -> Bool {
        let n = Self.norm(name)
        guard !n.isEmpty else { return false }
        return entries.contains { $0.network == network && $0.names.contains { Self.norm($0) == n } }
    }

    /// A Meshtastic text message: its sending node, or for a bridged line, the person it came from.
    func blocksMeshtastic(from node: String?, text: String) -> Bool {
        if let node, contains(meshtastic: node) { return true }
        if let b = Self.bridgedSender(text) { return contains(name: b.name, on: b.network) }
        return false
    }

    /// Someone on this network is blocked by name (so names are worth looking up).
    func hasNames(on network: BlockedSender.Network) -> Bool {
        entries.contains { $0.network == network && !$0.names.isEmpty }
    }

    /// A MeshCore message: a direct one by its contact's key or name (MeshCore blocks are
    /// app-only, so a sender blocked by name from a channel line must not get through by DM),
    /// a room server post by its author's key or name, a channel line by the name it starts
    /// with, a bridged line by the person it came from.
    func blocksMeshCore(contact keyHex: String?, contactName: String? = nil, author authorHex: String? = nil,
                        authorName: String? = nil, channelLine: Bool, text: String) -> Bool {
        if let keyHex, contains(meshcore: keyHex) { return true }
        if let contactName, contains(name: contactName, on: .meshcore) { return true }
        if let authorHex, contains(meshcore: authorHex) { return true }
        if let authorName, contains(name: authorName, on: .meshcore) { return true }
        if let b = Self.bridgedSender(text) { return contains(name: b.name, on: b.network) }
        if channelLine, let n = Self.channelSender(text) { return contains(name: n, on: .meshcore) }
        return false
    }

    // MARK: Reading senders out of text

    /// "MAYA: hello" -> "MAYA": MeshCore channel lines start with the sender's name.
    static func channelSender(_ text: String) -> String? {
        guard let r = text.range(of: ": ") else { return nil }
        let name = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.count > 32 ? nil : name
    }

    /// Who a bridged line really came from, and on which network: "[MT] STAY: hi" is
    /// STAY on Meshtastic. On MeshCore the bridging node's name comes first: "Bag: [MC] MAYA: hi".
    static func bridgedSender(_ text: String) -> (name: String, network: BlockedSender.Network)? {
        var line = text
        if MeshBridge.parse(line) == nil, let r = line.range(of: ": "),
           line.distance(from: line.startIndex, to: r.lowerBound) <= 32 {
            line = String(line[r.upperBound...])
        }
        // parse() names the network itself when a line has no "NAME: " part: nobody to block.
        guard let p = MeshBridge.parse(line), p.sender != p.network else { return nil }
        let name = p.sender.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, p.network == "MeshCore" ? .meshcore : .meshtastic)
    }
}
