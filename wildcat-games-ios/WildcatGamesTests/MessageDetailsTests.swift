import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// Message details kept for the message view: which radio, hops, signal, size,
/// receive time, round trip, bridged origin, raw packet. Old saves must still load.
@MainActor
final class MessageDetailsTests: XCTestCase {
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

    private func packet(id: UInt32, text: String, rxTime: Date? = nil) throws -> MeshPacket {
        // Through the real decoder, so raw bytes and size are what the node would hand over.
        let toRadio = MeshCodec.textPacket(text, to: .broadcast, channel: 1, id: id)
        var p = try MeshCodec.decodePacket(try XCTUnwrap(try Proto.Message(toRadio).bytes(1)))
        p.from = PracticeMesh.fox
        p.rxTime = rxTime
        p.rxSNR = 6.25
        p.rxRSSI = -97
        p.hopStart = 3
        p.hopLimit = 1
        p.relayNode = 0x3E
        return p
    }

    func testReceivedMessageKeepsItsDetails() throws {
        let heard = Date(timeIntervalSince1970: 1_790_000_000)
        store.handle(.packet(try packet(id: 60, text: "anyone out?", rxTime: heard)))
        let m = try XCTUnwrap(store.messages.last)
        XCTAssertEqual(m.radio, PracticeMesh.me.id)
        XCTAssertEqual(m.receivedAt, heard, "the node's receive time")
        XCTAssertEqual(m.hopStart, 3)
        XCTAssertEqual(m.hopLimit, 1)
        XCTAssertEqual(m.hops, 2)
        XCTAssertEqual(m.relayNode, 0x3E)
        XCTAssertEqual(m.rssi, -97)
        XCTAssertEqual(m.size, 16 + MeshCodec.textDataSize("anyone out?"))
        XCTAssertNil(m.raw, "raw packets are off by default")
        XCTAssertNil(m.bridged)

        store.keepsRawPackets = true
        store.handle(.packet(try packet(id: 61, text: "second")))
        XCTAssertNotNil(store.messages.last?.raw)
        XCTAssertEqual(store.messages.last?.receivedAt, store.messages.last?.time, "no node time: when the phone got it")
    }

    func testIncomingBridgedLineGetsItsOrigin() throws {
        store.handle(.packet(try packet(id: 62, text: "[MC] MAYA Field Unit: Howdy")))
        let o = try XCTUnwrap(store.messages.last?.bridged)
        XCTAssertEqual(o.network, .meshcore)
        XCTAssertEqual(o.senderName, "MAYA Field Unit")
        XCTAssertEqual(o.via, PracticeMesh.fox.id)
    }

    func testSentMessageSizeOriginAndRoundTrip() throws {
        let origin = BridgeOrigin(network: .meshcore, senderName: "MAYA", channel: "WGBRIDGE", hops: 1)
        XCTAssertTrue(store.send("[MC] MAYA: hi", in: .direct(PracticeMesh.fox.id), bridged: origin))
        let m = try XCTUnwrap(store.messages.last)
        XCTAssertEqual(m.bridged, origin)
        XCTAssertEqual(m.radio, PracticeMesh.me.id)
        XCTAssertEqual(m.size, 16 + MeshCodec.textDataSize("[MC] MAYA: hi"))
        var ack = MeshPacket(from: PracticeMesh.fox, to: PracticeMesh.me, id: 1, portnum: .routing)
        ack.requestID = m.packetID
        ack.routingError = RoutingError.none
        store.handle(.packet(ack))
        XCTAssertEqual(store.messages.last?.status, .delivered)
        XCTAssertNotNil(store.messages.last?.roundTripMs)
    }

    func testDetailsSurviveSaveAndOldSavesLoad() throws {
        store.keepsRawPackets = true
        store.handle(.packet(try packet(id: 63, text: "keep me", rxTime: Date(timeIntervalSince1970: 1_790_000_000))))
        store.save()
        let again = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
        XCTAssertEqual(again.messages.last?.raw, store.messages.last?.raw)
        XCTAssertEqual(again.messages.last?.hopStart, 3)
        XCTAssertEqual(again.messages.last?.relayNode, 0x3E)
        XCTAssertEqual(again.messages.last?.receivedAt, Date(timeIntervalSince1970: 1_790_000_000))

        // Saved by an older version (one file for every radio) before any detail existed,
        // plus a detail this version can't read: migrated, then shown before any radio connects.
        let oldDir = dir.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let old = #"{"messages":[{"packetID":7,"from":"!0000abcd","conversation":{"channel":{"_0":1}},"text":"old one","time":700000000,"outgoing":false,"status":{"received":{}},"snr":5,"rssi":-90,"hops":1,"hopStart":"three"}]}"#
        try Data(old.utf8).write(to: oldDir.appendingPathComponent("messages.json"))
        let loaded = MessageStore(radio: Radio(), folder: oldDir, defaults: try XCTUnwrap(UserDefaults(suiteName: "msgs-\(UUID())")))
        let m = try XCTUnwrap(loaded.messages.first)
        XCTAssertEqual(m.text, "old one")
        XCTAssertEqual(m.rssi, -90)
        XCTAssertNil(m.radio)
        XCTAssertNil(m.receivedAt)
        XCTAssertNil(m.hopStart)
        XCTAssertNil(m.bridged)
        XCTAssertNil(m.raw)
    }

    func testBridgeLogIsKeptAcrossLaunches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bridge-\(UUID())"))
        let origin = BridgeOrigin(network: .meshtastic, senderID: "!a3f9c21e", senderName: "STAY", channel: "LongFast", hops: 3)
        let lines = (0..<(MeshBridge.keepLog + 5)).map {
            MeshBridge.Line(way: .toMeshCore, text: "[MT] STAY: \($0)", at: Date(timeIntervalSince1970: TimeInterval($0)),
                            dmMeshtastic: $0 == MeshBridge.keepLog + 4 ? PracticeMesh.fox : nil, origin: origin)
        }
        defaults.set(try JSONEncoder().encode(lines), forKey: MeshBridge.logKey)
        let bridge = MeshBridge(radio: radio, meshcore: MeshCoreLink(defaults: defaults), messages: store, defaults: defaults)
        XCTAssertEqual(bridge.log.count, MeshBridge.keepLog, "capped")
        XCTAssertEqual(bridge.log.last?.text, "[MT] STAY: \(MeshBridge.keepLog + 4)")
        XCTAssertEqual(bridge.log.last?.origin, origin)
        XCTAssertEqual(bridge.log.last?.dmMeshtastic, PracticeMesh.fox)
        XCTAssertEqual(bridge.log.last?.id, lines.last?.id)
    }
}
