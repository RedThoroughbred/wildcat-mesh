import XCTest
import WildcatRadioCore
@testable import WildcatGames

@MainActor
final class MessageStoreTests: XCTestCase {
    private var radio: Radio!
    private var store: MessageStore!
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("msgs-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: "msgs-\(UUID())"))
        radio = Radio()
        radio.startPractice()
        store = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
    }

    override func tearDown() async throws {
        radio.stopPractice()
        try? FileManager.default.removeItem(at: dir)
    }

    private func routing(_ req: UInt32, from: NodeNum, _ err: RoutingError) -> MeshSession.Event {
        var p = MeshPacket(from: from, to: PracticeMesh.me, id: 1, portnum: .routing)
        p.requestID = req
        p.routingError = err
        return .packet(p)
    }

    func testSendThenAckStates() throws {
        XCTAssertTrue(store.send("hello", in: .channel(slot: 1, name: "WGHUNT")))
        let m = try XCTUnwrap(store.messages.last)
        XCTAssertEqual(m.status, .sending)
        store.handle(routing(m.packetID, from: PracticeMesh.me, .none))
        XCTAssertEqual(store.messages.last?.status, .sent, "our own node: a neighbour repeated it")
        store.handle(routing(m.packetID, from: PracticeMesh.fox, .none))
        XCTAssertEqual(store.messages.last?.status, .delivered)
        XCTAssertEqual(store.deliveredCount, 1, "only the other node's ack counts as delivered")
        store.handle(routing(m.packetID, from: PracticeMesh.fox, .none))
        XCTAssertEqual(store.deliveredCount, 1, "a repeated ack counts once")
        XCTAssertTrue(store.send("again", in: .direct(PracticeMesh.fox.id)))
        let m2 = try XCTUnwrap(store.messages.last)
        store.handle(routing(m2.packetID, from: PracticeMesh.me, .maxRetransmit))
        XCTAssertEqual(store.messages.last?.status, .failed("Nobody acknowledged it"))
    }

    func testPracticeDeliveriesDoNotCount() throws {
        let practice = MessageStore(radio: radio, folder: dir, defaults: defaults)
        XCTAssertTrue(practice.send("hello", in: .direct(PracticeMesh.fox.id)))
        let m = try XCTUnwrap(practice.messages.last)
        practice.handle(routing(m.packetID, from: PracticeMesh.fox, .none))
        XCTAssertEqual(practice.messages.last?.status, .delivered)
        XCTAssertEqual(practice.deliveredCount, 0, "no rating prompt from the practice radio")
    }

    func testIncomingThreadsRepliesAndReactions() {
        let chan = MeshPacket(from: PracticeMesh.fox, to: .broadcast, channel: 1, id: 50, portnum: .text, text: "anyone out?")
        store.handle(.packet(chan))
        store.handle(.packet(chan))
        XCTAssertEqual(store.messages(in: .channel(slot: 1, name: "WGHUNT")).count, 1, "duplicates dropped")
        XCTAssertEqual(store.unread(in: .channel(slot: 1, name: "WGHUNT")), 1)
        var dm = MeshPacket(from: PracticeMesh.den, to: PracticeMesh.me, id: 51, portnum: .text, text: "hi you")
        dm.replyID = 50
        store.handle(.packet(dm))
        XCTAssertEqual(store.directThreads, [PracticeMesh.den.id])
        XCTAssertEqual(store.messages(in: .direct(PracticeMesh.den.id)).first?.replyTo, 50)
        var tap = MeshPacket(from: PracticeMesh.den, to: .broadcast, channel: 1, id: 52, portnum: .text, text: "👍")
        tap.replyID = 50
        tap.isReaction = true
        store.handle(.packet(tap))
        XCTAssertEqual(store.messages(in: .channel(slot: 1, name: "WGHUNT")).first?.reactions["👍"], [PracticeMesh.den.id])
        store.markRead(.channel(slot: 1, name: "WGHUNT"))
        XCTAssertEqual(store.unread(in: .channel(slot: 1, name: "WGHUNT")), 0)
    }

    func testRefereeTrafficIsNotAChat() {
        let wg = MeshPacket(from: PracticeMesh.den, to: PracticeMesh.me, id: 60, portnum: .text, text: "WG W FOX7 COLDER -82>-88 BEST -47")
        store.handle(.packet(wg))
        XCTAssertTrue(store.messages(in: .direct(PracticeMesh.den.id)).isEmpty)
        XCTAssertEqual(store.unread(in: .direct(PracticeMesh.den.id)), 0)
    }

    func testRetryReplacesAFailedSend() throws {
        XCTAssertTrue(store.send("anyone?", in: .channel(slot: 1, name: "WGHUNT")))
        let m = try XCTUnwrap(store.messages.last)
        XCTAssertFalse(store.retry(m), "only failed sends retry")
        store.handle(routing(m.packetID, from: PracticeMesh.me, .maxRetransmit))
        let failed = try XCTUnwrap(store.messages.last)
        XCTAssertTrue(store.retry(failed))
        XCTAssertEqual(store.messages(in: .channel(slot: 1, name: "WGHUNT")).map(\.text), ["anyone?"], "the failed copy goes")
        XCTAssertEqual(store.messages.last?.status, .sending)
        XCTAssertNotEqual(store.messages.last?.id, failed.id)
    }

    func testPersistsAndFailsStaleSends() throws {
        XCTAssertTrue(store.send("pending", in: .channel(slot: 0)))
        store.save()
        let again = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
        XCTAssertEqual(again.messages.last?.text, "pending")
        XCTAssertEqual(again.messages.last?.status, .failed("No answer"))
    }
}
