import XCTest
@testable import WildcatRadioCore

final class NodesTests: XCTestCase {
    private var v: [String: Data] = [:]
    private let me = NodeNum(0xDEAD_BEEF)
    private let pk = Data(1...8)

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "meshtastic-vectors", withExtension: "json"))
        let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        v = raw.filter { $0.value.allSatisfy(\.isHexDigit) }.mapValues { s in
            var d = Data()
            var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                d.append(UInt8(s[i..<j], radix: 16)!)
                i = j
            }
            return d
        }
    }

    func testFullNodeInfo() throws {
        guard case .nodeInfo(let n) = try MeshCodec.decodeFromRadio(try XCTUnwrap(v["fromradio_nodeinfo_full"])) else { return XCTFail() }
        XCTAssertEqual(n.shortName, "GO")
        XCTAssertEqual(n.hardware, "RAK4631")
        XCTAssertEqual(n.role, DeviceRole.router.rawValue)
        XCTAssertEqual(n.position?.latitude ?? 0, 39.1031, accuracy: 1e-6)
        XCTAssertEqual(n.altitude, 250)
        XCTAssertEqual(n.metrics?.batteryLevel, 87)
        XCTAssertEqual(n.metrics?.voltage ?? 0, 4.05, accuracy: 0.001)
        XCTAssertEqual(n.metrics?.channelUtilization ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(n.metrics?.uptime, 86400)
        XCTAssertEqual(n.lastHeard, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(n.hopsAway, 2)
        XCTAssertTrue(n.viaMQTT)
        XCTAssertTrue(n.isFavorite)
        XCTAssertFalse(n.isIgnored)
    }

    func testTrafficUpdatesTheNodeDatabase() throws {
        var s = MeshSession(configID: 1)
        _ = s.handle(.myInfo(me))
        _ = s.handle(try MeshCodec.decodeFromRadio(try XCTUnwrap(v["fromradio_telemetry"])))
        let go = try XCTUnwrap(s.nodes[NodeNum(0x716C_668C)])
        XCTAssertTrue(go.metrics?.isPowered ?? false)
        XCTAssertEqual(go.hopsAway, 0)
        XCTAssertEqual(go.snr, 5.5)
        XCTAssertNotNil(go.lastHeard)
        _ = s.handle(try MeshCodec.decodeFromRadio(try XCTUnwrap(v["fromradio_nodeinfo_packet"])))
        let hiker = try XCTUnwrap(s.nodes[NodeNum(0x0BAD_F00D)])
        XCTAssertEqual(hiker.longName, "New Hiker")
        XCTAssertEqual(hiker.hardware, "T-Echo")
        s.setFlags(NodeNum(0x0BAD_F00D), favorite: true)
        XCTAssertTrue(s.nodes[NodeNum(0x0BAD_F00D)]?.isFavorite ?? false)
        s.setFlags(NodeNum(0x0BAD_F00D), remove: true)
        XCTAssertNil(s.nodes[NodeNum(0x0BAD_F00D)])
    }

    func testTracerouteAnswer() throws {
        guard case .packet(let p) = try MeshCodec.decodeFromRadio(try XCTUnwrap(v["fromradio_traceroute"])) else { return XCTFail() }
        XCTAssertEqual(p.requestID, 781)
        let r = try XCTUnwrap(p.route)
        XCTAssertEqual(r.towards, [NodeNum(0x1111_1111), NodeNum(0x2222_2222)])
        XCTAssertEqual(r.snrTowards, [6, -2, 2.5])
        XCTAssertEqual(r.back, [NodeNum(0x2222_2222)])
        XCTAssertEqual(r.snrBack, [3, 1])
    }

    func testFavoriteIgnoreRemoveBytes() throws {
        let go = NodeNum(0x716C_668C)
        XCTAssertEqual(Admin.setFavorite(go, true, me: me, passkey: pk, id: 1008), v["admin_set_favorite"])
        XCTAssertEqual(Admin.setFavorite(go, false, me: me, passkey: pk, id: 1009), v["admin_remove_favorite"])
        XCTAssertEqual(Admin.setIgnored(go, true, me: me, passkey: pk, id: 1010), v["admin_set_ignored"])
        XCTAssertEqual(Admin.setIgnored(go, false, me: me, passkey: pk, id: 1011), v["admin_remove_ignored"])
        XCTAssertEqual(Admin.removeNode(go, me: me, passkey: pk, id: 1012), v["admin_remove_node"])
    }

    func testFixedPositionAndChannelToReach() throws {
        XCTAssertEqual(Admin.setFixedPosition(Coordinate(latitude: 39.1031, longitude: -84.512), altitude: 250,
                                              time: Date(timeIntervalSince1970: 1_790_000_000), me: me, passkey: pk, id: 1013),
                       v["admin_set_fixed_position"])
        XCTAssertEqual(Admin.removeFixedPosition(me: me, passkey: pk, id: 1014), v["admin_remove_fixed_position"])
        var s = MeshSession(configID: 1)
        _ = s.handle(try MeshCodec.decodeFromRadio(try XCTUnwrap(v["fromradio_nodeinfo_channel"])))
        XCTAssertEqual(s.channel(toReach: NodeNum(0x53FD_8B02)), 4)
        _ = s.handle(.channel(ChannelInfo(index: 5, name: "WGHUNT", role: .secondary)))
        XCTAssertEqual(s.channel(toReach: NodeNum(0x1234)), 5, "unknown node: WGHUNT")
    }

    func testPrivateAppPackets() throws {
        XCTAssertEqual(MeshCodec.privatePacket(Data([0x57, 0x47, 0x47, 1, 9, 9, 9, 9]), channel: 1, id: 1300), v["toradio_private_app"])
        guard case .packet(let p) = try MeshCodec.decodeFromRadio(try XCTUnwrap(v["fromradio_private_app"])) else { return XCTFail() }
        XCTAssertEqual(p.portnum, .privateApp)
        XCTAssertEqual(p.payload, Data([0x57, 0x47, 0x47, 1, 7]))
    }
}
