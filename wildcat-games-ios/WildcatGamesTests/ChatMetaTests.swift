import XCTest
import WildcatRadioCore
@testable import WildcatGames

@MainActor
final class ChatMetaTests: XCTestCase {
    private func line(_ network: MeshNetwork = .meshcore) -> ChatLine {
        ChatLine(id: UUID(), network: network, time: Date(), text: "hi")
    }

    func testNumbersUseTrueMinusAndTrimZeros() {
        XCTAssertEqual(ChatMeta.number(12.2), "12.2")
        XCTAssertEqual(ChatMeta.number(6.75), "6.75")
        XCTAssertEqual(ChatMeta.number(-3.0), "−3")
        XCTAssertEqual(ChatMeta.number(-0.001), "0")
        XCTAssertEqual(ChatMeta.number(.nan), "—")
        XCTAssertEqual(ChatMeta.dBm(-97), "−97 dBm")
        XCTAssertEqual(ChatMeta.duration(ms: 640), "640 ms")
        XCTAssertEqual(ChatMeta.duration(ms: 1800), "1.8 s")
        XCTAssertEqual(ChatMeta.hops(0), "direct")
        XCTAssertEqual(ChatMeta.hops(1), "1 hop")
        XCTAssertEqual(ChatMeta.path([Data([0x7a]), Data([0xc4, 0x01])]), "7a›c401")
    }

    func testPlainAndRawLinesForAReceivedMessage() {
        var l = line()
        XCTAssertNil(ChatMeta.plain(l), "nothing known, nothing said")
        XCTAssertNil(ChatMeta.raw(l))
        l.hops = 5
        l.snr = 12.2
        l.rssi = -97
        l.path = [Data([0x7a]), Data([0xc4])]
        XCTAssertEqual(ChatMeta.plain(l), "5 hops · strong signal")
        XCTAssertEqual(ChatMeta.raw(l), "SNR 12.2 · −97 dBm · path 7a›c4")
        l.viaMQTT = true
        XCTAssertEqual(ChatMeta.plain(l), "5 hops · through the internet")
    }

    func testBridgedLineSaysWhereItWasSaid() {
        var l = line()
        l.bridged = BridgeOrigin(network: .meshtastic, senderName: "STAY", hops: 3)
        l.bridgeVia = "Wildcat Bag"
        XCTAssertEqual(ChatMeta.plain(l), "3 hops on Meshtastic, relayed here by Wildcat Bag")
        l.bridged?.hops = nil
        l.bridgeVia = nil
        XCTAssertEqual(ChatMeta.plain(l), "Said on Meshtastic")
    }

    func testOwnMessageStatusWords() {
        var l = line()
        l.mine = true
        l.flood = true
        l.size = 44
        l.airtimeMs = 63
        XCTAssertEqual(ChatMeta.sentRaw(l), "flood · 44 B · 63 ms")
        l.status = .heardBy(3)
        XCTAssertEqual(ChatMeta.status(l), "heard by 3 repeaters")
        l.status = .heardBy(1)
        XCTAssertEqual(ChatMeta.status(l), "heard by 1 repeater")
        l.status = .delivered
        l.roundTripMs = 1800
        XCTAssertEqual(ChatMeta.status(l), "delivered 1.8 s")
        l.status = .failed("No answer")
        XCTAssertEqual(ChatMeta.status(l), "not sent · No answer")
        XCTAssertFalse(l.filtered, "your own text is never masked")
        XCTAssertTrue(line().filtered)
    }

    func testMeshCoreSizeRoundsUpToCipherBlocks() {
        // "MAYA: hi" = 8 bytes + 5 of timestamp and flags = 13 -> one 16-byte block, plus 5 of header.
        XCTAssertEqual(ChatMeta.meshcoreSize(text: "hi", senderName: "MAYA", channel: true), 21)
        XCTAssertEqual(ChatMeta.meshcoreSize(text: String(repeating: "a", count: 12), senderName: nil, channel: false), 6 + 32)
    }

    func testThreadFilterByChipAndSearch() {
        let a = MessageThread(id: "a", route: .meshcore(.channel(0)), network: .meshcore, title: "Public", preview: "solar is up")
        var b = MessageThread(id: "b", route: .meshtastic(.direct("!1")), network: .meshtastic, title: "MAYA")
        b.direct = true
        let all = [a, b]
        XCTAssertEqual(MessageThread.filtered(all, by: .all, query: "").map(\.id), ["a", "b"])
        XCTAssertEqual(MessageThread.filtered(all, by: .meshcore, query: "").map(\.id), ["a"])
        XCTAssertEqual(MessageThread.filtered(all, by: .meshtastic, query: "").map(\.id), ["b"])
        XCTAssertEqual(MessageThread.filtered(all, by: .direct, query: "").map(\.id), ["b"])
        XCTAssertEqual(MessageThread.filtered(all, by: .all, query: "SOLAR").map(\.id), ["a"])
        XCTAssertEqual(MessageThread.filtered(all, by: .direct, query: "solar").map(\.id), [])
        XCTAssertEqual(MessageThread.filtered(all, by: .reticulum, query: "").map(\.id), [])
    }

    func testReticulumConversationsFollowChipAndSearch() {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        var book = Reticulum.Book()
        book.heard(hash: a, name: "MAYA", hops: 1, stampCost: nil, at: Date(timeIntervalSince1970: 10))
        _ = book.add(.init(id: "1", incoming: true, peer: a, text: "the creek is up", at: Date(timeIntervalSince1970: 20), delivery: .queued))
        _ = book.add(.init(id: "2", incoming: false, peer: b, text: "on my way", at: Date(timeIntervalSince1970: 30), delivery: .queued))
        let all = book.conversations
        func shown(_ f: MessageThread.Filter, _ q: String) -> Set<String> {
            Set(MessageThread.filtered(all, by: f, query: q, title: { $0.title }, text: { $0.last.text }).map(\.peer))
        }
        XCTAssertEqual(shown(.all, ""), [a, b])
        XCTAssertEqual(shown(.reticulum, ""), [a, b])
        XCTAssertEqual(shown(.direct, ""), [a, b], "every Reticulum conversation is person to person")
        XCTAssertEqual(shown(.meshcore, ""), [])
        XCTAssertEqual(shown(.meshtastic, ""), [])
        XCTAssertEqual(shown(.all, "maya"), [a], "by name")
        XCTAssertEqual(shown(.reticulum, "WAY"), [b], "by the last message")
        XCTAssertEqual(shown(.all, "zzz"), [])
    }
}
