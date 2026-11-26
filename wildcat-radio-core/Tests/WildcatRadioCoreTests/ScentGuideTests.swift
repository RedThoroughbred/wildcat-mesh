import XCTest
@testable import WildcatRadioCore

/// The GPS guide for hunters with no node: banded, noisy, from a moved spot.
final class ScentGuideTests: XCTestCase {
    typealias S = ScentGuide
    let spot = Coordinate(latitude: 38.9, longitude: -84.6)

    /// `metres` north (and east) of the spot.
    func near(_ north: Double, _ east: Double = 0) -> Coordinate {
        Coordinate(latitude: spot.latitude + north / 110_574,
                   longitude: spot.longitude + east / (111_320 * cos(spot.latitude * .pi / 180)))
    }

    /// A seeded generator, so the random offsets are the same every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testDistance() {
        XCTAssertEqual(S.distance(spot, near(100)), 100, accuracy: 1)
        XCTAssertEqual(S.distance(spot, near(0, 100)), 100, accuracy: 1)
        XCTAssertEqual(S.distance(spot, spot), 0)
        XCTAssertEqual(S.distance(Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 180)), .pi * 6_371_000, accuracy: 1)
    }

    func testTheSharedSpotIsMovedAndRounded() {
        let east = S.shared(spot, bearing: 90, distance: 10)
        XCTAssertEqual(east.latitude, 38.9)
        XCTAssertEqual(east.longitude, -84.5999, accuracy: 1e-9, "10 m east, on the grid")
        XCTAssertEqual(S.shared(spot, bearing: 0, distance: 0), spot, "already on the grid")
        // Never farther than the radius plus half a grid step each way.
        let far = S.shared(spot, bearing: 45, distance: 500)
        XCTAssertLessThanOrEqual(S.distance(far, spot), S.shareRadius + 8)
        XCTAssertEqual(S.shared(spot, bearing: .nan, distance: .infinity), spot)
        var g = Seeded(state: 7)
        for _ in 0..<500 {
            let o = S.randomOffset(using: &g)
            XCTAssertTrue((0..<360).contains(o.bearing))
            XCTAssertTrue((0...S.shareRadius).contains(o.distance))
            let s = S.shared(near(Double.random(in: -50...50, using: &g)), bearing: o.bearing, distance: o.distance)
            XCTAssertEqual((s.latitude / S.grid).rounded() * S.grid, s.latitude, accuracy: 1e-9)
        }
    }

    func testNoiseIsBounded() {
        XCTAssertEqual(S.noisyDistance(100, noise: 0), 100)
        XCTAssertEqual(S.noisyDistance(100, noise: 1), 125, accuracy: 1e-9)
        XCTAssertEqual(S.noisyDistance(100, noise: -1), 75, accuracy: 1e-9)
        XCTAssertEqual(S.noisyDistance(100, noise: 7), 125, accuracy: 1e-9, "clamped")
        XCTAssertEqual(S.noisyDistance(100, noise: .nan), 100)
        XCTAssertEqual(S.noisyDistance(5, noise: -1), 0, "never below zero")
    }

    func testBandsAndWords() {
        XCTAssertEqual(S.band(for: 0), 0)
        XCTAssertEqual(S.band(for: 24.9), 0)
        XCTAssertEqual(S.band(for: 25), 1)
        XCTAssertEqual(S.band(for: 399), 4)
        XCTAssertEqual(S.band(for: 5000), 5)
        XCTAssertEqual(S.Reading(band: 0).words, "within about 25 m")
        XCTAssertEqual(S.Reading(band: 2).words, "50–100 m")
        XCTAssertEqual(S.Reading(band: 5).words, "more than 400 m")
        XCTAssertEqual(S.Reading(band: 99).band, 5)
        XCTAssertEqual(S.Reading(band: -3).band, 0)
        XCTAssertTrue(S.Reading(band: 0).isHot)
        // Closer is a higher meter value, all of them 0–100.
        let scores = (0...5).map { S.Reading(band: $0).score }
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertTrue(scores.allSatisfy { (0...100).contains($0) })
    }

    func testReadings() {
        XCTAssertEqual(S.reading(phone: near(10), accuracy: 5, spot: spot, noise: 0)?.band, 0)
        XCTAssertEqual(S.reading(phone: near(70), accuracy: 5, spot: spot, noise: 0)?.band, 2)
        XCTAssertEqual(S.reading(phone: near(70), accuracy: 5, spot: spot, noise: 1)?.band, 2)
        XCTAssertEqual(S.reading(phone: near(70), accuracy: 5, spot: spot, noise: -1)?.band, 1, "noise can move a band")
        XCTAssertNil(S.reading(phone: near(10), accuracy: 80, spot: spot, noise: 0), "a poor fix says nothing")
        XCTAssertNil(S.reading(phone: near(10), accuracy: nil, spot: spot, noise: 0))
        XCTAssertNil(S.reading(phone: near(10), accuracy: -1, spot: spot, noise: 0))
        XCTAssertNil(S.reading(phone: near(10), accuracy: .nan, spot: spot, noise: 0))
    }

    func testTheGuideNeverPinsTheSpot() {
        // Anywhere within 10 m of the shared spot reads the same, whatever the noise: "hot".
        for n in stride(from: -1.0, through: 1, by: 0.25) {
            for (dn, de) in [(0.0, 0.0), (6, 0), (0, -8), (-5, 5)] {
                XCTAssertEqual(S.reading(phone: near(dn, de), accuracy: 5, spot: spot, noise: n)?.band, 0)
            }
        }
        // And 150 m off is never mistaken for close.
        for n in stride(from: -1.0, through: 1, by: 0.25) {
            XCTAssertGreaterThanOrEqual(S.reading(phone: near(150), accuracy: 5, spot: spot, noise: n)?.band ?? 0, 2)
        }
    }

    func testTrend() {
        XCTAssertEqual(S.trend(nil, .init(band: 3)), .none)
        XCTAssertEqual(S.trend(.init(band: 3), .init(band: 2)), .warmer)
        XCTAssertEqual(S.trend(.init(band: 2), .init(band: 4)), .colder)
        XCTAssertEqual(S.trend(.init(band: 2), .init(band: 2)), .steady)
    }
}
