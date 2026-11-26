import Foundation
import Observation
import WildcatRadioCore

/// On-device moderation for both networks: who's blocked and the word filter.
/// There is no server; everything here stays on the phone.
@MainActor
@Observable
final class Safety {
    private(set) var blocklist = Blocklist()
    var filterWords = true {
        didSet { defaults.set(filterWords, forKey: "safety.filterWords") }
    }

    @ObservationIgnored private let radio: Radio?
    @ObservationIgnored private let admin: NodeAdmin?
    @ObservationIgnored private let defaults: UserDefaults

    init(radio: Radio? = nil, admin: NodeAdmin? = nil, defaults: UserDefaults = .standard) {
        self.radio = radio
        self.admin = admin
        self.defaults = defaults
        if defaults.object(forKey: "safety.filterWords") != nil { filterWords = defaults.bool(forKey: "safety.filterWords") }
        if let d = defaults.data(forKey: "safety.blocked"), let b = try? JSONDecoder().decode(Blocklist.self, from: d) {
            blocklist = b
        }
    }

    // MARK: Who's hidden

    /// A node your Meshtastic radio ignores counts as blocked: it's the same thing.
    func hides(meshtasticNode id: String) -> Bool {
        if blocklist.contains(meshtastic: id) { return true }
        guard let n = NodeNum(id: id) else { return false }
        return radio?.session.nodes[n]?.isIgnored == true
    }

    /// Also by a name blocked from a bridged line ("[MT] STAY: …") before we knew the node.
    func hides(meshtasticNode id: String, named name: String) -> Bool {
        hides(meshtasticNode: id) || blocklist.contains(name: name, on: .meshtastic)
    }

    /// The name of the MeshCore contact with this key prefix (set by the app from the
    /// connected node, or the last one's save). Lets a block by name cover direct messages.
    @ObservationIgnored var meshcoreName: (Data) -> String? = { _ in nil }

    /// A MeshCore contact by key prefix, or by the name it goes by (looked up only when
    /// someone is blocked by name, so the usual case stays cheap).
    func hides(meshcoreContact prefix: Data) -> Bool {
        blocklist.contains(meshcore: MeshCoreStore.hex(prefix)) || meshcoreNameBlocked(prefix)
    }

    /// A MeshCore contact blocked by key or by name.
    func hides(_ c: MeshCore.Contact) -> Bool {
        blocklist.contains(meshcore: MeshCoreStore.hex(c.prefix)) || blocklist.contains(name: c.name, on: .meshcore)
    }

    private func meshcoreNameBlocked(_ prefix: Data) -> Bool {
        guard !prefix.isEmpty, blocklist.hasNames(on: .meshcore), let name = meshcoreName(prefix) else { return false }
        return blocklist.contains(name: name, on: .meshcore)
    }

    /// A Reticulum sender, by LXMF address.
    func hides(reticulum address: String) -> Bool { blocklist.contains(reticulum: address) }

    func hides(_ m: ChatMessage) -> Bool {
        if !m.outgoing, hides(meshtasticNode: m.from) { return true }
        return blocklist.blocksMeshtastic(from: nil, text: m.text)
    }

    /// A MeshCore message from someone blocked: a direct message by the contact's key or
    /// name, a room server post by its author's, a channel line by the name it starts with.
    func hides(_ c: MeshCoreSession.Chat) -> Bool {
        let received = c.direction == .received
        switch c.origin {
        case .contact(let p):
            guard received else { return blocklist.blocksMeshCore(contact: nil, channelLine: false, text: c.text) }
            let names = blocklist.hasNames(on: .meshcore)
            let author = c.author.flatMap { $0.isEmpty ? nil : $0 }
            return blocklist.blocksMeshCore(contact: MeshCoreStore.hex(p), contactName: names ? meshcoreName(p) : nil,
                                            author: author.map(MeshCoreStore.hex),
                                            authorName: names ? author.flatMap(meshcoreName) : nil,
                                            channelLine: false, text: c.text)
        case .channel:
            return blocklist.blocksMeshCore(contact: nil, channelLine: received, text: c.text)
        }
    }

