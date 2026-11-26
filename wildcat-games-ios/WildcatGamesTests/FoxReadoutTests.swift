import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// The words and numbers on the Fox Hunt instrument.
final class FoxReadoutTests: XCTestCase {
    private let fox = NodeNum(0x9E76_6B18)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A tracker fed direct readings (seconds after t0, SNR, RSSI).
    private func samples(_ readings: [(TimeInterval, Float?, Int?)]) -> [FoxTracker.Sample] {
        var tracker = FoxTracker(fox: fox)
        for (i, r) in readings.enumerated() {
            let p = MeshPacket(from: fox, to: .broadcast, channel: 0, id: UInt32(i + 1), rxTime: t0, rxSNR: r.1,
                               rxRSSI: r.2, hopLimit: 3, hopStart: 3, viaMQTT: false, relayNode: nil,
                               portnum: .position, rawPortnum: 3, text: nil, position: nil, isEncrypted: false)
            tracker.ingest(p, at: t0.addingTimeInterval(r.0))
        }
        return tracker.samples
    }

    func testUnitPrefersSNR() {
        let s = samples([(0, -3.25, -112), (5, nil, -100)])
        XCTAssertEqual(FoxReadout.unit(for: s.first), .snr)
        XCTAssertEqual(FoxReadout.unit(for: s.last), .rssi, "no SNR: RSSI leads")
        XCTAssertEqual(FoxReadout.unit(for: nil), .rssi)
    }

    func testChangeOverThirtySeconds() {
        let s = samples([(0, -8, nil), (20, -6, nil), (40, -5, nil), (60, -3.5, nil)])
        // Latest at 60 s; the newest reading at least 30 s older is the one at 20 s.
        XCTAssertEqual(FoxReadout.change(s, unit: .snr) ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(FoxReadout.warmth(change: 2.5, unit: .snr), .warmer)
        XCTAssertEqual(FoxReadout.warmth(change: -1.5, unit: .snr), .colder)
        XCTAssertEqual(FoxReadout.warmth(change: 1, unit: .snr), .steady)
        XCTAssertEqual(FoxReadout.warmth(change: 2, unit: .rssi), .steady, "RSSI needs 3 dB")
        XCTAssertEqual(FoxReadout.warmth(change: nil, unit: .snr), .none)
    }

    func testChangeFallsBackToOldestAndNeedsTwo() {
        let s = samples([(0, -8, nil), (10, -6, nil)])
        XCTAssertEqual(FoxReadout.change(s, unit: .snr) ?? 0, 2, accuracy: 0.001)
        XCTAssertNil(FoxReadout.change(Array(s.prefix(1)), unit: .snr))
        XCTAssertNil(FoxReadout.change([], unit: .snr))
        XCTAssertNil(FoxReadout.change(s, unit: .rssi), "no RSSI in these readings")
    }

    func testTrendWindowAndThinning() {
        let s = samples((0..<60).map { (Double($0) * 5, Float(-10 + $0 % 7), nil) })
        let t = FoxReadout.trend(s, unit: .snr)
        XCTAssertTrue(t.windowed)
        XCTAssertEqual(t.values.count, 24, "25 readings in 2 min, thinned to 24 bars")
        // A fox heard once a minute: fewer than two in the window, so the last readings.
        let sparse = samples([(0, -9, nil), (300, -7, nil), (600, -5, nil)])
        let st = FoxReadout.trend(sparse, unit: .snr)
        XCTAssertFalse(st.windowed)
        XCTAssertEqual(st.values, [-9, -7, -5])
        XCTAssertEqual(FoxReadout.trend([], unit: .snr).values, [])
    }

    func testThinKeepsPeaks() {
        XCTAssertEqual(FoxReadout.thin([1, 5, 2, 3, 9, 4], to: 3), [5, 3, 9])
        XCTAssertEqual(FoxReadout.thin([1, 2], to: 5), [1, 2])
        XCTAssertEqual(FoxReadout.thin([1, 2], to: 0), [1, 2], "a bad count never traps")
    }

    func testMeterFraction() {
        XCTAssertEqual(FoxReadout.meterFraction(-20, unit: .snr), 0)
        XCTAssertEqual(FoxReadout.meterFraction(0, unit: .snr), 0.5)
        XCTAssertEqual(FoxReadout.meterFraction(-3.25, unit: .snr), 0.41875, accuracy: 0.0001)
        XCTAssertEqual(FoxReadout.meterFraction(-45, unit: .rssi), 1)
        XCTAssertEqual(FoxReadout.meterFraction(-200, unit: .rssi), 0)
        XCTAssertEqual(FoxReadout.meterFraction(nil, unit: .snr), 0)
        XCTAssertEqual(FoxReadout.meterFraction(.nan, unit: .snr), 0)
    }

    func testFormattingUsesTrueMinus() {
        XCTAssertEqual(FoxReadout.format(-3.25, unit: .snr), "−3.25")
        XCTAssertEqual(FoxReadout.format(-1, unit: .snr), "−1.0")
        XCTAssertEqual(FoxReadout.format(1.5, unit: .snr, signed: true), "+1.5")
        XCTAssertEqual(FoxReadout.format(0, unit: .snr, signed: true), "0.0")
        XCTAssertEqual(FoxReadout.format(-112, unit: .rssi), "−112")
        XCTAssertEqual(FoxReadout.format(.infinity, unit: .rssi), "--")
    }

    func testClockAndAgo() {
        XCTAssertEqual(FoxReadout.clock(761), "12:41")
        XCTAssertEqual(FoxReadout.clock(3723), "1:02:03")
        XCTAssertEqual(FoxReadout.clock(-5), "0:00")
        XCTAssertEqual(FoxReadout.clock(.nan), "0:00")
        XCTAssertEqual(FoxReadout.ago(0.4), "just now")
        XCTAssertEqual(FoxReadout.ago(4), "4 s ago")
        XCTAssertEqual(FoxReadout.ago(185), "3 min ago")
        XCTAssertEqual(FoxReadout.ago(7300), "2 h ago")
    }

    func testDirections() {
        XCTAssertEqual(FoxReadout.direction(47), "north-east")
        XCTAssertEqual(FoxReadout.direction(359), "north")
        XCTAssertEqual(FoxReadout.direction(-90), "west")
        XCTAssertEqual(FoxReadout.direction(.nan), "north")
        XCTAssertEqual(FoxReadout.degrees(47), "047°")
        XCTAssertEqual(FoxReadout.degrees(360), "000°")
        XCTAssertEqual(FoxReadout.degrees(-10), "350°")
    }

    func testInstruction() {
        let listening = FoxReadout.instruction(hasReading: false, warmth: .none, bearing: nil, listening: "Waiting.")
        XCTAssertEqual(listening.lead, "Listening.")
        XCTAssertEqual(listening.rest, "Waiting.")
        let warm = FoxReadout.instruction(hasReading: true, warmth: .warmer, bearing: 47, distance: 1200, listening: "")
        XCTAssertEqual(warm.lead, "Getting warmer.")
        XCTAssertTrue(warm.rest.hasPrefix("Head north-east (047°), about 1.2 km."))
        let close = FoxReadout.instruction(hasReading: true, warmth: .colder, bearing: nil, veryClose: true, listening: "")
        XCTAssertEqual(close.lead, "Very close.", "the referee's HOT wins")
    }
}
