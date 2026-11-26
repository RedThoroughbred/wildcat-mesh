import XCTest
@testable import WildcatRadioCore

final class MeshCodecTests: XCTestCase {
    private var vectors: [String: Data] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "meshtastic-vectors", withExtension: "json"))
        let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        vectors = raw.filter { $0.value.allSatisfy(\.isHexDigit) }.mapValues { hex in
            var d = Data()
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                d.append(UInt8(hex[i..<j], radix: 16)!)
                i = j
            }
            return d
        }
    }

    private func v(_ k: String) throws -> Data { try XCTUnwrap(vectors[k], k) }

    func testTextPacket() throws {
        guard case .packet(let p) = try MeshCodec.decodeFromRadio(v("fromradio_text")) else { return XCTFail() }
        XCTAssertEqual(p.from, NodeNum(0x9E76_6B18))
        XCTAssertEqual(p.from.id, "!9e766b18")
        XCTAssertEqual(p.from.short, "6b18")
        XCTAssertTrue(p.isBroadcast)
        XCTAssertEqual(p.channel, 1)
        XCTAssertEqual(p.id, 12345)
        XCTAssertEqual(p.rxTime, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(p.rxSNR, 6.5)
        XCTAssertEqual(p.rxRSSI, -88)
        XCTAssertEqual(p.hops, 0)
        XCTAssertTrue(p.isDirectRF)
        XCTAssertEqual(p.relayNode, 0x18)
        XCTAssertEqual(p.portnum, .text)
        XCTAssertEqual(p.text, "WG W FOX7 WARMER -94>-88 BEST -85 BRG 045")
        XCTAssertFalse(p.isEncrypted)
    }

    func testPositionPacketRelayedViaMQTT() throws {
        guard case .packet(let p) = try MeshCodec.decodeFromRadio(v("fromradio_position")) else { return XCTFail() }
        XCTAssertEqual(p.from.id, "!0a1b2c3d")
        XCTAssertEqual(p.to.id, "!9e766b18")
        XCTAssertEqual(p.hops, 2)
        XCTAssertTrue(p.viaMQTT)
        XCTAssertFalse(p.isDirectRF)
        XCTAssertEqual(p.rxRSSI, -112)
        XCTAssertEqual(p.rxSNR, -3.25)
        XCTAssertEqual(p.position?.latitude ?? 0, 38.4123456, accuracy: 1e-9)
        XCTAssertEqual(p.position?.longitude ?? 0, -85.2345678, accuracy: 1e-9)
    }

    func testEncryptedPacket() throws {
        guard case .packet(let p) = try MeshCodec.decodeFromRadio(v("fromradio_encrypted")) else { return XCTFail() }
        XCTAssertTrue(p.isEncrypted)
        XCTAssertNil(p.text)
        XCTAssertNil(p.rxRSSI, "0 means not measured")
    }

    func testConfigFrames() throws {
        XCTAssertEqual(try MeshCodec.decodeFromRadio(v("fromradio_myinfo")), .myInfo(NodeNum(0xDEAD_BEEF)))
        guard case .nodeInfo(var n) = try MeshCodec.decodeFromRadio(v("fromradio_nodeinfo")) else { return XCTFail() }
        XCTAssertNotNil(n.userRaw)
        n.userRaw = nil
        XCTAssertEqual(n, NodeInfo(num: NodeNum(0x9E76_6B18), userID: "!9e766b18", longName: "Wildcat Den",
                                   shortName: "DEN", snr: 7.75))
        guard case .channel(var c) = try MeshCodec.decodeFromRadio(v("fromradio_channel")) else { return XCTFail() }
        XCTAssertNotNil(c.settings)
        c.settings = nil
        XCTAssertEqual(c, ChannelInfo(index: 1, name: "WGHUNT", role: .secondary))
        XCTAssertEqual(try MeshCodec.decodeFromRadio(v("fromradio_config_complete")), .configComplete(424_242))
    }

    func testEncodersMatchOfficialBytes() throws {
        XCTAssertEqual(MeshCodec.textPacket("WG SIG FOX7 -88 6.5", channel: 1, id: 777, wantAck: false), try v("toradio_text_broadcast"))
        XCTAssertEqual(MeshCodec.textPacket("WG PING ab12", to: NodeNum(0x9E76_6B18), channel: 0, id: 778),
                       try v("toradio_text_dm"))
        XCTAssertEqual(MeshCodec.wantConfig(id: 123_456_789), try v("toradio_want_config"))
        XCTAssertEqual(MeshCodec.heartbeat(), try v("toradio_heartbeat"))
    }

    func testPositionPackets() throws {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(MeshCodec.positionPacket(time: t, channel: 1, id: 779), try v("toradio_position_beacon"))
        XCTAssertEqual(MeshCodec.positionPacket(coordinate: Coordinate(latitude: 39.1031, longitude: -84.512),
                                                altitude: 256, time: t, id: 780), try v("toradio_position_full"))
    }

    func testTraceroute() throws {
        XCTAssertEqual(MeshCodec.traceroutePacket(to: NodeNum(0x9E76_6B18), channel: 1, id: 781), try v("toradio_traceroute"))
    }

    func testMessagingFrames() throws {
        guard case .packet(let ack) = try MeshCodec.decodeFromRadio(v("fromradio_ack")) else { return XCTFail() }
        XCTAssertEqual(ack.portnum, .routing)
        XCTAssertEqual(ack.requestID, 777)
        XCTAssertEqual(ack.routingError, RoutingError.none)
        XCTAssertTrue(ack.routingError?.isSuccess ?? false)
        guard case .packet(let nak) = try MeshCodec.decodeFromRadio(v("fromradio_nak")) else { return XCTFail() }
        XCTAssertEqual(nak.requestID, 778)
        XCTAssertEqual(nak.routingError, .maxRetransmit)
        guard case .packet(let reply) = try MeshCodec.decodeFromRadio(v("fromradio_reply")) else { return XCTFail() }
        XCTAssertEqual(reply.text, "on my way")
        XCTAssertEqual(reply.replyID, 777)
        XCTAssertFalse(reply.isReaction)
        guard case .packet(let tap) = try MeshCodec.decodeFromRadio(v("fromradio_reaction")) else { return XCTFail() }
        XCTAssertEqual(tap.text, "👍")
        XCTAssertTrue(tap.isReaction)
        XCTAssertEqual(tap.replyID, 777)
    }

    func testMessagingEncoders() throws {
        XCTAssertEqual(MeshCodec.textPacket("hello mesh", channel: 1, id: 904), try v("toradio_text_broadcast_ack"))
        XCTAssertEqual(MeshCodec.textPacket("❤️", to: NodeNum(0x9E76_6B18), id: 905, replyID: 902, isReaction: true),
                       try v("toradio_reaction_dm"))
    }

    func testTruncatedInputThrows() {
        XCTAssertThrowsError(try MeshCodec.decodeFromRadio(Data([0x12, 0x10, 0x0d])))
    }

    func testNodeNumParsing() {
        XCTAssertEqual(NodeNum(id: "!9E766B18"), NodeNum(0x9E76_6B18))
        XCTAssertEqual(NodeNum(id: "9e766b18"), NodeNum(0x9E76_6B18))
        XCTAssertNil(NodeNum(id: "!9e766b1"))
        XCTAssertEqual(NodeNum(0x9E76_6B18).relayByte, 0x18)
    }

    func testSessionBuildsNodeDatabaseAndBecomesReady() throws {
        var s = MeshSession(configID: 424_242)
        XCTAssertEqual(s.wantConfig, MeshCodec.wantConfig(id: 424_242))
        XCTAssertEqual(s.handle(try MeshCodec.decodeFromRadio(v("fromradio_myinfo"))), .myNode(NodeNum(0xDEAD_BEEF)))
        XCTAssertNil(s.handle(try MeshCodec.decodeFromRadio(v("fromradio_nodeinfo"))))
        XCTAssertNil(s.handle(try MeshCodec.decodeFromRadio(v("fromradio_channel"))))
        XCTAssertEqual(s.channelIndex(named: "wghunt"), 1)
        XCTAssertEqual(s.label(for: NodeNum(0x9E76_6B18)), "DEN")
        XCTAssertEqual(s.label(for: NodeNum(0x1)), "!00000001")
        XCTAssertFalse(s.isReady)
        XCTAssertNil(s.handle(.configComplete(1)), "another client's config id")
        XCTAssertEqual(s.handle(try MeshCodec.decodeFromRadio(v("fromradio_config_complete"))), .ready)
        XCTAssertTrue(s.isReady)
    }
}
