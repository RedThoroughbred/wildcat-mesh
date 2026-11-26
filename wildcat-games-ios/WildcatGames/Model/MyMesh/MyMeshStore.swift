import Foundation
import Observation
import WildcatRadioCore

/// The radios the user owns, across both networks. A node joins when the
/// phone connects to it over Bluetooth, when you log in to a MeshCore
/// repeater as admin, or when you mark it as yours; every fresh report
/// updates its record. Practice nodes are shown while practice runs and are
/// never saved.
@MainActor
@Observable
final class MyMeshStore {
    private(set) var saved: [OwnedNode] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private weak var radio: Radio?
    @ObservationIgnored private weak var meshcore: MeshCoreLink?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastMeshCoreRefresh: Date = .distantPast
    @ObservationIgnored private var practiceCache: (at: Date, nodes: [OwnedNode])?
    /// Tests set this instead of starting a practice mesh.
    @ObservationIgnored var practiceOverride: Bool?

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("my-mesh.json")
    }

    init(file: URL = MyMeshStore.defaultURL) {
        fileURL = file
        load()
    }

    /// Listens to both radios for connections, logins and fresh reports.
    func attach(radio: Radio) {
        self.radio = radio
        radio.addListener { [weak self, weak radio] e in
            guard let self, let radio, radio.source == .bluetooth, let link = radio.link else { return }
            switch e {
            case .ready: self.connected(meshtastic: link.session, bluetoothID: link.lastNodeID)
            case .packet(let p): self.heard(meshtastic: link.session, from: p.from)
            case .myNode: break
            }
        }
    }

    func attach(meshcore link: MeshCoreLink) {
        meshcore = link
        link.addListener { [weak self, weak link] e in
            guard let self, let link, !link.isDemo else { return }
            let s = link.session
            switch e {
            case .ready:
                self.connected(meshcore: s, bluetoothID: link.lastNodeID)
            case .contactsChanged:
                self.refreshContacts(s)
            case .login(let prefix, let ok, let admin):
                if ok, admin, let c = s.contact(prefix: prefix) { self.adminLogin(c, companion: s.me) }
            case .status(let prefix, let status):
                self.repeaterStatus(prefix: prefix, .init(status, at: Date()))
            case .heard, .message:
                // Battery and radio changes arrive without an event of their own.
                if Date().timeIntervalSince(self.lastMeshCoreRefresh) > 30 { self.refresh(meshcore: s) }
            default:
                break
            }
        }
    }

    /// Re-reads whatever is connected now (opening My Mesh).
    func refreshFromLinks() {
        if let radio, radio.source == .bluetooth, let link = radio.link, link.state.isReady {
            _ = OwnedNode.meshtastic(link.session).map { upsert($0, insert: false) }
            refreshHeard(meshtastic: link.session)
        }
        if let meshcore, meshcore.state.isReady, !meshcore.isDemo {
            refresh(meshcore: meshcore.session)
            meshcore.refreshBattery()
        }
    }

    // MARK: What the screens show

    var isPracticeRunning: Bool {
        practiceOverride ?? (radio?.source == .practice || meshcore?.isDemo == true)
    }

    /// Saved nodes, plus the pretend ones while practice runs. Connected first, then most recently heard.
    var nodes: [OwnedNode] {
        let all = (isPracticeRunning ? practiceNodes() : []) + saved
        return all.sorted {
            let a = isConnected($0), b = isConnected($1)
            if a != b { return a }
            let ha = $0.lastHeard ?? .distantPast, hb = $1.lastHeard ?? .distantPast
            if ha != hb { return ha > hb }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func node(_ id: String) -> OwnedNode? { nodes.first { $0.id == id } }

    func contains(_ id: String) -> Bool { saved.contains { $0.id == id } }

    /// Talking to this phone over Bluetooth right now.
    func isConnected(_ n: OwnedNode) -> Bool {
        if n.origin == .practice {
            switch n.network {
            case .meshtastic: return radio?.source == .practice || practiceOverride == true
            case .meshcore: return n.meshcoreKind == .chat && (meshcore?.isDemo == true || practiceOverride == true)
            }
        }
        switch n.network {
        case .meshtastic:
            guard let radio, radio.source == .bluetooth, radio.isReady else { return false }
            return radio.session.myNode?.id == n.nodeID
        case .meshcore:
            guard let meshcore, meshcore.state.isReady, !meshcore.isDemo, let me = meshcore.session.me else { return false }
            return OwnedNode.hex(me.publicKey.prefix(6)) == n.nodeID
        }
    }

    /// Connected, or heard in the last hour.
    func isOnline(_ n: OwnedNode, now: Date = Date()) -> Bool {
        isConnected(n) || (n.lastHeard.map { now.timeIntervalSince($0) < 3600 } ?? false)
    }

    var onlineCount: Int { nodes.filter { isOnline($0) }.count }

    // MARK: Changes

    /// "This one's mine" from a node or contact screen.
    func markMine(_ n: OwnedNode) {
        var n = n
        if n.origin == .practice { return }
        n.origin = .manual
        upsert(n, insert: true)
    }

    func remove(_ id: String) {
        saved.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Merges `n` into its saved record; adds it only when `insert` is true. Returns whether it's (now) saved.
    @discardableResult
    func upsert(_ n: OwnedNode, insert: Bool) -> Bool {
        guard n.origin != .practice else { return false }
        if let i = saved.firstIndex(where: { $0.id == n.id }) {
            var m = saved[i]
            m.merge(n)
            if m != saved[i] { saved[i] = m; scheduleSave() }
            return true
        }
        guard insert else { return false }
        saved.append(n)
        scheduleSave()
        return true
    }

    // MARK: Reports from the radios

    /// The phone just connected to a Meshtastic node.
    func connected(meshtastic s: MeshSession, bluetoothID: UUID?, now: Date = Date()) {
        guard let n = OwnedNode.meshtastic(s, bluetoothID: bluetoothID, now: now) else { return }
        upsert(n, insert: true)
        refreshHeard(meshtastic: s)
    }

    /// A packet arrived: refresh the connected node (its own telemetry) or an owned node we heard.
    func heard(meshtastic s: MeshSession, from: NodeNum, now: Date = Date()) {
        if from == s.myNode {
            if let n = OwnedNode.meshtastic(s, now: now) {
                var fresh = n
                fresh.lastConnected = nil   // a packet isn't a new connection
                upsert(fresh, insert: false)
            }
        } else if contains(OwnedNode.id(.meshtastic, from.id)), let info = s.nodes[from] {
            upsert(OwnedNode.meshtastic(info, now: now), insert: false)
        }
    }

    /// Owned Meshtastic nodes the connected one has heard (a home base, a second handheld).
    func refreshHeard(meshtastic s: MeshSession) {
        for n in saved where n.network == .meshtastic {
            guard let num = NodeNum(id: n.nodeID), num != s.myNode, let info = s.nodes[num] else { continue }
            upsert(OwnedNode.meshtastic(info), insert: false)
        }
    }

    /// The phone just connected to a MeshCore companion.
    func connected(meshcore s: MeshCoreSession, bluetoothID: UUID?, now: Date = Date()) {
        guard let n = OwnedNode.meshcore(s, bluetoothID: bluetoothID, now: now) else { return }
        upsert(n, insert: true)
        refreshContacts(s)
        lastMeshCoreRefresh = now
    }

    /// Fresh battery and radio settings for the connected companion.
    func refresh(meshcore s: MeshCoreSession, now: Date = Date()) {
        lastMeshCoreRefresh = now
        if var n = OwnedNode.meshcore(s, now: now) {
            n.lastConnected = nil
            upsert(n, insert: false)
        }
        refreshContacts(s)
    }

    /// Owned repeaters and room servers, from the companion's contact list (name, last advert, location).
    func refreshContacts(_ s: MeshCoreSession) {
        for n in saved where n.network == .meshcore && n.meshcoreKind != .chat {
            guard let prefix = Self.bytes(hex: n.nodeID), let c = s.contact(prefix: prefix) else { continue }
            upsert(OwnedNode.meshcore(c, origin: n.origin), insert: false)
        }
    }

    /// Logged in to a repeater as admin: it's ours.
    func adminLogin(_ c: MeshCore.Contact, companion: MeshCore.SelfInfo?, now: Date = Date()) {
        var n = OwnedNode.meshcore(c, companion: companion, origin: .admin, now: now)
        n.lastHeard = OwnedNode.later(n.lastHeard, now)   // it just answered
        upsert(n, insert: true)
    }

    /// A status reply from a repeater we own.
    func repeaterStatus(prefix: Data, _ status: OwnedNode.RepeaterSnapshot) {
        let id = OwnedNode.id(.meshcore, OwnedNode.hex(prefix.prefix(6)))
        guard var n = saved.first(where: { $0.id == id }) else { return }
        n.repeater = status
        if let mv = status.batteryMillivolts { n.batteryVolts = Double(mv) / 1000 }
        n.lastHeard = OwnedNode.later(n.lastHeard, status.at)
        upsert(n, insert: false)
    }

    // MARK: Practice

    /// A pretend repeater, companion and handheld, matching the practice meshes.
    func practiceNodes(now: Date = Date()) -> [OwnedNode] {
        if let c = practiceCache, now.timeIntervalSince(c.at) < 60 { return c.nodes }
        let nodes = Self.practiceNodes(now: now)
        practiceCache = (now, nodes)
        return nodes
    }

    static func practiceNodes(now: Date) -> [OwnedNode] {
        let demo = MeshCoreSession.demo(now: now)
        var out: [OwnedNode] = []
        if var c = OwnedNode.meshcore(demo, now: now) {
            c.origin = .practice
            c.name = "Practice Companion"
            out.append(c)
        }
        if let rpt = demo.contacts.values.first(where: { $0.kind == .repeater && $0.pathLength == 0 }) {
            var r = OwnedNode.meshcore(rpt, companion: demo.me, origin: .practice, now: now)
            r.hardware = "Solar repeater"
            r.firmware = demo.device?.version
            r.batteryVolts = 4.05
            r.repeater = .init(uptimeSeconds: 12 * 86_400 + 3 * 3600, packetsRelayed: 18_452, packetsHeard: 25_310,
                               noiseFloor: -112, batteryMillivolts: 4050, at: now.addingTimeInterval(-600))
            out.append(r)
        }
        out.append(OwnedNode(network: .meshtastic, nodeID: PracticeMesh.me.id, name: "Practice Handheld", shortName: "PRAC",
                             hardware: "Handheld", firmware: "practice", roleCode: DeviceRole.client.rawValue,
                             radio: .init(region: "US 915", preset: "Long Fast", slot: 20, channels: ["LongFast", "WGHUNT"]),
                             batteryVolts: 3.95, batteryPercent: 76, sharesLocation: false, lastConnected: now,
                             lastHeard: now, origin: .practice, added: now))
        return out
    }

    /// Bytes from a hex string ("a1b2c3"); nil if it isn't hex.
    static func bytes(hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0, chars.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) })
        else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }

    // MARK: Saving

    private struct Saved: Codable {
        var nodes: [Lossy]
    }

    /// One saved node; an unreadable one is skipped instead of failing the whole file.
    private struct Lossy: Codable {
        var node: OwnedNode?
        init(_ n: OwnedNode) { node = n }
        init(from decoder: Decoder) throws { node = try? OwnedNode(from: decoder) }
        func encode(to encoder: Encoder) throws { try node.encode(to: encoder) }
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL) else { return }
        if let s = try? JSONDecoder().decode(Saved.self, from: d) {
            saved = s.nodes.compactMap(\.node).filter { $0.origin != .practice }
        } else {
            // Keep an unreadable file aside rather than overwrite it on the next save.
            let bad = fileURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.copyItem(at: fileURL, to: bad)
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        let s = Saved(nodes: saved.filter { $0.origin != .practice }.map(Lossy.init))
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: fileURL, options: .atomic) }
    }
}
