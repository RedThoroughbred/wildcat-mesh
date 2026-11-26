import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// Practice chat (what App Review and screenshots see): a made-up history on LongFast
/// and a DM, acknowledgements and replies, and none of it in the real save file.
@MainActor
final class PracticeChatTests: XCTestCase {
    private var radio: Radio!
    private var store: MessageStore!
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("msgs-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: "msgs-\(UUID())"))
        radio = Radio()
        store = MessageStore(radio: radio, folder: dir, defaults: defaults)
        radio.startPractice()
    }

    override func tearDown() async throws {
        radio.stopPractice()
        try? FileManager.default.removeItem(at: dir)
    }

    func testHistoryHasLongFastLinesAndADirectMessage() throws {
        let primary = store.messages(in: .channel(slot: 0))
        XCTAssertGreaterThanOrEqual(primary.count, 4)
        let received = primary.filter { !$0.outgoing }
        XCTAssertGreaterThanOrEqual(Set(received.map(\.from)).count, 3, "several people")
        for m in received {
            XCTAssertNotNil(m.snr)
            XCTAssertNotNil(m.rssi)
            XCTAssertNotNil(m.hopStart)
            XCTAssertEqual(m.hops, (m.hopStart ?? 0) - (m.hopLimit ?? 0))
            XCTAssertNotNil(m.relayNode)
            XCTAssertNotNil(m.airtimeMs)
        }
        let dm = store.messages(in: .direct(PracticeMesh.maya.id))
        XCTAssertTrue(dm.contains { !$0.outgoing })
        let mine = try XCTUnwrap(dm.first { $0.outgoing })
        XCTAssertEqual(mine.status, .delivered)
        XCTAssertNotNil(mine.roundTripMs)
        XCTAssertEqual(store.directThreads, [PracticeMesh.maya.id])
        XCTAssertFalse(store.messages.contains { $0.text.hasPrefix("WG ") })
        XCTAssertTrue(store.messages.allSatisfy(\.practice))
    }

    func testPracticeIsNeverSavedAndGoesWhenPracticeEnds() throws {
        XCTAssertTrue(store.send("hello park", in: .channel(slot: 0)))
        XCTAssertEqual(store.messages.last?.practice, true)
        store.save()
        let saved = MessageStore(radio: Radio(), folder: dir, defaults: defaults)
        XCTAssertTrue(saved.messages.isEmpty, "nothing from practice reaches the file")
        XCTAssertNil(saved.historyNode, "the practice mesh leaves no history file behind")
        XCTAssertEqual(store.historyNode, PracticeMesh.me.id, "practice chats live under the practice node, apart from real radios")

        radio.stopPractice()
        XCTAssertTrue(store.messages.isEmpty)
        radio.startPractice()
        radio.startPractice()
        XCTAssertEqual(store.messages.count, PracticeMesh.history().count, "a second start doesn't double the history")
    }

    func testDirectMessageIsDeliveredWithRoundTrip() async throws {
        XCTAssertTrue(store.send("see you there", in: .direct(PracticeMesh.maya.id)))
        let id = try XCTUnwrap(store.messages.last?.id)
        for _ in 0..<40 where store.messages.first(where: { $0.id == id })?.status != .delivered {
            try await Task.sleep(for: .milliseconds(100))
        }
        let m = try XCTUnwrap(store.messages.first { $0.id == id })
        XCTAssertEqual(m.status, .delivered)
        XCTAssertNotNil(m.roundTripMs)
    }

    func testReplies() {
        XCTAssertEqual(PracticeMesh.reply(to: PracticeMesh.maya, channel: 0, turn: 0)?.from, PracticeMesh.maya, "a DM is answered by its recipient")
        XCTAssertNotNil(PracticeMesh.reply(to: .broadcast, channel: 0, turn: 3))
        XCTAssertNil(PracticeMesh.reply(to: .broadcast, channel: PracticeMesh.huntChannel, turn: 0), "the hunt channel stays for the Den")
        XCTAssertNil(PracticeMesh.reply(to: PracticeMesh.den, channel: 0, turn: 0))
    }

    func testPracticeChatsStayShort() {
        for k in 0..<30 { store.send("line \(k)", in: .channel(slot: 0)) }
        XCTAssertEqual(store.messages(in: .channel(slot: 0)).count, PracticeMesh.keepPerChat)
        XCTAssertEqual(store.messages(in: .channel(slot: 0)).last?.text, "line 29")
    }
}
