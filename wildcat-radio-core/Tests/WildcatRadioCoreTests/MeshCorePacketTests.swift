import XCTest
@testable import WildcatRadioCore

final class MeshCorePacketTests: XCTestCase {
    let key = Data((0..<32).map { UInt8(0x40 + $0) })

    func advertPayload(name: String, lat: Int32? = nil, lon: Int32? = nil, kind: UInt8 = 2) -> [UInt8] {
        let p = Array(key) + withUnsafeBytes(of: UInt32(1_790_000_000).littleEndian) { Array($0) } + Array(repeating: 0x5A, count: 64)
        var flags = kind | 0x80
        var extra: [UInt8] = []
        if let lat, let lon {
            flags |= 0x10
            extra += withUnsafeBytes(of: lat.littleEndian) { Array($0) } + withUnsafeBytes(of: lon.littleEndian) { Array($0) }
        }
        return p + [flags] + extra + Array(name.utf8)
    }

    func testZeroHopAdvertIsTheSendersOwnSignal() throws {
        // header: flood (1) | advert (4 << 2) = 0x11; path_len 0
        let raw = Data([0x11, 0x00] + advertPayload(name: "Hilltop RPT", lat: 38_900_000, lon: -84_600_000))
        let p = try XCTUnwrap(MeshCorePacket(raw))
        XCTAssertEqual(p.route, .flood)
        XCTAssertEqual(p.type, .advert)
        XCTAssertEqual(p.hops, 0)
        let a = try XCTUnwrap(p.advert)
        XCTAssertEqual(a.name, "Hilltop RPT")
        XCTAssertEqual(a.kind, .repeater)
        XCTAssertEqual(a.position?.latitude ?? 0, 38.9, accuracy: 1e-9)
        XCTAssertEqual(a.timestamp, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(p.transmitted(by: key))
    }

    func testRelayedPacketBelongsToTheLastHop() throws {
        // flood group text relayed by two repeaters: hashes 0xAA, then 0x40 (our key's first byte)
        let raw = Data([0x15, 0x02, 0xAA, 0x40, 0x9C, 1, 2, 3, 4])
        let p = try XCTUnwrap(MeshCorePacket(raw))
        XCTAssertEqual(p.type, .groupText)
        XCTAssertEqual(p.path, [Data([0xAA]), Data([0x40])])
        XCTAssertEqual(p.lastHop, Data([0x40]))
        XCTAssertTrue(p.transmitted(by: key), "the repeater we're hunting relayed it last")
        XCTAssertFalse(p.transmitted(by: Data([0xAA] + Array(key.dropFirst()))))
        XCTAssertNil(p.advert)
    }

    func testTwoByteHashesAndTransportCodes() throws {
        // transport flood (0) | ack (3 << 2) = 0x0C, 4 transport bytes, path_len: size 2 (0x40), count 1
        let raw = Data([0x0C, 9, 9, 9, 9, 0x41, 0x40, 0x41, 7, 7, 7, 7])
        let p = try XCTUnwrap(MeshCorePacket(raw))
        XCTAssertEqual(p.route, .transportFlood)
        XCTAssertEqual(p.hashSize, 2)
        XCTAssertEqual(p.path, [Data([0x40, 0x41])])
        XCTAssertTrue(p.transmitted(by: key))
        XCTAssertEqual(p.payload, Data([7, 7, 7, 7]))
    }

    func testRejectsGarbage() {
        XCTAssertNil(MeshCorePacket(Data([0x11])))
        XCTAssertNil(MeshCorePacket(Data([0x11, 0x3F, 1])), "path longer than the packet")
        XCTAssertNil(MeshCorePacket(Data([0x11, 0xC1, 1, 2, 3, 4])), "hash size 4 is reserved")
    }

    func testDirectResponseFromTheRepeaterCounts() throws {
        // direct (2) | response (1 << 2) = 0x06, no path left, payload: dest hash 0x99, src hash 0x40 (our key), MAC, data
        let p = try XCTUnwrap(MeshCorePacket(Data([0x06, 0x00, 0x99, 0x40, 1, 2, 3, 4])))
        XCTAssertEqual(p.sourceHash, 0x40)
        XCTAssertTrue(p.transmitted(by: key))
        XCTAssertFalse(p.transmitted(by: Data([0x41] + Array(key.dropFirst()))))
        // still being relayed toward us: not the repeater's own signal
        let relayed = try XCTUnwrap(MeshCorePacket(Data([0x06, 0x01, 0x55, 0x99, 0x40, 1, 2])))
        XCTAssertFalse(relayed.transmitted(by: key))
    }
}
