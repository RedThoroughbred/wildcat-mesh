import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// Save files, queues and limits that keep a long session (or a hostile mesh) from hurting the app.
@MainActor
final class RobustnessTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("robust-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func setAside(_ name: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(name + ".bad-") }
    }

    // MARK: Save files

    func testUnreadableMessagesAreSetAsideNotOverwritten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "robust-\(UUID())"))
        let radio = Radio()
        radio.startPractice()
        defer { radio.stopPractice() }
        // The practice node's own history file, unreadable.
        let file = dir.appendingPathComponent(MeshtasticHistory.fileName(node: PracticeMesh.me.id))
        try Data("{ not json".utf8).write(to: file)
        let store = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
        XCTAssertTrue(store.messages.isEmpty)
        let bad = try setAside(file.lastPathComponent)
        XCTAssertEqual(bad.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(bad[0])), Data("{ not json".utf8), "kept as it was")
        XCTAssertTrue(store.send("fresh start", in: .channel(slot: 0)))
        store.save()
        XCTAssertEqual(MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true).messages.last?.text, "fresh start")

        // The old single file, unreadable: set aside too, and nothing is migrated from it.
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("messages.json"))
        _ = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
        XCTAssertEqual(try setAside("messages.json").count, 1)
    }

    func testOldMessagesWithoutDefaultedFieldsLoad() throws {
        let file = dir.appendingPathComponent("messages.json")
        // Saved before id, reactions, viaMQTT, lastRead and the radio existed.
        let old = #"{"messages":[{"packetID":7,"from":"!0000abcd","conversation":{"channel":{"_0":1}},"text":"old one","time":700000000,"outgoing":false,"status":{"received":{}}}]}"#
        try Data(old.utf8).write(to: file)
        let radio = Radio()
        let store = MessageStore(radio: radio, folder: dir, defaults: try XCTUnwrap(UserDefaults(suiteName: "robust-\(UUID())")))
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "old one")
        XCTAssertEqual(store.messages.first?.reactions, [:])
        XCTAssertEqual(store.messages.first?.viaMQTT, false)
        XCTAssertEqual(store.messages.first?.conversation, .channel(slot: 1), "a slot key until a radio says which channel sits there")
        XCTAssertTrue(try setAside("messages.json").isEmpty)
        XCTAssertEqual(store.historyNode, MeshtasticHistory.unknownNode, "no radio recorded anywhere: kept as an earlier radio's")
        XCTAssertEqual(store.historyLabel, "earlier radio")
    }

    func testUnreadableGiftsAreSetAside() throws {
        let file = dir.appendingPathComponent("gifts.json")
        try Data([0xFF, 0x00, 0x01]).write(to: file)
        let gifts = GiftStore(radio: Radio(), file: file)
        XCTAssertTrue(gifts.received.isEmpty)
        XCTAssertEqual(try setAside("gifts.json").count, 1)
    }

    func testOldGiftsFileWithoutSentLoads() throws {
        let file = dir.appendingPathComponent("gifts.json")
        let old = #"{"received":[{"id":5,"payload":"AA==","received":700000000}]}"#
        try Data(old.utf8).write(to: file)
        let gifts = GiftStore(radio: Radio(), file: file)
        XCTAssertEqual(gifts.received.first?.id, 5)
        XCTAssertTrue(gifts.sent.isEmpty)
    }

    func testMeshCoreArchiveToleratesMissingLists() throws {
        let a = try JSONDecoder().decode(MeshCoreStore.Archive.self, from: Data(#"{"chats":[]}"#.utf8))
        XCTAssertTrue(a.contacts.isEmpty)
    }

    func testSavedContactsKeepTheMostRecentlyHeard() {
        let contacts = (0..<600).map { i in
            MeshCore.Contact(publicKey: Data([UInt8(i % 256), UInt8(i / 256)] + Array(repeating: 0, count: 30)), kind: .chat, flags: 0,
                             pathLength: nil, name: "N\(i)", lastAdvert: Date(timeIntervalSince1970: TimeInterval(i)),
                             position: nil, lastModified: nil)
        }
        let kept = MeshCoreStore.pruned(contacts)
        XCTAssertEqual(kept.count, MeshCoreStore.keepContacts)
        XCTAssertTrue(kept.contains { $0.name == "N599" })
        XCTAssertFalse(kept.contains { $0.name == "N0" })
    }

    // MARK: Gifts

    func testReceivedGiftsCapDropsOldestOpenedFirst() {
        var list: [GiftStore.Received] = (0..<101).map { i in
            GiftStore.Received(id: UInt32(i), payload: Data(), received: Date(timeIntervalSince1970: TimeInterval(1000 - i)))
        }
        list[50].opened = Date()   // newest first: 50 is older than 0-49
        list[99].opened = Date()
        let capped = GiftStore.capped(list)
        XCTAssertEqual(capped.count, 100)
        XCTAssertFalse(capped.contains { $0.id == 99 }, "oldest opened one goes first")
        XCTAssertTrue(capped.contains { $0.id == 100 }, "a locked gift stays while opened ones can go")
        let allLocked = GiftStore.capped(Array(repeating: GiftStore.Received(id: 1, payload: Data(), received: Date()), count: 105))
        XCTAssertEqual(allLocked.count, 100)
    }

    // MARK: Bridge

    func testBridgeFollowsTheSavedChannelByName() {
        let chans: [(index: Int, name: String)] = [(0, "Public"), (1, "WGBRIDGE"), (2, "Camp")]
        XCTAssertEqual(MeshBridge.resolve(name: "WGBRIDGE", hint: 1, in: chans), 1)
        XCTAssertEqual(MeshBridge.resolve(name: "WGBRIDGE", hint: 2, in: chans), 1, "slot moved: follow the name")
        XCTAssertNil(MeshBridge.resolve(name: "WGBRIDGE", hint: 1, in: [(0, "Public"), (1, "Other")]), "gone: no silent swap")
        XCTAssertNil(MeshBridge.resolve(name: "X", hint: nil, in: [(1, "X"), (2, "X")]), "ambiguous")
        XCTAssertEqual(MeshBridge.resolve(name: nil, hint: 2, in: chans), 2, "saved before names were kept")
        XCTAssertNil(MeshBridge.resolve(name: nil, hint: 5, in: chans))
    }

    // MARK: Referee

    func testRefereeQueueLimits() {
        let a = NodeNum(0x11), b = NodeNum(0x22)
        var q: [FoxReferee.Say] = []
        for i in 0..<10 { PhoneReferee.admit(FoxReferee.Say(to: a, text: "a\(i)", channel: nil), to: &q) }
        XCTAssertEqual(q.count, PhoneReferee.maxPerNode, "one chatty hunter can't fill the queue")
        for i in 0..<30 { PhoneReferee.admit(FoxReferee.Say(to: .broadcast, text: "b\(i)", channel: nil), to: &q) }
        XCTAssertEqual(q.count, PhoneReferee.maxQueue)
        XCTAssertEqual(q.last?.text, "b29", "oldest dropped")
        PhoneReferee.admit(FoxReferee.Say(to: b, text: "b", channel: nil), to: &q)
        XCTAssertEqual(q.last?.to, b)
    }

    func testRefereeCooldownPerHunter() {
        let a = NodeNum(0x11), b = NodeNum(0x22), now = Date()
        let q = [FoxReferee.Say(to: a, text: "1", channel: nil), FoxReferee.Say(to: b, text: "2", channel: nil)]
        XCTAssertEqual(PhoneReferee.next(in: q, lastSentTo: [:], now: now).index, 0)
        XCTAssertEqual(PhoneReferee.next(in: q, lastSentTo: [a: now.addingTimeInterval(-1)], now: now).index, 1, "a waits, b goes")
        let both = PhoneReferee.next(in: q, lastSentTo: [a: now.addingTimeInterval(-1), b: now.addingTimeInterval(-2)], now: now)
        XCTAssertNil(both.index)
        XCTAssertEqual(both.wait, 1, accuracy: 0.01)
        XCTAssertEqual(PhoneReferee.next(in: q, lastSentTo: [a: now.addingTimeInterval(-3)], now: now).index, 0)
    }

    // MARK: Widget

    func testWidgetIgnoresLastHeardAndThrottles() {
        let node = WildcatSnapshot.Node(name: "N", badge: "N", connected: true, heard: 1, lastHeard: Date(), batteryVolts: nil)
        var a = WildcatSnapshot(updated: Date(), meshtastic: node, meshcore: nil, bridgeOn: false, bridged: 0,
                                bridgeChannels: nil, unreadMeshtastic: 0, unreadMeshCore: 0, recent: [])
        var b = a
        b.updated = Date().addingTimeInterval(9)
        b.meshtastic?.lastHeard = Date().addingTimeInterval(9)
        XCTAssertEqual(SnapshotWriter.shown(a), SnapshotWriter.shown(b), "a packet alone isn't a change")
        a.unreadMeshtastic = 1
        XCTAssertNotEqual(SnapshotWriter.shown(a), SnapshotWriter.shown(b))
        let now = Date()
        XCTAssertEqual(SnapshotWriter.reloadDelay(lastReload: nil, now: now, foreground: true), 0)
        XCTAssertEqual(SnapshotWriter.reloadDelay(lastReload: now.addingTimeInterval(-20), now: now, foreground: true), 40, accuracy: 0.01)
        XCTAssertEqual(SnapshotWriter.reloadDelay(lastReload: now.addingTimeInterval(-120), now: now, foreground: false), 780, accuracy: 0.01)
    }

    // MARK: Debug log

    func testDebugLogRollsOverPastItsLimit() throws {
        let file = dir.appendingPathComponent("log.txt"), old = dir.appendingPathComponent("log.1.txt")
        let chunk = Data(repeating: 0x41, count: 600)
        DebugLog.write(chunk, to: file, rollingTo: old, limit: 1000)
        DebugLog.write(chunk, to: file, rollingTo: old, limit: 1000)
        XCTAssertEqual(try Data(contentsOf: file).count, 600)
        XCTAssertEqual(try Data(contentsOf: old).count, 600)
    }
}
