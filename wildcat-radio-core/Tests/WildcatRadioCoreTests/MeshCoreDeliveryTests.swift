import XCTest
@testable import WildcatRadioCore

/// Direct messages: wait for the confirmation as long as the firmware says (plus a
/// margin), send again with the next attempt number, flood after the second miss,
/// give up after `directAttempts`. The clock is whatever the test passes in.
final class MeshCoreDeliveryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    lazy var maya: MeshCore.Contact = {
        var c = MeshCore.Contact(publicKey: Data([0x51] + (1..<32).map { UInt8($0) }), kind: .chat, flags: 0, pathLength: 1,
                                 name: "MAYA Field Unit", lastAdvert: t0, position: nil, lastModified: nil)
        c.path = Data([0x1C])
        return c
    }()

    func session() -> MeshCoreSession {
        var s = MeshCoreSession()
        _ = s.handle(.contact(maya))
        return s
    }

    func at(_ secs: Double) -> Date { t0.addingTimeInterval(secs) }
    func send(_ attempt: Int) -> MeshCore.Command { .sendText(to: maya.prefix, text: "hi", at: t0, attempt: attempt) }
    func delivery(_ s: MeshCoreSession, _ id: UUID) -> MeshCoreSession.Chat.Delivery? { s.chats.first { $0.id == id }?.delivery }

    func testConfirmedFirstTime() {
        var s = session()
        let (id, cmds) = s.sendDirect("hi", to: maya, at: t0, now: t0)
        XCTAssertEqual(cmds, [send(0)])
        let a = s.answered(send(0), with: .sent(flood: false, ack: 0xA1, timeout: 5000), now: at(0.2))
        XCTAssertEqual(a.events, [.delivery(id: id, .sent(attempt: 0, flood: false))])
        XCTAssertEqual(s.chats.last?.ack, 0xA1, "the app's old `ack` still says it's on air")
        XCTAssertEqual(s.chats.last?.flood, false)

        let c = s.handle(.sendConfirmed(ack: 0xA1, roundTripMs: 1800), now: at(2))
        XCTAssertEqual(c.events, [.confirmed(ack: 0xA1, roundTripMs: 1800), .delivery(id: id, .delivered)])
        XCTAssertEqual(delivery(s, id), .delivered)
        XCTAssertEqual(s.chats.last?.confirmed, true)
        XCTAssertEqual(s.chats.last?.roundTripMs, 1800)
        XCTAssertEqual(s.pendingDirectCount, 0)
        XCTAssertTrue(s.tick(now: at(60)).follow.isEmpty, "nothing left to retry")
    }

    func testRetriesThenFloodsThenGivesUp() {
        var s = session()
        let (id, _) = s.sendDirect("hi", to: maya, at: t0, now: t0)
        _ = s.answered(send(0), with: .sent(flood: false, ack: 0xA1, timeout: 5000), now: t0)

        // The firmware's 5 s plus the margin: nothing before 7 s.
        XCTAssertTrue(s.tick(now: at(6.9)).follow.isEmpty)
        let r1 = s.tick(now: at(7))
        XCTAssertEqual(r1.follow, [send(1)], "same text and timestamp, next attempt")
        XCTAssertEqual(r1.events, [.delivery(id: id, .sending(attempt: 1))])

        _ = s.answered(send(1), with: .sent(flood: false, ack: 0xA2, timeout: 5000), now: at(8))
        XCTAssertEqual(delivery(s, id), .sent(attempt: 1, flood: false))
        XCTAssertEqual(s.chats.last?.ack, 0xA2)

        // Second miss: forget the route, so the third goes by flood.
        let r2 = s.tick(now: at(15))
        XCTAssertEqual(r2.follow, [.resetPath(publicKey: maya.publicKey), send(2)])
        _ = s.answered(send(2), with: .sent(flood: true, ack: 0xA3, timeout: 9000), now: at(16))
        XCTAssertEqual(delivery(s, id), .sent(attempt: 2, flood: true))

        XCTAssertTrue(s.tick(now: at(26.9)).events.isEmpty)
        let r3 = s.tick(now: at(27))
        XCTAssertEqual(MeshCoreSession.directAttempts, 3)
        XCTAssertTrue(r3.follow.isEmpty, "given up")
        XCTAssertEqual(r3.events, [.delivery(id: id, .failed(.noConfirmation(attempts: 3)))])
        XCTAssertEqual(MeshCoreSession.Chat.Failure.noConfirmation(attempts: 3).reason, "No confirmation after 3 tries")
        XCTAssertEqual(s.pendingDirectCount, 0)

        // A confirmation that turns up after all still counts.
        let late = s.handle(.sendConfirmed(ack: 0xA3, roundTripMs: 9000), now: at(30))
        XCTAssertEqual(late.events, [.confirmed(ack: 0xA3, roundTripMs: 9000), .delivery(id: id, .delivered)])
    }

    func testAnEarlierAttemptsAckConfirms() {
        var s = session()
        let (id, _) = s.sendDirect("hi", to: maya, at: t0, now: t0)
        _ = s.answered(send(0), with: .sent(flood: false, ack: 0xA1, timeout: 3000), now: t0)
        _ = s.tick(now: at(6))
        _ = s.answered(send(1), with: .sent(flood: false, ack: 0xA2, timeout: 3000), now: at(6))
        _ = s.handle(.sendConfirmed(ack: 0xA1, roundTripMs: 5500), now: at(6.5))
        XCTAssertEqual(delivery(s, id), .delivered)
        XCTAssertEqual(s.pendingDirectCount, 0)
        XCTAssertTrue(s.tick(now: at(60)).follow.isEmpty, "no third try")
    }

    func testNoResetWhenItAlreadyFlooded() {
        var s = session()
        _ = s.sendDirect("hi", to: maya, at: t0, now: t0)
        _ = s.answered(send(0), with: .sent(flood: true, ack: 1, timeout: 4000), now: t0)
        _ = s.tick(now: at(10))
        _ = s.answered(send(1), with: .sent(flood: true, ack: 2, timeout: 4000), now: at(10))
        XCTAssertEqual(s.tick(now: at(20)).follow, [send(2)], "no route to forget")
    }

    func testNodeThatNeverAnswers() {
        var s = session()
        let (id, _) = s.sendDirect("hi", to: maya, at: t0, now: t0)
        XCTAssertTrue(s.tick(now: at(29)).follow.isEmpty, "it may be waiting behind other commands")
        XCTAssertEqual(s.tick(now: at(30)).follow, [send(1)])
        XCTAssertEqual(s.tick(now: at(60)).follow, [send(2)], "never on air: no path reset")
        XCTAssertEqual(s.tick(now: at(90)).events, [.delivery(id: id, .failed(.nodeDidNotAnswer))])
    }

    func testUnknownContactIsAddedOnceThenRejected() {
        var s = session()
        let (id, _) = s.sendDirect("hi", to: maya, at: t0, now: t0)
        let first = s.answered(send(0), with: .error(code: 2), now: at(1))
        XCTAssertEqual(first.follow, [.addContact(maya), send(0)], "the node lost her: add and resend")
        XCTAssertFalse(s.isOnNode(maya))
        _ = s.answered(.addContact(maya), with: .ok, now: at(1))
        let second = s.answered(send(0), with: .error(code: 2), now: at(2))
        XCTAssertTrue(second.follow.isEmpty)
        XCTAssertEqual(second.events, [.delivery(id: id, .failed(.rejected(code: 2)))])
        XCTAssertEqual(MeshCoreSession.Chat.Failure.rejected(code: 2).reason, "Your node doesn't know this contact")
    }

    func testQueueFullFailsAtOnce() {
        var s = session()
        let (id, _) = s.sendDirect("hi", to: maya, at: t0, now: t0)
        XCTAssertEqual(s.answered(send(0), with: .error(code: 3), now: t0).events, [.delivery(id: id, .failed(.rejected(code: 3)))])
    }

    func testAnswersToOtherSendsAreIgnored() {
        var s = session()
        let (id, _) = s.sendDirect("hi", to: maya, at: t0, now: t0)
        let other = MeshCore.Command.sendText(to: maya.prefix, text: "something else", at: t0, attempt: 0)
        XCTAssertTrue(s.answered(other, with: .sent(flood: false, ack: 9, timeout: 1000), now: t0).events.isEmpty)
        XCTAssertTrue(s.answered(.login(publicKey: maya.publicKey, password: "x"), with: .sent(flood: false, ack: 9, timeout: 1000)).events.isEmpty)
        XCTAssertEqual(delivery(s, id), .sending(attempt: 0))
        XCTAssertNil(s.chats.last?.ack)
    }

    func testZeroTimeoutUsesTheDefault() {
        var s = session()
        _ = s.sendDirect("hi", to: maya, at: t0, now: t0)
        _ = s.answered(send(0), with: .sent(flood: false, ack: 1, timeout: 0), now: t0)
        XCTAssertTrue(s.tick(now: at(13.9)).follow.isEmpty)
        XCTAssertEqual(s.tick(now: at(14)).follow, [send(1)])
    }

    /// Chats sent the 1.0 way (no delivery) keep working as before.
    func testOldStyleAckStillConfirms() {
        var s = session()
        let id = s.sent("hi", to: .contact(maya.prefix), at: t0)
        s.attachAck(7, to: id)
        XCTAssertEqual(s.handle(.sendConfirmed(ack: 7, roundTripMs: 100)).events, [.confirmed(ack: 7, roundTripMs: 100)])
        XCTAssertEqual(s.chats.last?.confirmed, true)
        XCTAssertNil(s.chats.last?.delivery)
    }
}
