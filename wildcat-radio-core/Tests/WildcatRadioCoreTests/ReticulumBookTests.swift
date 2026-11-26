import XCTest
@testable import WildcatRadioCore

/// What Wildcat keeps of Reticulum messaging, and the bridge's events. Saved files from an older
/// build must load in a newer one; nothing a stranger sends may trap.
final class ReticulumBookTests: XCTestCase {
    private let maya = String(repeating: "a1", count: 16)
    private let sam = String(repeating: "b2", count: 16)
    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    // MARK: Saved data

    func testAnOldBookLoads() throws {
        // The least a file can hold: fields added later all have defaults.
        let old = #"{"contacts":[{"hash":"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"}],"messages":[{"id":"m1","peer":"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"}]}"#
        let book = try JSONDecoder().decode(Reticulum.Book.self, from: Data(old.utf8))
        XCTAssertEqual(book.contacts.first?.announces, 0)
        XCTAssertNil(book.contacts.first?.name)
        XCTAssertEqual(book.messages.first?.delivery, .failed)
        XCTAssertEqual(book.messages.first?.read, true)
        XCTAssertEqual(try JSONDecoder().decode(Reticulum.Book.self, from: Data("{}".utf8)), Reticulum.Book())
    }

    func testValuesFromANewerBuildDontBreakTheFile() throws {
        let newer = #"{"messages":[{"id":"m1","peer":"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1","delivery":"teleported","failure":"gremlins","trust":"notarised","later":1}]}"#
        let m = try XCTUnwrap(JSONDecoder().decode(Reticulum.Book.self, from: Data(newer.utf8)).messages.first)
        XCTAssertEqual(m.delivery, .failed)
        XCTAssertEqual(m.failure, .noAnswer)
        XCTAssertEqual(m.trust, .unknownSender)
    }

