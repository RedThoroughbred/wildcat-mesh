import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// MeshCore direct-message delivery as the chat shows it, saved chats while disconnected,
/// blocks by name reaching direct messages, and the "Set up" key's words.
@MainActor
final class MeshCoreMessagesTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "mc-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
    }

    private func sent(_ text: String = "hi", delivery: MeshCoreSession.Chat.Delivery?, ack: UInt32? = nil,
                      confirmed: Bool = false) -> MeshCoreSession.Chat {
        var c = MeshCoreSession.Chat(id: UUID(), direction: .sent, origin: .contact(Data([1, 2, 3, 4, 5, 6])), text: text,
                                     at: Date(), ack: ack, confirmed: confirmed)
        c.delivery = delivery
        return c
    }

    private func line(_ status: ChatLine.Status, flood: Bool? = nil) -> ChatLine {
        var l = ChatLine(id: UUID(), network: .meshcore, time: Date(), text: "hi")
        l.mine = true
        l.status = status
        l.flood = flood
        return l
    }

    // MARK: Delivery status

    func testDeliveryMapsToChatStatus() {
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: .sending(attempt: 0))), .sending)
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: .sending(attempt: 1))), .retrying(try: 2))
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: .sent(attempt: 0, flood: false))), .awaiting(try: 1, flood: false))
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: .sent(attempt: 2, flood: true))), .awaiting(try: 3, flood: true))
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: .delivered)), .delivered)
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: .failed(.noConfirmation(attempts: 3)))),
                       .undelivered("No confirmation after 3 tries"))
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: .failed(.rejected(code: 3)))),
                       .undelivered("Your node's send queue is full"))
    }

    func testChatsSavedBeforeDeliveryUseConfirmedAndAck() {
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: nil)), .sending)
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: nil, ack: 7)), .sent)
        XCTAssertEqual(ChatMeta.meshcoreDirectStatus(sent(delivery: nil, ack: 7, confirmed: true)), .delivered)
    }

    func testStatusWords() {
        XCTAssertEqual(ChatMeta.status(line(.sending)), "sending…")
        XCTAssertEqual(ChatMeta.status(line(.retrying(try: 2))), "sending · try 2")
        XCTAssertEqual(ChatMeta.status(line(.awaiting(try: 1, flood: false))), "sent")
        XCTAssertEqual(ChatMeta.status(line(.awaiting(try: 3, flood: true))), "sent by flood · try 3")
        XCTAssertEqual(ChatMeta.status(line(.undelivered("No confirmation after 3 tries"))), "no confirmation after 3 tries")
        XCTAssertEqual(ChatMeta.status(line(.failed("No answer"))), "not sent · No answer", "Meshtastic unchanged")
        XCTAssertTrue(ChatLine.Status.undelivered("x").isFailed)
        XCTAssertTrue(ChatLine.Status.failed("x").isFailed)
        XCTAssertFalse(ChatLine.Status.awaiting(try: 3, flood: true).isFailed)
        // "sent by flood" already says flood: the raw part doesn't repeat it.
        XCTAssertEqual(ChatMeta.sentRaw(line(.awaiting(try: 3, flood: true), flood: true)), nil)
        XCTAssertEqual(ChatMeta.sentRaw(line(.awaiting(try: 1, flood: false), flood: false)), "direct route")
    }

    func testSavedInFlightMessagesSettleAsFailed() {
        let chats = [sent(delivery: .sending(attempt: 0)), sent(delivery: .sending(attempt: 2)),
                     sent(delivery: .sent(attempt: 1, flood: false)), sent(delivery: .delivered),
                     sent(delivery: nil, ack: 4)]
        let settled = MeshCoreStore.settled(chats).map(\.delivery)
        XCTAssertEqual(settled, [.failed(.nodeDidNotAnswer), .failed(.noConfirmation(attempts: 2)),
                                 .failed(.noConfirmation(attempts: 2)), .delivered, nil])
    }

    /// Practice: DEX's first try is never confirmed, so the message is sent again and then delivered.
    func testPracticeDirectMessageRetriesThenDelivers() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let link = MeshCoreLink(defaults: defaults)
        link.clock = { now }
        link.startDemo(timer: false)
        var events: [MeshCoreSession.Event] = []
        link.addListener { events.append($0) }
        let dex = try XCTUnwrap(link.session.contacts.values.first { $0.name.hasPrefix("DEX") })
        let id = link.send(text: "Where are you?", to: dex)
        func status() -> ChatLine.Status? { link.session.chats.last { $0.id == id }.map(ChatMeta.meshcoreDirectStatus) }
        XCTAssertEqual(status(), .awaiting(try: 1, flood: false))
        for _ in 0..<11 { now += 1; link.tick() }
        XCTAssertEqual(status(), .awaiting(try: 2, flood: false), "the first try ran out: sent again")
        XCTAssertTrue(events.contains(.delivery(id: id, .sending(attempt: 1))))
        for _ in 0..<5 { now += 1; link.tick() }
        XCTAssertEqual(status(), .delivered)
        XCTAssertTrue(events.contains(.delivery(id: id, .delivered)))
        link.disconnect()
    }

    // MARK: Saved chats while disconnected

    func testArchiveBecomesAReadOnlySession() {
        let maya = MeshCore.Contact(publicKey: Data([0x51] + Array(repeating: 1, count: 31)), kind: .chat, flags: 0, pathLength: 1,
                                    name: "MAYA Field Unit", lastAdvert: nil, position: nil, lastModified: nil)
        var dm = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .contact(maya.prefix), text: "hello", at: Date())
        dm.receivedAt = Date()
        let ch = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .channel(2), text: "N0CALL: hi", at: Date())
        var mine = sent(delivery: .sent(attempt: 0, flood: true))
        mine.origin = .contact(maya.prefix)
        let a = MeshCoreStore.Archive(chats: [dm, ch, mine], contacts: [maya],
                                      channels: [.init(index: 0, name: "Public"), .init(index: 2, name: "Trail Crew")], node: "N0CALL Bag")
        let s = MeshCoreStore.session(from: a)
        XCTAssertEqual(s.label(.channel(2)), "Trail Crew")
        XCTAssertEqual(s.label(.contact(maya.prefix)), "MAYA Field Unit")
        XCTAssertEqual(s.conversationChats.count, 3)
        XCTAssertEqual(s.chats.last?.delivery, .failed(.noConfirmation(attempts: 1)), "in flight when saved: settled")
    }

    func testStoreShowsTheLastNodesChatsBeforeConnecting() throws {
        let a = MeshCoreStore.Archive(chats: [MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .channel(0),
                                                                    text: "N0CALL: saved line", at: Date())],
                                      contacts: [], channels: [.init(index: 0, name: "Public")], node: "N0CALL Bag")
        try JSONEncoder().encode(a).write(to: folder.appendingPathComponent("meshcore-0011223344556677.json"))
        defaults.set("0011223344556677", forKey: MeshCoreStore.lastArchiveKey)
        let link = MeshCoreLink(defaults: defaults)
        let store = MeshCoreStore(link: link, folder: folder, defaults: defaults)
        XCTAssertTrue(store.isOffline)
        XCTAssertEqual(store.offlineName, "N0CALL Bag")
        XCTAssertEqual(store.visibleChats.map(\.text), ["N0CALL: saved line"])
        XCTAssertEqual(store.lastLine(.channel(0)), "N0CALL: saved line")
        // Connecting (here, practice) shows that node instead.
        link.startDemo(timer: false)
        XCTAssertFalse(store.isOffline)
        XCTAssertFalse(store.visibleChats.contains { $0.text == "N0CALL: saved line" })
        link.disconnect()
        XCTAssertTrue(store.isOffline, "practice over: the saved chats are back")
    }

    func testOfflineFallsBackToTheNewestSave() throws {
        let a = MeshCoreStore.Archive(chats: [], contacts: [], node: "N0CALL Old")
        try JSONEncoder().encode(a).write(to: folder.appendingPathComponent("meshcore-aaaaaaaaaaaaaaaa.json"))
        let store = MeshCoreStore(link: MeshCoreLink(defaults: defaults), folder: folder, defaults: defaults)
        XCTAssertEqual(store.offlineName, "N0CALL Old", "saved before the last node was noted: the newest file")
    }

    // MARK: Blocks by name reach direct messages

    func testBlocklistMatchesDirectMessagesAndRoomPostsByName() {
        let list = Blocklist([BlockedSender(network: .meshcore, names: ["DEX Trail Node"])])
        XCTAssertTrue(list.hasNames(on: .meshcore))
        XCTAssertFalse(list.hasNames(on: .meshtastic))
        XCTAssertTrue(list.blocksMeshCore(contact: "660101010101", contactName: "dex trail node", channelLine: false, text: "hi"),
                      "a direct message from a contact blocked by name")
        XCTAssertFalse(list.blocksMeshCore(contact: "510101010101", contactName: "MAYA Field Unit", channelLine: false, text: "hi"))
        XCTAssertTrue(list.blocksMeshCore(contact: "3e0101010101", contactName: "Park Room Server", author: "66010101",
                                          authorName: "DEX Trail Node", channelLine: false, text: "hi"), "a room post by its author")
        let byKey = Blocklist([BlockedSender(network: .meshcore, key: "660101010101", names: [])])
        XCTAssertTrue(byKey.blocksMeshCore(contact: "3e0101010101", author: "66010101", channelLine: false, text: "hi"),
                      "a room post by its author's key prefix")
    }

    func testSafetyHidesANameBlockedSenderEverywhere() {
        let safety = Safety(defaults: defaults)
        let dexKey = Data([0x66] + Array(repeating: 1, count: 31))
        safety.meshcoreName = { $0 == dexKey.prefix(6) ? "DEX Trail Node" : nil }
        // Blocked from a channel line: only the name is known.
        safety.block(BlockedSender(network: .meshcore, names: ["DEX Trail Node"]))
        let dm = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .contact(dexKey.prefix(6)), text: "psst", at: Date())
        let line = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .channel(0), text: "DEX Trail Node: hey", at: Date())
        let other = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .contact(Data([0x51, 1, 1, 1, 1, 1])), text: "hi", at: Date())
        XCTAssertTrue(safety.hides(dm), "direct messages too, not just channel lines")
        XCTAssertTrue(safety.hides(line))
        XCTAssertFalse(safety.hides(other))
        XCTAssertTrue(safety.hides(meshcoreContact: dexKey.prefix(6)), "the whole thread")
    }

    func testStoreAndNotificationsSkipANameBlockedContactsDirectMessages() throws {
        let link = MeshCoreLink(defaults: defaults)
        let store = MeshCoreStore(link: link, folder: folder, defaults: defaults)
        let safety = Safety(defaults: defaults)
        store.safety = safety
        safety.meshcoreName = { [weak store] p in store?.source.contact(prefix: p)?.name }
        link.startDemo(timer: false)
        let maya = try XCTUnwrap(link.session.contacts.values.first { $0.name.hasPrefix("MAYA") })
        XCTAssertTrue(store.directs.contains(.contact(maya.prefix)))
        safety.block(BlockedSender(network: .meshcore, names: [maya.name]))
        XCTAssertFalse(store.directs.contains(.contact(maya.prefix)), "thread gone")
        XCTAssertFalse(store.visibleChats.contains { $0.direction == .received && $0.origin == .contact(maya.prefix) })
        XCTAssertFalse(store.visibleChats.contains { $0.channelSender == maya.name }, "channel lines gone")
        XCTAssertEqual(store.unread(.contact(maya.prefix)), 0, "never counted (so never notified)")
        link.disconnect()
    }

    // MARK: Set up key

    func testSetupKeyWordsAndLine() {
        func me(_ name: String, f: Double = 910.525) -> MeshCore.SelfInfo {
            // SelfInfo has no public init: start from the practice node's.
            var m = MeshCoreSession.demo().me!
            m.publicKey = Data([0xA1, 0xB2, 0xC3, 0xD4] + Array(repeating: 0, count: 28))
            m.frequency = f
            m.name = name
            return m
        }
        XCTAssertEqual(MeshCoreSetupCheck.keyWord(nil), "Node")
        XCTAssertNil(MeshCoreSetupCheck.line(me("N0CALL Trail")))
        XCTAssertEqual(MeshCoreSetupCheck.line(me("a1b2c3d4")), "Still has the firmware's default name")
        XCTAssertEqual(MeshCoreSetupCheck.line(me("N0CALL", f: 915)), "Radio matches no MeshCore preset")
        XCTAssertTrue(MeshCoreSetupCheck.needsSetup(me("NONAME", f: 915)))
        XCTAssertEqual(MeshCoreSetupCheck.keyWord(me("NONAME", f: 915)), "Setup!")
    }
}