    // MARK: Word filter

    /// Received text as it may be shown in lists and notifications.
    func shown(_ text: String) -> String { filterWords ? WordFilter.masked(text) : text }

    func masks(_ text: String) -> Bool { filterWords && WordFilter.matches(text) }

    // MARK: Changing the list

    /// Everyone blocked, plus nodes your Meshtastic radio ignores (set here or in another app).
    var blocked: [BlockedSender] {
        var out = blocklist.entries
        if let session = radio?.session {
            for n in session.nodes.values where n.isIgnored && !blocklist.contains(meshtastic: n.num.id) {
                out.append(BlockedSender(network: .meshtastic, key: n.num.id, names: [n.longName, n.shortName].compactMap { $0 }))
            }
        }
        return out.sorted { $0.at > $1.at }
    }

    func block(_ s: BlockedSender) {
        blocklist.add(s)
        save()
        setIgnored(s, true)
    }

    func unblock(_ s: BlockedSender) {
        blocklist.remove(s)
        save()
        setIgnored(s, false)
    }

    /// A MeshCore contact may be blocked by key and by name: clears both.
    func unblock(_ c: MeshCore.Contact) {
        let single = Blocklist([.contact(c)])
        for e in blocklist.entries where e.network == .meshcore
            && (single.contains(meshcore: e.key) || e.names.contains { single.contains(name: $0, on: .meshcore) }) {
            blocklist.remove(e)
        }
        save()
    }

    /// Mirrors a Meshtastic block onto the connected radio's ignore list, so the node drops them too.
    private func setIgnored(_ s: BlockedSender, _ on: Bool) {
        guard s.network == .meshtastic, let n = NodeNum(id: s.key), let radio, let admin,
              radio.source == .bluetooth, radio.isReady, let node = radio.session.nodes[n], node.isIgnored != on else { return }
        Task { await admin.apply([.ignore(n, on)], summary: on ? "Block" : "Unblock") }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(blocklist) { defaults.set(d, forKey: "safety.blocked") }
    }
}

extension BlockedSender {
    /// A Meshtastic node, with the names its bridged lines carry.
    static func node(_ n: NodeInfo) -> BlockedSender {
        BlockedSender(network: .meshtastic, key: n.num.id, names: [n.shortName, n.longName].compactMap { $0 })
    }

    /// A Reticulum sender: the LXMF address is what is blocked; the name is only for the list.
    static func reticulum(_ address: String, name: String?) -> BlockedSender {
        BlockedSender(network: .reticulum, key: address, names: [name].compactMap { $0 })
    }

    @MainActor
    static func contact(_ c: MeshCore.Contact) -> BlockedSender {
        BlockedSender(network: .meshcore, key: MeshCoreStore.hex(c.prefix), names: [c.name])
    }

    /// Someone known only by name (a bridged line, a MeshCore channel line): their node
    /// or contact when this phone knows one by that name, else just the name.
    @MainActor
    static func named(_ name: String, on network: Network, radio: Radio, meshcore: MeshCoreLink) -> BlockedSender {
        let n = Blocklist.norm(name)
        switch network {
        case .meshtastic:
            if let node = radio.session.nodes.values.first(where: { Blocklist.norm($0.shortName ?? "") == n || Blocklist.norm($0.longName ?? "") == n }) {
                return BlockedSender(network: .meshtastic, key: node.num.id, names: [name, node.shortName, node.longName].compactMap { $0 })
            }
        case .meshcore:
            if let c = meshcore.session.contacts.values.first(where: { Blocklist.norm($0.name) == n }) {
                return BlockedSender(network: .meshcore, key: MeshCoreStore.hex(c.prefix), names: [name, c.name])
            }
        case .reticulum:
            break
        }
        return BlockedSender(network: network, names: [name])
    }
}
