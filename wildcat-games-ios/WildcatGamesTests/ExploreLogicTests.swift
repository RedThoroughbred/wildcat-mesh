import XCTest
@testable import WildcatGames

final class ExploreLogicTests: XCTestCase {
    private let den = LatLon(lat: 39.1031, lon: -84.512)
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func point(_ p: LatLon, _ kind: CoveragePoint.Kind, snr: Double? = 5, rssi: Int? = -90) -> CoveragePoint {
        CoveragePoint(time: t0, latitude: p.lat, longitude: p.lon, kind: kind, snr: snr, rssi: rssi)
    }

    func testGeo() {
        let north = Geo.offset(den, distance: 1000, bearing: 0)
        XCTAssertEqual(Geo.distance(den, north), 1000, accuracy: 1)
        let b = Geo.bearing(den, north)
        XCTAssertLessThan(min(b, 360 - b), 0.5, "due north (0° and 360° are the same)")
        XCTAssertEqual(Geo.bearing(den, Geo.offset(den, distance: 500, bearing: 135)), 135, accuracy: 0.5)
        XCTAssertEqual(Geo.compass(44), "NE")
        XCTAssertEqual(Geo.compass(350), "N")
    }

    func testSignalBearingPointsUphill() {
        // Signal gets stronger towards the east.
        var s: [(LatLon, Double)] = []
        for (i, b) in [0.0, 90, 180, 270, 45].enumerated() {
            let p = Geo.offset(den, distance: 40, bearing: b)
            let east = 40 * sin(b * .pi / 180)
            s.append((p, 50 + east / 2 + Double(i % 2) * 0.1))
        }
        let b = Geo.signalBearing(s)
        XCTAssertNotNil(b)
        XCTAssertEqual(b ?? 0, 90, accuracy: 5)
    }

    func testHexGridIsStableAndCentred() {
        let g = HexGrid(size: 90, refLat: 38.9)
        let k = g.key(for: den)
        XCTAssertEqual(g.key(for: g.center(k)), k)
        XCTAssertLessThan(Geo.distance(g.center(k), den), 95)
        XCTAssertEqual(g.corners(k).count, 6)
        XCTAssertNotEqual(g.key(for: Geo.offset(den, distance: 400, bearing: 0)), k)
    }

    func testTerritoryKeepsTheBestLinkPerTile() {
        let g = HexGrid(size: 90, refLat: 38.9)
        let far = Geo.offset(den, distance: 1000, bearing: 90)
        let t = Territory(grid: g, points: [point(den, .missed), point(den, .uplink, snr: 6),
                                            point(far, .missed), point(far, .downlink)])
        XCTAssertEqual(t.explored, 2)
        XCTAssertEqual(t.tiles[g.key(for: den)]?.best, .strong)
        XCTAssertEqual(t.dead, 1)
        XCTAssertGreaterThan(t.explored(within: 2000, of: den), 0)
    }

    func testFrontierKeepsTheFarthestPerSector() {
        let near = Geo.offset(den, distance: 500, bearing: 10)
        let far = Geo.offset(den, distance: 2500, bearing: 12)
        let east = Geo.offset(den, distance: 800, bearing: 95)
        let f = Frontier(den: den, points: [point(near, .uplink), point(far, .uplink), point(east, .uplink),
                                            point(Geo.offset(den, distance: 9000, bearing: 200), .missed)])
        XCTAssertEqual(f.reach.count, 2)
        XCTAssertEqual(f.farthest, 2500, accuracy: 2)
        XCTAssertEqual(f.outline.count, 2)
    }

    func testNodedex() {
        var dex = Nodedex()
        let node = Geo.offset(den, distance: 6000, bearing: 30)
        XCTAssertTrue(dex.heard(id: "!a", shortName: "A", longName: nil, at: t0, me: den, nodePosition: node, snr: 2, rssi: -110))
        XCTAssertFalse(dex.heard(id: "!a", shortName: nil, longName: "Alpha", at: t0 + 60, me: den, nodePosition: nil, snr: 5, rssi: -120))
        let e = dex.entries["!a"]!
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.bestSNR, 5)
        XCTAssertEqual(e.bestRSSI, -110)
        XCTAssertEqual(e.longName, "Alpha")
        XCTAssertEqual(e.rarity, .rare)
        XCTAssertEqual(DexEntry.Rarity(distance: 20_000), .legendary)
        XCTAssertEqual(DexEntry.Rarity(distance: nil), .common)
    }

    func testDailyFoxPickIsStableAndFiltered() {
        let now = t0
        let cands = (0..<6).map { i in
            DailyFox.Candidate(id: "!n\(i)", name: "N\(i)", position: Geo.offset(den, distance: Double(200 + i * 800), bearing: 0),
                               lastHeard: now - 3600)
        } + [DailyFox.Candidate(id: "!stale", name: "S", position: Geo.offset(den, distance: 1000, bearing: 90),
                                lastHeard: now - 5 * 86_400)]
        let a = DailyFox.pick(from: cands, me: den, day: "2026-09-27", maxDistance: 5000, now: now)
        let b = DailyFox.pick(from: cands.reversed(), me: den, day: "2026-09-27", maxDistance: 5000, now: now)
        XCTAssertEqual(a, b, "order doesn't matter")
        XCTAssertNotEqual(a?.id, "!n0", "too close")
        XCTAssertNotEqual(a?.id, "!stale")
        XCTAssertLessThanOrEqual(Geo.distance(den, a!.position), 5000)
        let other = (0..<20).compactMap { DailyFox.pick(from: cands, me: den, day: "2026-09-27", reroll: $0, maxDistance: 5000, now: now)?.id }
        XCTAssertGreaterThan(Set(other).count, 1, "rerolls change the fox")
        XCTAssertNil(DailyFox.pick(from: cands, me: den, day: "x", maxDistance: 100, now: now))
    }

    func testDailyFoxScoreAndStreak() {
        var run = DailyFoxRun(day: "2026-09-27", foxID: "!a", foxName: "A", foxPosition: den, started: t0)
        XCTAssertEqual(run.score, 0)
        run.found = t0 + 25 * 60
        run.hints = 1
        run.pings = 7
        XCTAssertEqual(run.score, 1000 - 100 - 150 - 40)
        let runs = ["2026-09-25", "2026-09-26", "2026-09-27", "2026-09-20"].map {
            DailyFoxRun(day: $0, foxID: "!a", foxName: "A", foxPosition: den, started: t0, found: t0)
        }
        XCTAssertEqual(DailyFox.streak(runs, today: "2026-09-27"), 3)
        XCTAssertEqual(DailyFox.streak(runs, today: "2026-09-28"), 3, "today not played yet")
        XCTAssertEqual(DailyFox.streak(runs, today: "2026-09-30"), 0)
        XCTAssertEqual(DailyFox.distanceHint(1500), "It's 1 to 2 km away.")
    }

    func testAchievements() {
        var s = ExploreStats()
        XCTAssertTrue(Achievement.all.filter { $0.isMet(s) }.isEmpty)
        s.uplinks = 1
        s.farthest = 3200
        s.streak = 3
        let met = Set(Achievement.all.filter { $0.isMet(s) }.map(\.id))
        XCTAssertEqual(met, ["first-contact", "range-1k", "range-3k", "fox-streak-3"])
        XCTAssertEqual(Set(Achievement.all.map(\.id)).count, Achievement.all.count, "unique ids")
    }
}
