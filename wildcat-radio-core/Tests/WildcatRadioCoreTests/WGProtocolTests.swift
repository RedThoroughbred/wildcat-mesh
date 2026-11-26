import XCTest
@testable import WildcatRadioCore

/// Every reply string below is copied from foxhunt.py / wg.py.
final class WGProtocolTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(WG.Command.join(hunt: "fox7", name: "Maya!").text, "WG JOIN FOX7 MAYA")
        XCTAssertEqual(WG.Command.join(hunt: nil, name: nil).text, "WG JOIN")
        XCTAssertEqual(WG.Command.sig(hunt: "FOX7", .init(rssi: -88, snr: 6.5)).text, "WG SIG FOX7 -88 6.5")
        XCTAssertEqual(WG.Command.sig(hunt: nil, .init(snr: 6.46)).text, "WG SIG SNR 6.5")
        XCTAssertEqual(WG.Command.found(hunt: "FOX7", code: "4821").text, "WG FOUND FOX7 4821")
        XCTAssertEqual(WG.Command.status.text, "WG HUNT")
        XCTAssertEqual(WG.Command.leave.text, "WG LEAVE")
        XCTAssertEqual(WG.Command.ping(nonce: "ab12").text, "WG PING ab12")
        XCTAssertEqual(WG.sanitizedName("9 lives Seth!!"), "LIVESSETH")
    }

    func testPong() {
        XCTAssertEqual(WG.Reply("WG PONG ab12 -88dBm 6.5dB 0h"),
                       .pong(nonce: "ab12", rssi: -88, snr: 6.5, hops: 0, viaMQTT: false))
        XCTAssertEqual(WG.Reply("WG PONG -101dBm -4.2dB 2h mqtt"),
                       .pong(nonce: nil, rssi: -101, snr: -4.2, hops: 2, viaMQTT: true))
    }

    func testJoinGoAndStatus() {
        XCTAssertEqual(WG.Reply("WG OK JOIN FOX7 MAYA 3 HUNTING LIVE FOX 6b18 · SIG <rssi> <snr> · FOUND <code>"),
                       .joined(hunt: "FOX7", name: "MAYA", hunters: 3, phase: .live, fox: "6b18"))
        XCTAssertEqual(WG.Reply("WG GO FOX7 HUNT IS LIVE · FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>"),
                       .go(hunt: "FOX7", fox: "ZEUZ"))
        XCTAssertEqual(WG.Reply("WG HUNT FOX7 LIVE T+3M 2 HUNTERS 0 FOUND FOX 6b18"),
                       .status(hunt: "FOX7", phase: .live, minutes: 3, hunters: 2, found: 0, fox: "6b18"))
        XCTAssertEqual(WG.Reply("WG HUNT NONE"), .noHunt)
        XCTAssertEqual(WG.Reply("WG OK LEAVE FOX7"), .left(hunt: "FOX7"))
    }

    func testWarmth() {
        XCTAssertEqual(WG.Reply("WG W FOX7 WARMER -94>-88 BEST -85 BRG 045"),
                       .warmth(hunt: "FOX7", trend: .warmer, previous: .init(rssi: -94), current: .init(rssi: -88),
                               best: .init(rssi: -85), bearing: 45, askForCode: false))
        XCTAssertEqual(WG.Reply("WG W FOX7 FIRST S6.5 BEST S6.5"),
                       .warmth(hunt: "FOX7", trend: .first, previous: nil, current: .init(snr: 6.5),
                               best: .init(snr: 6.5), bearing: nil, askForCode: false))
        XCTAssertEqual(WG.Reply("WG W FOX7 HOT -80>-72 BEST -72 · FOUND <code>"),
                       .warmth(hunt: "FOX7", trend: .hot, previous: .init(rssi: -80), current: .init(rssi: -72),
                               best: .init(rssi: -72), bearing: nil, askForCode: true))
    }

    func testFinds() {
        XCTAssertEqual(WG.Reply("WG OK FOUND FOX7 #1 +175 CODE+RF-B T+14M"),
                       .youFound(hunt: "FOX7", place: 1, points: 175, proofs: [.code, .rfAttested], minutes: 14))
        XCTAssertEqual(WG.Reply("WG OK FOUND FOX7 #2 +70  T+20M"),
                       .youFound(hunt: "FOX7", place: 2, points: 70, proofs: [], minutes: 20))
        XCTAssertEqual(WG.Reply("WG FOUND FOX7 MAYA #1 T+14M"),
                       .someoneFound(hunt: "FOX7", name: "MAYA", place: 1, minutes: 14))
        XCTAssertEqual(WG.Reply("WG END FOX7 MAYA WINS 1/2 FOUND"),
                       .ended(hunt: "FOX7", winner: "MAYA", found: 1, total: 2))
        XCTAssertEqual(WG.Reply("WG END FOX7 NO FINDS 0/2 FOUND"),
                       .ended(hunt: "FOX7", winner: nil, found: 0, total: 2))
    }

    func testRejections() {
        XCTAssertEqual(WG.Reply("WG NO FOUND FOX7 BADCODE 2/5"), .rejected(verb: "FOUND", hunt: "FOX7", reason: "BADCODE 2/5"))
        XCTAssertEqual(WG.Reply("WG NO FOUND NO HUNT"), .rejected(verb: "FOUND", hunt: nil, reason: "NO HUNT"))
        XCTAssertEqual(WG.Reply("WG NO FOUND FOX7 NOT STARTED"), .rejected(verb: "FOUND", hunt: "FOX7", reason: "NOT STARTED"))
        XCTAssertEqual(WG.Reply("WG NO JOIN FOX7 OVER"), .rejected(verb: "JOIN", hunt: "FOX7", reason: "OVER"))
        XCTAssertEqual(WG.Reply("WG NO SIG FORMAT · WG SIG -88 6.5"), .rejected(verb: "SIG", hunt: nil, reason: "FORMAT"))
    }

    func testNotWGAndUnknown() {
        XCTAssertNil(WG.Reply("hello there"))
        XCTAssertNil(WG.Reply("WG"))
        XCTAssertEqual(WG.Reply("WG ARM TOWER2"), .other("WG ARM TOWER2"))
    }
}