    func testBookRoundTrips() throws {
        var book = Reticulum.Book()
        book.heard(hash: maya, name: "MAYA", hops: 1, stampCost: 8, at: t(0))
        book.add(.init(id: "m1", incoming: false, peer: maya, text: "hi", at: t(1), delivery: .queued))
        book.add(.init(id: "h1", incoming: true, peer: maya, text: "yo", at: t(2), delivery: .received, trust: .verified, read: false))
        book.update(id: "m1", delivery: .failed, failure: .noPath)
        let back = try JSONDecoder().decode(Reticulum.Book.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(back, book)
    }

    // MARK: People heard

    func testHeardKeepsNamesCountsAndOrder() {
        var book = Reticulum.Book()
        book.heard(hash: maya, name: "MAYA", hops: 1, stampCost: nil, at: t(0))
        book.heard(hash: sam, name: "  ", hops: 3, stampCost: 8, at: t(5))
        book.heard(hash: maya, name: nil, hops: 2, stampCost: nil, at: t(9))
        XCTAssertEqual(book.contacts.count, 2)
        XCTAssertEqual(book.contact(maya)?.name, "MAYA", "a nameless announce keeps the name")
        XCTAssertEqual(book.contact(maya)?.announces, 2)
        XCTAssertEqual(book.contact(maya)?.hops, 2)
        XCTAssertEqual(book.contact(maya)?.firstHeard, t(0))
        XCTAssertEqual(book.contact(sam)?.title, "b2b2b2b2…b2b2", "no name: the short address")
        XCTAssertEqual(book.contact(sam)?.needsStamp, true)
        XCTAssertEqual(book.heardRecently.map(\.hash), [maya, sam])
        book.heard(hash: "not an address", name: "X", hops: nil, stampCost: nil, at: t(10))
        XCTAssertEqual(book.contacts.count, 2)
        book.heard(hash: sam, name: String(repeating: "N", count: 500), hops: nil, stampCost: nil, at: t(11))
        XCTAssertEqual(book.contact(sam)?.name?.count, 64, "a stranger's name is cut")
    }

    func testContactsAreCappedButNeverThoseWithAConversation() {
        var book = Reticulum.Book()
        book.heard(hash: maya, name: "MAYA", hops: 1, stampCost: nil, at: t(0))
        book.add(.init(id: "m1", incoming: false, peer: maya, text: "hi", at: t(1), delivery: .delivered))
        for i in 0..<(Reticulum.Book.contactLimit + 20) {
            book.heard(hash: String(format: "%032x", i + 1), name: nil, hops: nil, stampCost: nil, at: t(Double(10 + i)))
        }
        XCTAssertEqual(book.contacts.count, Reticulum.Book.contactLimit)
        XCTAssertNotNil(book.contact(maya), "the oldest, but there is a conversation with her")
        XCTAssertNil(book.contact(String(format: "%032x", 1)))
    }

    // MARK: Messages

    func testMessagesDedupeAndDropWhatMustNotBeKept() {
        var book = Reticulum.Book()
        let m = Reticulum.Message(id: "h1", incoming: true, peer: maya, text: "yo", at: t(1), delivery: .received, trust: .verified, read: false)
        XCTAssertTrue(book.add(m))
        XCTAssertFalse(book.add(m), "the same LXMF hash again")
        var forged = m
        forged.id = "h2"
        forged.trust = .badSignature
        XCTAssertFalse(book.add(forged), "a bad signature is never kept")
        var odd = m
        odd.id = "h3"
        odd.peer = "<script>"
        XCTAssertFalse(book.add(odd))
        var long = m
        long.id = "h4"
        long.text = String(repeating: "x", count: 50_000)
        XCTAssertTrue(book.add(long))
        XCTAssertEqual(book.messages.last?.text.count, Reticulum.Book.textLimit + 1)
        for i in 0..<(Reticulum.Book.messageLimit + 5) {
            book.add(.init(id: "n\(i)", incoming: true, peer: sam, text: "", at: t(Double(i)), delivery: .received))
        }
        XCTAssertEqual(book.messages.count, Reticulum.Book.messageLimit)
    }

    func testDeliveryMovesForwardOnly() {
        var book = Reticulum.Book()
        book.add(.init(id: "m1", incoming: false, peer: maya, text: "hi", at: t(1), delivery: .queued))
        book.update(id: "m1", delivery: .findingPath)
        book.update(id: "m1", delivery: .sending)
        book.update(id: "m1", delivery: .delivered)
        book.update(id: "m1", delivery: .sending)
        XCTAssertEqual(book.messages[0].delivery, .delivered, "a late 'sending' changes nothing")
        book.add(.init(id: "m2", incoming: false, peer: maya, text: "hi", at: t(2), delivery: .queued))
        book.update(id: "m2", delivery: .failed, failure: .noPath)
        XCTAssertEqual(book.messages[1].failure, .noPath)
        book.update(id: "m2", delivery: .delivered)
        XCTAssertEqual(book.messages[1].delivery, .delivered, "a proof always counts")
        XCTAssertNil(book.messages[1].failure)
        book.update(id: "nobody", delivery: .delivered)
        book.add(.init(id: "m3", incoming: false, peer: maya, text: "", at: t(3), delivery: .queued))
        book.update(id: "m3", delivery: .failed)
        XCTAssertEqual(book.messages[2].failure, .noAnswer, "a failure always has a reason to show")
    }

    func testStoppingInterruptsWhatWasOnItsWay() {
        var book = Reticulum.Book()
        book.add(.init(id: "a", incoming: false, peer: maya, text: "", at: t(1), delivery: .sending))
        book.add(.init(id: "b", incoming: false, peer: maya, text: "", at: t(2), delivery: .delivered))
        book.add(.init(id: "c", incoming: false, peer: maya, text: "", at: t(3), delivery: .sent))
        book.add(.init(id: "d", incoming: true, peer: maya, text: "", at: t(4), delivery: .received))
        book.interrupt()
        XCTAssertEqual(book.messages.map(\.delivery), [.failed, .delivered, .sent, .received])
        XCTAssertEqual(book.messages[0].failure, .interrupted)
    }

    func testConversationsUnreadAndRemoval() {
        var book = Reticulum.Book()
        book.heard(hash: maya, name: "MAYA", hops: 1, stampCost: nil, at: t(0))
        book.add(.init(id: "1", incoming: true, peer: maya, text: "one", at: t(1), delivery: .received, read: false))
        book.add(.init(id: "2", incoming: true, peer: sam, text: "two", at: t(2), delivery: .received, read: false))
        book.add(.init(id: "3", incoming: true, peer: maya, text: "three", at: t(3), delivery: .received, read: false))
        let c = book.conversations
        XCTAssertEqual(c.map(\.peer), [maya, sam], "the latest first")
        XCTAssertEqual(c[0].title, "MAYA")
        XCTAssertEqual(c[0].last.text, "three")
        XCTAssertEqual(c[0].unread, 2)
        XCTAssertEqual(c[1].title, "b2b2b2b2…b2b2")
        XCTAssertEqual(book.unread, 3)
        book.markRead(peer: maya)
        XCTAssertEqual(book.unread, 1)
        XCTAssertEqual(book.thread(with: maya).map(\.id), ["1", "3"])
        book.removeConversation(with: maya)
        XCTAssertEqual(book.conversations.map(\.peer), [sam])
        book.forget(contact: maya)
        XCTAssertNil(book.contact(maya))
    }

    func testWordsForStatesAndFailures() {
        XCTAssertEqual(Reticulum.Delivery(bridge: "outbound"), .sending)
        XCTAssertEqual(Reticulum.Delivery(bridge: "path"), .findingPath)
        XCTAssertEqual(Reticulum.Delivery(bridge: "rejected"), .failed)
        XCTAssertEqual(Reticulum.Delivery(bridge: "state 99"), .failed)
        XCTAssertEqual(Reticulum.Failure(bridge: "no_path"), .noPath)
        XCTAssertEqual(Reticulum.Failure(bridge: "stamp"), .needsStamp)
        XCTAssertNil(Reticulum.Failure(bridge: nil))
        XCTAssertTrue(Reticulum.Failure.noPath.line.contains("announce"))
        XCTAssertTrue(Reticulum.Failure.needsStamp.line.contains("stamp"))
        XCTAssertNil(Reticulum.Trust.verified.note)
        XCTAssertEqual(Reticulum.Trust(validated: false, reason: "source unknown"), .unknownSender)
        XCTAssertEqual(Reticulum.Trust(validated: false, reason: "signature invalid"), .badSignature)
        XCTAssertEqual(Reticulum.Trust(validated: false, reason: nil), .unknownSender)
    }

    // MARK: The bridge's events

    func testDecodesEveryEvent() {
        typealias E = Reticulum.Event
        XCTAssertEqual(E.decode(#"{"event": "ready", "python": "3.13.16"}"#), .ready(python: "3.13.16"))
        let key = String(repeating: "ab", count: 64)
        XCTAssertEqual(E.decode(#"{"event": "identity", "private_key": "\#(key)", "identity_hash": "ebf8"}"#),
                       .identity(privateKey: Data(repeating: 0xAB, count: 64), identityHash: "ebf8"))
        XCTAssertEqual(E.decode(#"{"event": "identity", "private_key": "abcd"}"#), .error("identity event without a 64-byte key"))
        let started = E.decode(#"{"event": "started", "address": "221b", "identity_hash": "ebf8", "rns": "1.5.7", "lxmf": "1.2.0", "crypto": "openssl", "python": "3.13.16", "timings_ms": {"reticulum": 105, "lxmf": 4}, "rnode": {"frequency": 914875000, "bandwidth": 125000, "txpower": 7, "spreadingfactor": 8, "codingrate": 5}}"#)
        guard case .started(let s)? = started else { return XCTFail("started") }
        XCTAssertEqual(s.versions, "RNS 1.5.7 · LXMF 1.2.0 · Python 3.13.16 · openssl")
        XCTAssertEqual(s.reticulumMs, 105)
        XCTAssertEqual(s.radio?.line, "914.875 MHz · 125 kHz · SF8 · CR 4/5 · 7 dBm")
        XCTAssertEqual(E.decode(#"{"event": "interfaces", "list": [{"name": "WildcatRNodeInterface[RNode over Bluetooth]", "online": true, "rxb": 10, "txb": 20}]}"#),
                       .interfaces([.init(name: "WildcatRNodeInterface[RNode over Bluetooth]", online: true, rxBytes: 10, txBytes: 20)]))
        XCTAssertEqual(E.decode(#"{"event": "announce", "hash": "\#(maya)", "name": "MAYA", "hops": 2, "stamp_cost": 8, "at": 1800000000}"#),
                       .announce(.init(hash: maya, name: "MAYA", hops: 2, stampCost: 8, at: t(0))))
        XCTAssertEqual(E.decode(#"{"event": "message", "direction": "out", "id": "m1", "to": "\#(maya)", "text": "hi", "state": "queued", "at": 1800000001}"#),
                       .message(.init(id: "m1", incoming: false, peer: maya, text: "hi", at: t(1), delivery: .queued)))
        XCTAssertEqual(E.decode(#"{"event": "message", "direction": "in", "hash": "h1", "from": "\#(maya)", "text": "yo", "signature_validated": true, "at": 1800000002}"#),
                       .message(.init(id: "h1", incoming: true, peer: maya, text: "yo", at: t(2), delivery: .received, trust: .verified, read: false)))
        XCTAssertEqual(E.decode(#"{"event": "message_state", "id": "m1", "state": "delivered"}"#),
                       .messageState(id: "m1", delivery: .delivered, failure: nil, detail: nil))
        XCTAssertEqual(E.decode(#"{"event": "message_state", "id": "m1", "state": "failed", "reason": "no_path", "detail": "x"}"#),
                       .messageState(id: "m1", delivery: .failed, failure: .noPath, detail: "x"))
        XCTAssertEqual(E.decode(#"{"event": "message_state", "id": "m1", "state": "rejected"}"#),
                       .messageState(id: "m1", delivery: .failed, failure: .rejected, detail: nil))
        XCTAssertEqual(E.decode(#"{"event": "stopped", "state": "stopped"}"#), .stopped)
        XCTAssertEqual(E.decode(#"{"event": "error", "message": "boom"}"#), .error("boom"))
        XCTAssertEqual(E.decode(#"{"event": "python_exited", "code": 3}"#), .pythonExited(3))
        XCTAssertEqual(E.decode(#"{"event": "log", "line": "x"}"#), .log("x"))
        XCTAssertEqual(E.decode(#"{"event": "heartbeat", "at": 1800000000}"#), .heartbeat(t(0)))
    }

    func testHostileEventsNeverTrap() {
        typealias E = Reticulum.Event
        let now = t(0)
        XCTAssertNil(E.decode("", now: now))
        XCTAssertNil(E.decode("[1,2]", now: now))
        XCTAssertNil(E.decode(#"{"event": 7}"#, now: now))
        XCTAssertNil(E.decode(#"{"event": "new thing"}"#, now: now))
        XCTAssertNil(E.decode(#"{"event": "announce", "hash": "zz"}"#, now: now), "not an address")
        XCTAssertNil(E.decode(#"{"event": "message", "direction": "in", "hash": "h", "from": null}"#, now: now))
        XCTAssertNil(E.decode(#"{"event": "message", "direction": "in", "from": "\#(maya)"}"#, now: now), "no hash to tell repeats by")
        // Numbers of the wrong kind and size.
        XCTAssertEqual(E.decode(#"{"event": "announce", "hash": "\#(maya)", "hops": 1e308, "stamp_cost": true, "at": -5}"#, now: now),
                       .announce(.init(hash: maya, name: nil, hops: nil, stampCost: nil, at: now)))
        XCTAssertEqual(E.decode(#"{"event": "python_exited", "code": 1e300}"#, now: now), .pythonExited(0))
        guard case .started(let s)? = E.decode(#"{"event": "started", "rnode": {"frequency": -1, "bandwidth": 1e40}, "timings_ms": 3}"#, now: now) else { return XCTFail() }
        XCTAssertNil(s.radio)
        guard case .message(let m)? = E.decode(#"{"event": "message", "direction": "in", "hash": "h", "from": "\#(maya)", "text": 5, "signature_validated": "yes", "unverified": "signature invalid"}"#, now: now) else { return XCTFail() }
        XCTAssertEqual(m.text, "")
        XCTAssertEqual(m.trust, .badSignature)
        XCTAssertNil(Data(reticulumHex: "abc"))
        XCTAssertNil(Data(reticulumHex: "zz"))
        XCTAssertEqual(Data(reticulumHex: "00fF"), Data([0, 255]))
    }
}
