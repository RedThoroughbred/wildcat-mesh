import Foundation
import Observation
import UserNotifications
import WildcatRadioCore

/// Keeps MeshCore chats and contacts across launches (one file per node), counts
/// unread messages, and notifies about new ones when you're not looking at that chat.
/// While no node is connected it serves the last node's saved chats, read-only.
@MainActor
@Observable
final class MeshCoreStore {
    /// Last time each conversation was read, keyed by `key(_:)`.
    private(set) var lastRead: [String: Date] = [:]
    struct RepeaterState: Equatable {
        var loggedIn = false
        var isAdmin = false
        var loginFailed = false
        var status: MeshCore.RepeaterStatus?
        var statusAt: Date?
    }
    /// Direct messages a contact confirmed since launch, practice left out (the ratings prompt watches it).
    private(set) var confirmedCount = 0
    /// Trace results by tag.
    private(set) var traces: [UInt32: MeshCore.TraceResult] = [:]

    /// Per repeater (keyed by the 6-byte key prefix in hex).
    private(set) var repeaters: [String: RepeaterState] = [:]

    /// The last real node's saved chats, contacts and channel names, as a session to read
    /// while nothing is connected (nil when there's no save). Kept fresh as it saves.
    private(set) var offline: MeshCoreSession?
    /// That node's name, when the save knows it.
    private(set) var offlineName: String?

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func repeater(_ c: MeshCore.Contact) -> RepeaterState { repeaters[Self.hex(c.prefix)] ?? RepeaterState() }
    func clearLogin(_ c: MeshCore.Contact) { repeaters[Self.hex(c.prefix)] = RepeaterState() }

    /// Remembered admin passwords live in the Keychain, never in files.
    static func savedPassword(_ c: MeshCore.Contact) -> String? { Keychain.read("meshcore.pw." + hex(c.publicKey)) }
    static func savePassword(_ pw: String?, for c: MeshCore.Contact) { Keychain.write(pw, for: "meshcore.pw." + hex(c.publicKey)) }

    /// The chat on screen right now (no notifications for it).
    var openChat: MeshCore.Message.Origin?
    var isForeground = true
    /// Blocks and the word filter (set by the app).
    @ObservationIgnored var safety: Safety?

    private let link: MeshCoreLink
    @ObservationIgnored private let saver = Debouncer(.seconds(5))
    @ObservationIgnored private var nodeKey: String?
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let defaults: UserDefaults

    /// Which node's file was used last (its key's first 8 bytes in hex), for reading it before a connection.
    static let lastArchiveKey = "meshcore.lastArchive"

    init(link: MeshCoreLink, folder: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
         defaults: UserDefaults = .standard) {
        self.link = link
        self.folder = folder
        self.defaults = defaults
        if let d = defaults.data(forKey: "meshcore.lastRead"),
           let r = try? JSONDecoder().decode([String: Date].self, from: d) { lastRead = r }
        replaced = Set((defaults.stringArray(forKey: Self.replacedKey) ?? []).compactMap(UUID.init(uuidString:)))
        link.addListener { [weak self] in self?.handle($0) }
        loadOffline()
    }

