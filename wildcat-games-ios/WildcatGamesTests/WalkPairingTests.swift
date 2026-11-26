import XCTest
@testable import WildcatGames

final class WalkPairingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func fix(_ dt: TimeInterval, lat: Double = 39.10, acc: Double = 8) -> WalkPairing.Fix {
        .init(time: t0 + dt, latitude: lat, longitude: -84.51, accuracy: acc)
    }

    func testUplinkPairsWithTheNearestFix() {
        var p = WalkPairing()
        p.add(fix(0, lat: 39.08))
        p.add(fix(10, lat: 39.09))
        XCTAssertTrue(p.beaconSent(at: t0 + 10))
        let point = p.denHeard(at: t0 + 12, snr: 4.5, rssi: -98, hops: 0)
        XCTAssertEqual(point?.latitude, 39.09)
        XCTAssertEqual(point?.kind, .uplink)
        XCTAssertEqual(point?.quality, .strong)
        XCTAssertTrue(p.pending.isEmpty)
        XCTAssertNil(p.denHeard(at: t0 + 12, snr: 4.5, rssi: -98, hops: 0), "same sample twice")
    }

    func testRelayedMeasurementsAreNotCoverage() {
        var p = WalkPairing()
        p.add(fix(0))
        XCTAssertNil(p.denHeard(at: t0 + 1, snr: 3, rssi: -90, hops: 2))
    }

    func testUnheardBeaconBecomesAMiss() {
        var p = WalkPairing()
        p.add(fix(0))
        XCTAssertTrue(p.beaconSent(at: t0))
        XCTAssertTrue(p.expire(now: t0 + 30).isEmpty)
        let missed = p.expire(now: t0 + 50)
        XCTAssertEqual(missed.map(\.kind), [.missed])
        XCTAssertEqual(missed.first?.quality, CoveragePoint.Quality.none)
    }

    func testBadOrStaleFixesAreIgnored() {
        var p = WalkPairing()
        p.add(fix(0, acc: 200))
        XCTAssertFalse(p.beaconSent(at: t0), "no usable fix")
        p.add(fix(0))
        XCTAssertFalse(p.beaconSent(at: t0 + 60), "fix too old")
    }

    func testQualityThresholds() {
        func q(_ snr: Double?, _ rssi: Int?) -> CoveragePoint.Quality {
            CoveragePoint(time: t0, latitude: 0, longitude: 0, kind: .uplink, snr: snr, rssi: rssi).quality
        }
        XCTAssertEqual(q(5, -90), .strong)
        XCTAssertEqual(q(-3, -105), .ok)
        XCTAssertEqual(q(-12, -100), .weak)
        XCTAssertEqual(q(2, -118), .weak)
    }

    func testStoreRoundTripAndCSV() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("walks-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var w = CoverageWalk(name: "Test", started: t0, node: "!a", den: "!b", beaconInterval: 30)
        w.points = [CoveragePoint(time: t0, latitude: 1, longitude: 2, kind: .uplink, snr: 3, rssi: -90)]
        WalkStore.save(w, in: dir)
        XCTAssertEqual(WalkStore.load(in: dir), [w])
        XCTAssertTrue(WalkStore.csv(w).contains(",uplink,3.0,-90"))
    }
}
