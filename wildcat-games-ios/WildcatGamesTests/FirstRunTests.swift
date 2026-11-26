import CoreLocation
import WildcatRadioCore
import XCTest
@testable import WildcatGames

@MainActor
final class FirstRunTests: XCTestCase {
    // MARK: PendingScan

    func testPendingScanStopsOnceTheCallTakes() async throws {
        let pending = PendingScan()
        var tries = 0
        pending.start(every: .milliseconds(10)) {
            tries += 1
            return tries == 3   // Bluetooth came up on the third try
        }
        XCTAssertTrue(pending.isWaiting)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(pending.isWaiting)
        XCTAssertEqual(tries, 3)
    }

    func testPendingScanDoneAtOnceDoesNotWait() {
        let pending = PendingScan()
        pending.start { true }
        XCTAssertFalse(pending.isWaiting)
    }

    func testPendingScanGivesUpAndCancels() async throws {
        let pending = PendingScan()
        var tries = 0
        pending.start(every: .milliseconds(10), for: .milliseconds(50)) { tries += 1; return false }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(pending.isWaiting, "times out")
        let after = tries
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tries, after, "no tries after giving up")

        pending.start(every: .milliseconds(10)) { false }
        pending.cancel()
        XCTAssertFalse(pending.isWaiting)
    }

    // MARK: LocationAccess

    func testLocationAccess() {
        XCTAssertEqual(LocationAccess(.notDetermined), .notAsked)
        XCTAssertEqual(LocationAccess(.authorizedWhenInUse), .allowed)
        XCTAssertEqual(LocationAccess(.denied), .denied)
        XCTAssertEqual(LocationAccess(.restricted), .restricted)
        XCTAssertNil(LocationAccess.allowed.problem)
        XCTAssertNotNil(LocationAccess.restricted.problem, "restricted never reads as waiting for GPS")
    }

    // MARK: MeshCore channel QR

    func testMeshCoreChannelCodes() {
        let hex = "8b3387e9c5cdea6ac9e5edbaa115cd72"
        XCTAssertEqual(MeshCoreChannelCode(scanned: hex)?.key.count, 16)
        XCTAssertNil(MeshCoreChannelCode(scanned: hex)?.name)
        let link = MeshCoreChannelCode(scanned: "meshcore://channel/add?name=WGBRIDGE&secret=\(hex)")
        XCTAssertEqual(link?.name, "WGBRIDGE")
        XCTAssertEqual(link?.key, MeshCoreChannelCode(scanned: hex)?.key)
        XCTAssertNil(MeshCoreChannelCode(scanned: "https://meshtastic.org/e/#CgMSAQE"))
        XCTAssertNil(MeshCoreChannelCode(scanned: "wildcat://hunt/abc"))
        XCTAssertNil(MeshCoreChannelCode(scanned: String(hex.dropLast())))
        XCTAssertNil(MeshCoreChannelCode(scanned: "８b3387e9c5cdea6ac9e5edbaa115cd72"), "fullwidth digits aren't hex")
    }

    // MARK: Practice nodes

    func testPracticeNodesSitAroundYou() {
        let me = LatLon(lat: 51.5, lon: -0.12)
        let spots = PracticeMesh.placements(around: me)
        XCTAssertEqual(spots.count, 3)
        for p in spots {
            let d = Geo.distance(me, p)
            XCTAssertGreaterThan(d, 150, "not found on the spot")
            XCTAssertLessThan(d, 2000, "within Daily Fox's smallest range")
        }
        XCTAssertEqual(PracticeMesh.placements(around: nil).first, LatLon(lat: 37.7712, lon: -122.4815))
    }

    func testPracticeMeshUsesTheCentre() {
        let me = LatLon(lat: 40.0, lon: -105.0)
        let mesh = PracticeMesh(center: me)
        let placed = mesh.session.nodes.values.compactMap(\.position)
        XCTAssertEqual(placed.count, 3)
        XCTAssertTrue(placed.allSatisfy { Geo.distance(me, LatLon(lat: $0.latitude, lon: $0.longitude)) < 2000 })
    }
}
