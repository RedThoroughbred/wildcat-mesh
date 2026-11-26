import XCTest
@testable import WildcatRadioCore

/// The "Heard on air" header reader against packets the RNS library built and read back itself
/// (RNS 1.5.7, `Fixtures/make_reticulum_fixtures.py` → `reticulum-packets.json`: a throwaway
/// Reticulum with no interfaces, nothing sent), then the session's heard list.
final class ReticulumPacketTests: XCTestCase {
    struct Fixture: Decodable {
        struct RNSReading: Decodable {
            let header_type: Int, context_flag: Int, propagation: Int, destination_type: Int, packet_type: Int, hops: Int
            let transport_id: String?, destination_hash: String, context: Int, data_length: Int
        }
        struct Vector: Decodable {
            let name: String, note: String, raw: String, length: Int
            /// How RNS's inbound path read it; nil when RNS dropped it as malformed.
            let rns: RNSReading?
            let ifac: Bool?
        }
        let rns_version: String
        let path_request_destination: String
        let vectors: [Vector]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "reticulum-packets", withExtension: "json")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    static func bytes(_ hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    func vector(_ name: String) -> Fixture.Vector { Self.fixture.vectors.first { $0.name == name }! }
    func raw(_ name: String) -> Data { Self.bytes(vector(name).raw) }
    func packet(_ name: String) throws -> ReticulumPacket { try XCTUnwrap(ReticulumPacket(raw(name)), name) }

    // MARK: Agreement with RNS

    func testEveryVectorReadsTheWayRNSReadsIt() throws {
        XCTAssertEqual(Self.fixture.rns_version, "1.5.7")
        XCTAssertGreaterThanOrEqual(Self.fixture.vectors.count, 20)
        for v in Self.fixture.vectors {
            let raw = Self.bytes(v.raw)
            XCTAssertEqual(raw.count, v.length, v.name)
            let reading = ReticulumPacket.read(raw)
            if v.ifac == true {
                XCTAssertEqual(reading, .masked, "\(v.name): \(v.note)")
                continue
            }
            guard let r = v.rns else {
                guard case .unreadable = reading else { return XCTFail("\(v.name): RNS drops it, Wildcat read \(reading)") }
                continue
            }
            let p = try XCTUnwrap(reading.packet, "\(v.name): RNS reads it, Wildcat didn't (\(reading))")
            XCTAssertEqual(Int(p.headerType.rawValue), r.header_type, v.name)
            XCTAssertEqual(p.contextFlag ? 1 : 0, r.context_flag, v.name)
            XCTAssertEqual(Int(p.propagation.rawValue), r.propagation, v.name)
            XCTAssertEqual(Int(p.destinationType.rawValue), r.destination_type, v.name)
            XCTAssertEqual(Int(p.packetType.rawValue), r.packet_type, v.name)
            XCTAssertEqual(p.hops, r.hops, v.name)
            XCTAssertEqual(p.transportID.map(ReticulumPacket.hex), r.transport_id, v.name)
            XCTAssertEqual(ReticulumPacket.hex(p.destinationHash), r.destination_hash, v.name)
            XCTAssertEqual(Int(p.context), r.context, v.name)
            XCTAssertEqual(p.dataLength, r.data_length, v.name)
            XCTAssertEqual(p.headerLength + p.dataLength, raw.count, v.name)
            XCTAssertEqual(p.raw, raw)
        }
    }

    func testPathRequestDestinationIsTheOneRNSComputes() {
        XCTAssertEqual(ReticulumPacket.hex(ReticulumPacket.pathRequestDestination), Self.fixture.path_request_destination)
    }

    // MARK: What each kind looks like

    func testAnnounce() throws {
        let p = try packet("announce")
        XCTAssertEqual(p.kind, .announce)
        XCTAssertEqual(p.kind.word, "Announce")
        XCTAssertEqual(p.headerType, .type1)
        XCTAssertNil(p.transportID)
        XCTAssertEqual(p.destinationType, .single)
        XCTAssertEqual(p.propagation, .broadcast)
        XCTAssertFalse(p.contextFlag)
        XCTAssertEqual(p.hops, 0)
        XCTAssertEqual(p.headerLength, 19)
        XCTAssertEqual(p.destinationPrefix, String(vector("announce").rns!.destination_hash.prefix(8)))
        XCTAssertNil(p.contextName)
    }

    func testRatchetAnnounceSetsTheContextFlag() throws {
        let p = try packet("announce_ratchet")
        XCTAssertEqual(p.kind, .announce)
        XCTAssertTrue(p.contextFlag)
    }

    func testRelayedAnnounceCarriesTheTransportID() throws {
        let p = try packet("announce_relayed")
        XCTAssertEqual(p.headerType, .type2)
        XCTAssertEqual(p.propagation, .transport)
        XCTAssertEqual(p.hops, 1)
        XCTAssertEqual(p.transportID?.count, 16)
        XCTAssertEqual(p.headerLength, 35)
        XCTAssertEqual(p.destinationHash, try packet("announce").destinationHash, "the same beacon, passed on")
    }

    func testDataPathRequestLinkRequestAndProof() throws {
        XCTAssertEqual(try packet("data_plain").kind, .data)
        XCTAssertEqual(try packet("data_plain").destinationType, .plain)
        XCTAssertEqual(try packet("data_single").kind, .data)
        XCTAssertEqual(try packet("data_single").destinationType, .single)
        let path = try packet("path_request")
        XCTAssertEqual(path.kind, .pathRequest)
        XCTAssertEqual(path.kind.word, "Path request")
        XCTAssertEqual(path.raw.count, 51, "the manual's size for a path request")
        XCTAssertEqual(try packet("link_request").kind, .linkRequest)
        XCTAssertEqual(try packet("proof").kind, .proof)
        // Data to any other PLAIN destination is just data.
        XCTAssertEqual(try packet("mtu").kind, .data)
        XCTAssertEqual(try packet("mtu").raw.count, ReticulumPacket.mtu)
    }

    func testContextNames() throws {
        let lr = try packet("link_proof_flags")
        XCTAssertEqual(lr.kind, .proof)
        XCTAssertEqual(lr.destinationType, .link)
        XCTAssertEqual(lr.hops, 3)
        XCTAssertEqual(lr.contextName, "link request proof")
        XCTAssertEqual(try packet("group_path_response").destinationType, .group)
        XCTAssertEqual(try packet("group_path_response").contextName, "path response")
        XCTAssertTrue(try packet("context_flag_data").contextFlag)
        XCTAssertEqual(ReticulumPacket.contextNames[0xFA], "keepalive")
    }

    func testMaskedAndUnreadableSayWhy() {
        XCTAssertEqual(ReticulumPacket.read(raw("ifac_masked")).kind, .masked)
        XCTAssertEqual(ReticulumPacket.Kind.masked.word, "Access code")
        XCTAssertNil(ReticulumPacket(raw("ifac_masked")))
        XCTAssertEqual(ReticulumPacket.read(raw("no_data")), .unreadable(.noData))
        XCTAssertEqual(ReticulumPacket.read(raw("hops_128")), .unreadable(.tooManyHops(128)))
        XCTAssertEqual(ReticulumPacket.read(raw("type2_short")), .unreadable(.tooShort(length: 20, needed: 36)))
        XCTAssertEqual(ReticulumPacket.read(raw("two_bytes")), .unreadable(.tooShort(length: 2, needed: 20)))
        XCTAssertEqual(ReticulumPacket.read(Data()), .unreadable(.tooShort(length: 0, needed: 20)))
        // The IFAC bit on something too short to hold an access code is just short.
        XCTAssertEqual(ReticulumPacket.read(Data([0x80])), .unreadable(.tooShort(length: 1, needed: 21)))
        XCTAssertEqual(ReticulumPacket.read(Data(repeating: 0x80, count: 21)), .masked)
        XCTAssertEqual(ReticulumPacket.Reading.unreadable(.noData).kind, .unreadable)
        XCTAssertEqual(ReticulumPacket.Problem.tooManyHops(200).text, "200 hops: past Reticulum's limit of 128")
        XCTAssertEqual(ReticulumPacket.Problem.tooShort(length: 1, needed: 20).text, "1 byte, too short for a Reticulum header (20+)")
    }

    func testGarbageNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        for n in 0...600 {
            _ = ReticulumPacket.read(Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
        for flags in UInt8(0)...UInt8(255) {
            for length in [0, 1, 2, 18, 19, 20, 34, 35, 36, 37] {
                var d = Data(repeating: flags, count: length)
                if !d.isEmpty { d[d.startIndex] = flags }
                _ = ReticulumPacket.read(d)
                _ = ReticulumPacket.read(d.dropFirst())   // a slice with a non-zero start index
            }
        }
    }

    // MARK: Frames on air

    func testAirFramesFollowTheRNodeSplit() {
        XCTAssertEqual(RNodeSession.airFrames(188), 1)
        XCTAssertEqual(RNodeSession.airFrames(254), 1)
        XCTAssertEqual(RNodeSession.airFrames(255), 2)
        XCTAssertEqual(RNodeSession.airFrameBytes(188), [189])
        XCTAssertEqual(RNodeSession.airFrameBytes(254), [255])
        XCTAssertEqual(RNodeSession.airFrameBytes(255), [255, 2])
        XCTAssertEqual(RNodeSession.airFrameBytes(500), [255, 247])
        XCTAssertEqual(RNodeSession.airFrameBytes(0), [])
        var p = RNode.RadioParameters()
        XCTAssertNil(RNodeSession.airtimeMs(size: 188, parameters: p, preambleSymbols: 18), "no settings yet")
        p.spreadingFactor = 8
        p.bandwidthHz = 125_000
        p.codingRate = 5
        XCTAssertNil(RNodeSession.airtimeMs(size: 188, parameters: p, preambleSymbols: nil), "no preamble yet")
        let one = RNodeSession.airtimeMs(size: 188, parameters: p, preambleSymbols: 18)
        XCTAssertEqual(one, LoRaAirtime.milliseconds(bytes: 189, spreadingFactor: 8, bandwidthKHz: 125, codingRate: 5, preamble: 18))
        let split = RNodeSession.airtimeMs(size: 300, parameters: p, preambleSymbols: 18)
        XCTAssertEqual(split, (LoRaAirtime.milliseconds(bytes: 255, spreadingFactor: 8, bandwidthKHz: 125, codingRate: 5, preamble: 18) ?? 0)
                       + (LoRaAirtime.milliseconds(bytes: 47, spreadingFactor: 8, bandwidthKHz: 125, codingRate: 5, preamble: 18) ?? 0))
    }

    // MARK: The session's heard list

    func testSessionKeepsABoundedHeardListWithCounts() throws {
        var s = RNodeSession()
        let t0 = Date(timeIntervalSince1970: 1_791_500_000)
        XCTAssertTrue(s.heard.isEmpty)
        XCTAssertNil(s.heardSince)
        // The firmware sends RSSI, then SNR, then the packet.
        _ = s.handle(.rssi(-101), now: t0)
        _ = s.handle(.snr(6.5), now: t0)
        let events = s.handle(.data(raw("announce")), now: t0)
        XCTAssertEqual(events, [.packet(raw("announce"))])
        let h = try XCTUnwrap(s.heard.first)
        XCTAssertEqual(h.id, 1)
        XCTAssertEqual(h.at, t0)
        XCTAssertEqual(h.size, 188)
        XCTAssertEqual(h.airFrames, 1)
        XCTAssertEqual(h.rssi, -101)
        XCTAssertEqual(h.snr, 6.5)
        XCTAssertEqual(h.kind, .announce)
        XCTAssertNil(h.airtimeMs, "radio settings not read yet")
        XCTAssertEqual(s.heardSince, t0)
        XCTAssertEqual(s.heardCounts[.announce], 1)
        // A data packet with no RSSI/SNR frames before it, then garbage, then a masked one.
        let t1 = t0.addingTimeInterval(10)
        _ = s.handle(.data(raw("data_plain")), now: t1)
        _ = s.handle(.data(Data([1, 2, 3])), now: t1)
        _ = s.handle(.data(raw("ifac_masked")), now: t1)
        XCTAssertEqual(s.heard.map(\.id), [4, 3, 2, 1], "newest first")
        XCTAssertEqual(s.heard[2].kind, .data)
        XCTAssertNil(s.heard[2].rssi, "no RSSI frame came before it")
        XCTAssertEqual(s.heard[1].reading, .unreadable(.tooShort(length: 3, needed: 20)))
        XCTAssertNil(s.heard[1].packet)
        XCTAssertEqual(s.heard[0].kind, .masked)
        XCTAssertEqual(s.heardCounts, RNodeSession.HeardCounts([.announce: 1, .data: 1, .unreadable: 1, .masked: 1]))
        XCTAssertEqual(s.heardCounts.total, 4)
        XCTAssertEqual(s.heardCounts[.proof], 0)
        XCTAssertEqual(s.packetsHeard, 4)
        XCTAssertEqual(s.heardSince, t0, "the counts began with the first packet")
        XCTAssertEqual(s.heard(kinds: [.announce]).map(\.id), [1])
        XCTAssertEqual(s.heard(kinds: [.data, .masked]).map(\.id), [4, 2])
        XCTAssertEqual(s.heard(kinds: []).count, 4)
        // Fill past the limit: the oldest drop off, the counts keep going.
        for i in 0..<(RNodeSession.heardLimit + 50) {
            _ = s.handle(.data(raw("announce_relayed")), now: t1.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(s.heard.count, RNodeSession.heardLimit)
        XCTAssertEqual(s.heard.first?.id, 4 + RNodeSession.heardLimit + 50)
        XCTAssertEqual(s.heard.last?.id, 55)
        XCTAssertEqual(s.heardCounts.total, 4 + RNodeSession.heardLimit + 50)
        XCTAssertEqual(s.heardCounts[.announce], 1 + RNodeSession.heardLimit + 50)
        // Clear: empty, counts reset, "since" is now; ids keep climbing.
        let t2 = t1.addingTimeInterval(1000)
        s.clearHeard(now: t2)
        XCTAssertTrue(s.heard.isEmpty)
        XCTAssertEqual(s.heardCounts, RNodeSession.HeardCounts())
        XCTAssertEqual(s.heardSince, t2)
        XCTAssertEqual(s.packetsHeard, 4 + RNodeSession.heardLimit + 50, "the all-time count isn't cleared")
        _ = s.handle(.data(raw("data_plain")), now: t2)
        XCTAssertEqual(s.heard.first?.id, 5 + RNodeSession.heardLimit + 50)
        XCTAssertEqual(s.heardSince, t2)
    }

    func testHeardPacketsGetAnAirtimeOnceTheRadioSettingsAreKnown() throws {
        var s = RNodeSession()
        let t = Date(timeIntervalSince1970: 1_791_500_000)
        _ = s.handle(.spreadingFactor(8), now: t)
        _ = s.handle(.bandwidth(125_000), now: t)
        _ = s.handle(.codingRate(5), now: t)
        _ = s.handle(.data(raw("announce")), now: t)
        XCTAssertNil(s.heard.first?.airtimeMs, "the preamble comes with the RNode's PHY stats")
        // symbol 2.048 ms, 488 sym/s, preamble 18 symbols (37 ms), CSMA slot 12 ms, DIFS 48 ms.
        let phy = try XCTUnwrap(RNode.PhyStats(payload: [0x08, 0x00, 0x01, 0xE8, 0x00, 0x12, 0x00, 0x25, 0x00, 0x0C, 0x00, 0x30]))
        _ = s.handle(.phyStats(phy), now: t)
        _ = s.handle(.data(raw("announce")), now: t)
        let ms = try XCTUnwrap(s.heard.first?.airtimeMs)
        XCTAssertEqual(ms, LoRaAirtime.milliseconds(bytes: 189, spreadingFactor: 8, bandwidthKHz: 125, codingRate: 5, preamble: 18))
        // 1512 bits at ~3.1 kbps is ~484 ms, plus ~46 ms of preamble and the LoRa header.
        XCTAssertGreaterThan(ms, 500)
        XCTAssertLessThan(ms, 600)
    }

    func testAnnouncersGroupAnnouncesByDestination() throws {
        var s = RNodeSession()
        let t = Date(timeIntervalSince1970: 1_791_500_000)
        _ = s.handle(.data(raw("announce")), now: t)
        _ = s.handle(.data(raw("announce_ratchet")), now: t.addingTimeInterval(1))
        _ = s.handle(.data(raw("data_single")), now: t.addingTimeInterval(2))
        _ = s.handle(.rssi(-90), now: t.addingTimeInterval(3))
        _ = s.handle(.data(raw("announce_relayed")), now: t.addingTimeInterval(3))
        let a = s.announcers
        XCTAssertEqual(a.count, 2, "two destinations announced; data doesn't count")
        XCTAssertEqual(a[0].destinationHash, try packet("announce").destinationHash, "newest first: the beacon, relayed")
        XCTAssertEqual(a[0].count, 2)
        XCTAssertEqual(a[0].latest.packet?.hops, 1)
        XCTAssertEqual(a[0].latest.rssi, -90)
        XCTAssertEqual(a[1].destinationHash, try packet("announce_ratchet").destinationHash)
        XCTAssertEqual(a[1].count, 1)
    }
}

#if canImport(CoreBluetooth)
import CoreBluetooth

/// The heard list fed through the link, as Bluetooth notifications arrive.
@MainActor
final class RNodeLinkHeardTests: XCTestCase {
    func testANotificationWithSignalAndPacketLandsInTheHeardList() throws {
        var now = Date(timeIntervalSince1970: 1_791_500_000)
        let l = RNodeLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!)
        l.clock = { now }
        l.wire = { _ in }
        l.startSession()
        let announce = ReticulumPacketTests.bytes(ReticulumPacketTests.fixture.vectors.first { $0.name == "announce" }!.raw)
        // RSSI 0x39 → -100 dBm, SNR 0x1a → 6.5 dB, then the packet KISS-escaped in a data frame.
        var frame = Data([0xC0, 0x23, 0x39, 0xC0, 0xC0, 0x24, 0x1A, 0xC0, 0xC0, 0x00])
        frame += Data(RNode.KISS.escape([UInt8](announce)))
        frame.append(0xC0)
        // Bluetooth delivers it in pieces.
        let cut = frame.count / 2
        l.receive(frame.prefix(cut))
        XCTAssertTrue(l.session.heard.isEmpty, "half a frame is nothing yet")
        now += 0.2
        l.receive(frame.suffix(from: cut))
        let h = try XCTUnwrap(l.session.heard.first)
        XCTAssertEqual(h.size, announce.count)
        XCTAssertEqual(h.kind, .announce)
        XCTAssertEqual(h.rssi, -100)
        XCTAssertEqual(h.snr, 6.5)
        XCTAssertEqual(h.at, now)
        l.clearHeard()
        XCTAssertTrue(l.session.heard.isEmpty)
        XCTAssertEqual(l.session.heardSince, now)
    }
}
#endif