    static func key(_ o: MeshCore.Message.Origin) -> String {
        switch o {
        case .channel(let i): return "ch:\(i)"
        case .contact(let p): return "dm:" + p.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: What's shown

    /// Where chats, names and contacts come from: the node (or the practice node) when
    /// connected, else the last real node's save.
    var source: MeshCoreSession { link.state.isReady ? link.session : (offline ?? link.session) }

    /// No node connected, showing the last one's saved chats (nothing can be sent).
    var isOffline: Bool { !link.state.isReady && offline != nil }

    /// From someone the player blocked: never listed, counted or notified.
    func isHidden(_ c: MeshCoreSession.Chat) -> Bool { safety?.hides(c) ?? false }

    /// The chats worth showing: conversation text, nothing from blocked senders, no
    /// failed copies of messages that were sent again.
    var visibleChats: [MeshCoreSession.Chat] {
        source.conversationChats.filter { !isHidden($0) && !replaced.contains($0.id) }
    }

    /// Failed direct messages that were sent again (their failed copy leaves the chat, as on Meshtastic).
    private(set) var replaced: Set<UUID> = []
    static let replacedKey = "meshcore.replaced"

    /// Sends a failed direct message again; the failed copy goes. False when it didn't
    /// fail, or the node isn't connected or doesn't know the contact.
    @discardableResult
    func retry(_ c: MeshCoreSession.Chat) -> Bool {
        guard link.state.isReady, c.direction == .sent, case .contact(let p) = c.origin,
              ChatMeta.meshcoreDirectStatus(c).isFailed, let contact = link.session.contact(prefix: p) else { return false }
        link.send(text: c.text, to: contact)
        replaced.insert(c.id)
        // Capped: a few hundred is plenty (chats themselves are capped at 1000).
        if replaced.count > 300 { replaced.remove(replaced.first { $0 != c.id } ?? c.id) }
        if !link.isDemo { defaults.set(replaced.map(\.uuidString), forKey: Self.replacedKey) }
        return true
    }

    /// Direct threads, newest first, leaving out blocked contacts (by key or name).
    var directs: [MeshCore.Message.Origin] {
        var seen: [MeshCore.Message.Origin] = []
        for c in visibleChats.reversed() {
            if case .contact(let p) = c.origin, !seen.contains(c.origin), safety?.hides(meshcoreContact: p) != true { seen.append(c.origin) }
        }
        return seen
    }

    /// "You: hi" or the last line received, word-filtered.
    func lastLine(_ o: MeshCore.Message.Origin) -> String? {
        visibleChats.last { $0.origin == o }.map {
            $0.direction == .sent ? "You: " + $0.text : (safety?.shown($0.text) ?? $0.text)
        }
    }

    func unread(_ o: MeshCore.Message.Origin) -> Int {
        let since = lastRead[Self.key(o)] ?? .distantPast
        // Our clock, not the sender's (`at`), which can be far off.
        return source.conversationChats.filter {
            $0.origin == o && $0.direction == .received && ($0.receivedAt ?? $0.at) > since && !isHidden($0)
        }.count
    }

    var totalUnread: Int {
        Set(source.conversationChats.map(\.origin)).reduce(0) { $0 + unread($1) }
    }

    func markRead(_ o: MeshCore.Message.Origin) {
        lastRead[Self.key(o)] = Date()
        // Practice reads aren't kept (the practice node's chats aren't either).
        if !link.isDemo, let d = try? JSONEncoder().encode(lastRead) { defaults.set(d, forKey: "meshcore.lastRead") }
    }

    // MARK: Events

    private func handle(_ e: MeshCoreSession.Event) {
        switch e {
        case .ready:
            guard !link.isDemo, let me = link.session.me else { nodeKey = nil; return }
            nodeKey = me.publicKey.prefix(8).map { String(format: "%02x", $0) }.joined()
            defaults.set(nodeKey, forKey: Self.lastArchiveKey)
            if let a = load() { link.restore(chats: Self.settled(a.chats), contacts: a.contacts) }
            scheduleSave()
        case .message(let chat):
            scheduleSave()
            if chat.direction == .received, chat.textType != 1, !isForeground || openChat != chat.origin { notify(chat) }
            if openChat == chat.origin, isForeground { markRead(chat.origin) }
        case .contactsChanged, .delivery:
            scheduleSave()
        case .confirmed:
            if !link.isDemo { confirmedCount += 1 }
        case .login(let p, let ok, let admin):
            var r = repeaters[Self.hex(p)] ?? RepeaterState()
            r.loggedIn = ok
            r.isAdmin = admin
            r.loginFailed = !ok
            repeaters[Self.hex(p)] = r
        case .trace(let tr):
            traces[tr.tag] = tr
        case .status(let p, let s):
            var r = repeaters[Self.hex(p)] ?? RepeaterState()
            r.status = s
            r.statusAt = Date()
            repeaters[Self.hex(p)] = r
        default:
            break
        }
    }

    private func notify(_ c: MeshCoreSession.Chat) {
        guard !isHidden(c) else { return }
        let content = UNMutableNotificationContent()
        content.title = link.session.label(c.origin)
        content.subtitle = "MeshCore"
        content.body = safety?.shown(c.text) ?? c.text
        content.sound = .default
        content.threadIdentifier = Self.key(c.origin)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: c.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Saving

    struct Archive: Codable {
        /// A channel's slot and name (never its key).
        struct SavedChannel: Codable, Equatable {
            var index: Int
            var name: String
        }

        var chats: [MeshCoreSession.Chat] = []
        var contacts: [MeshCore.Contact] = []
        var channels: [SavedChannel] = []
        /// The node's own name.
        var node: String?

        init(chats: [MeshCoreSession.Chat], contacts: [MeshCore.Contact], channels: [SavedChannel] = [], node: String? = nil) {
            self.chats = chats
            self.contacts = contacts
            self.channels = channels
            self.node = node
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chats = try c.decodeIfPresent([MeshCoreSession.Chat].self, forKey: .chats) ?? []
            contacts = try c.decodeIfPresent([MeshCore.Contact].self, forKey: .contacts) ?? []
            channels = (try? c.decodeIfPresent([SavedChannel].self, forKey: .channels)) ?? []
            node = try? c.decodeIfPresent(String.self, forKey: .node)
        }
    }

    /// Contacts kept in the file: the most recently heard (a busy mesh adverts hundreds).
    nonisolated static let keepContacts = 500

    nonisolated static func pruned(_ contacts: [MeshCore.Contact], keep: Int = keepContacts) -> [MeshCore.Contact] {
        guard contacts.count > keep else { return contacts }
        return Array(contacts.sorted { ($0.lastAdvert ?? $0.lastModified ?? .distantPast) > ($1.lastAdvert ?? $1.lastModified ?? .distantPast) }
            .prefix(keep))
    }

    /// Direct messages saved while still on their way can't finish any more (the node's
    /// retries went with the connection): they read as not delivered, with a Retry.
    nonisolated static func settled(_ chats: [MeshCoreSession.Chat]) -> [MeshCoreSession.Chat] {
        chats.map { c in
            guard c.direction == .sent, !c.confirmed else { return c }
            var c = c
            switch c.delivery {
            case .sending(let a)?: c.delivery = .failed(a == 0 ? .nodeDidNotAnswer : .noConfirmation(attempts: a))
            case .sent(let a, _)?: c.delivery = .failed(.noConfirmation(attempts: a + 1))
            default: break
            }
            return c
        }
    }

    /// A read-only session from a save: its chats (in-flight ones settled), contacts and channel names.
    nonisolated static func session(from a: Archive) -> MeshCoreSession {
        var s = MeshCoreSession()
        for ch in a.channels {
            // Only the name is kept: a placeholder key keeps the slot listed.
            _ = s.handle(.channelInfo(index: ch.index, name: ch.name, secret: Data(repeating: 0xFF, count: 16)))
        }
        s.restore(chats: settled(a.chats), contacts: a.contacts)
        return s
    }

    private func url(_ key: String) -> URL? { folder?.appendingPathComponent("meshcore-\(key).json") }
    private var url: URL? { nodeKey.flatMap(url) }

    /// The saved chats and contacts; an unreadable file is set aside, never overwritten.
    private func load() -> Archive? {
        guard let url else { return nil }
        return SaveFile.load(Archive.self, from: url)
    }

    /// The last node's file: the one used last, or (saved before that was noted) the newest.
    private func lastArchiveURL() -> URL? {
        if let k = defaults.string(forKey: Self.lastArchiveKey), let u = url(k),
           FileManager.default.fileExists(atPath: u.path) { return u }
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { $0.lastPathComponent.hasPrefix("meshcore-") && $0.pathExtension == "json" }
            .max { modified($0) < modified($1) }
    }

    /// Reads the last node's save for showing while disconnected.
    func loadOffline() {
        guard let u = lastArchiveURL(), let a = SaveFile.load(Archive.self, from: u) else { return }
        keepOffline(a)
    }

    private func keepOffline(_ a: Archive) {
        offline = Self.session(from: a)
        offlineName = a.node
    }

    /// Saves within 5 s (adverts arrive constantly), encoding off the main thread.
    func scheduleSave() {
        saver.schedule { [weak self] in
            guard let self, let saved = archive() else { return }
            SaveFile.write(saved.archive, to: saved.url)
            keepOffline(saved.archive)
        }
    }

    /// Saves right now (the app is going to the background).
    func save() {
        saver.cancel()
        guard let saved = archive() else { return }
        SaveFile.writeNow(saved.archive, to: saved.url)
        keepOffline(saved.archive)
    }

    private func archive() -> (archive: Archive, url: URL)? {
        guard let url, link.session.isReady, !link.isDemo else { return nil }
        let s = link.session
        let channels = s.channels.values.sorted { $0.index < $1.index }.map { Archive.SavedChannel(index: $0.index, name: $0.name) }
        return (Archive(chats: s.chats, contacts: Self.pruned(Array(s.contacts.values)), channels: channels, node: s.me?.name), url)
    }
}
