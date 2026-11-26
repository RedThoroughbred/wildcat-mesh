import XCTest
@testable import WildcatGames

/// The pure logic behind the AB instruments: signal grading, meter segments,
/// hex dumps and ticker ages.
final class DesignSystemTests: XCTestCase {
    func testSignalBarsFromSNR() {
        XCTAssertEqual(SignalGrade.bars(snr: 12.2, rssi: nil), 5)
        XCTAssertEqual(SignalGrade.bars(snr: 9.5, rssi: nil), 4)
        XCTAssertEqual(SignalGrade.bars(snr: 6.75, rssi: nil), 3)
        XCTAssertEqual(SignalGrade.bars(snr: 3.5, rssi: nil), 2)
        XCTAssertEqual(SignalGrade.bars(snr: -3.25, rssi: nil), 1)
        XCTAssertEqual(SignalGrade.bars(snr: -30, rssi: nil), 1, "anything heard is at least one bar")
    }

    func testSNRWinsOverRSSIAndRSSIIsTheFallback() {
        XCTAssertEqual(SignalGrade.bars(snr: -3.25, rssi: -60), 1)
        XCTAssertEqual(SignalGrade.bars(snr: nil, rssi: -85), 5)
        XCTAssertEqual(SignalGrade.bars(snr: nil, rssi: -104), 3)
        XCTAssertEqual(SignalGrade.bars(snr: nil, rssi: -130), 1)
        XCTAssertEqual(SignalGrade.bars(snr: nil, rssi: nil), 0)
        XCTAssertEqual(SignalGrade.bars(snr: .nan, rssi: -104), 3, "a NaN SNR from the air falls back to RSSI")
        XCTAssertEqual(SignalGrade.bars(snr: .infinity, rssi: nil), 0)
    }

    func testGradeWords() {
        XCTAssertEqual(SignalGrade.grade(snr: 12.2, rssi: nil), .strong)
        XCTAssertEqual(SignalGrade.grade(snr: 6.75, rssi: nil), .ok)
        XCTAssertEqual(SignalGrade.grade(snr: -3.25, rssi: nil), .weak)
        XCTAssertEqual(SignalGrade.grade(snr: nil, rssi: nil), .none)
        XCTAssertEqual(SignalGrade.weak.word, "weak")
        XCTAssertLessThan(SignalGrade.weak, SignalGrade.strong)
    }

    func testSegmentLitCount() {
        XCTAssertEqual(SegmentMeter.litCount(value: 0, segments: 5), 0)
        XCTAssertEqual(SegmentMeter.litCount(value: 0.01, segments: 5), 1, "any signal lights one")
        XCTAssertEqual(SegmentMeter.litCount(value: 0.82, segments: 10), 8)
        XCTAssertEqual(SegmentMeter.litCount(value: 1.7, segments: 5), 5, "clamped")
        XCTAssertEqual(SegmentMeter.litCount(value: -1, segments: 5), 0)
        XCTAssertEqual(SegmentMeter.litCount(value: .nan, segments: 5), 0)
        XCTAssertEqual(SegmentMeter.litCount(value: 0.5, segments: 0), 0)
    }

    func testSNRFraction() {
        XCTAssertEqual(SegmentMeter.snrFraction(-20), 0)
        XCTAssertEqual(SegmentMeter.snrFraction(0), 0.5)
        XCTAssertEqual(SegmentMeter.snrFraction(40), 1)
        XCTAssertEqual(SegmentMeter.litCount(value: SegmentMeter.snrFraction(-3.25), segments: 20), 8)
        XCTAssertEqual(SegmentMeter.snrFraction(.nan), 0)
    }

    func testHexDumpLines() {
        let data = Data((0..<20).map { UInt8($0) })
        let lines = HexDump.lines(data, perRow: 16)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].offset, 16)
        XCTAssertEqual(lines[1].bytes, [16, 17, 18, 19])
        XCTAssertEqual(HexDump.lines(Data(), perRow: 16), [])
        XCTAssertEqual(HexDump.lines(data, perRow: 0).count, 20, "a bad row size never traps")
        XCTAssertEqual(HexDump.lines(data, perRow: 8, limit: 10).flatMap(\.bytes).count, 10)
    }

    func testHexDumpOfASliceWithNonZeroStartIndex() {
        let whole = Data([0xaa, 0xbb, 0xcc, 0xdd])
        let slice = whole[2...]
        XCTAssertEqual(HexDump.lines(slice).first?.bytes, [0xcc, 0xdd])
        XCTAssertEqual(HexDump.string(slice), "cc dd")
    }

    func testHexFormatting() {
        XCTAssertEqual(HexDump.hex(0x0f), "0f")
        XCTAssertEqual(HexDump.hex(0xa4), "a4")
        XCTAssertEqual(HexDump.offset(0x10), "10")
        XCTAssertEqual(HexDump.offset(0x1f0, width: 3), "1f0")
        XCTAssertEqual(HexDump.offset(5, width: 3), "005")
    }

    func testTickerAge() {
        let now = Date()
        XCTAssertEqual(PacketTicker.age(now.addingTimeInterval(-4), now: now), "4s")
        XCTAssertEqual(PacketTicker.age(now.addingTimeInterval(-190), now: now), "3m")
        XCTAssertEqual(PacketTicker.age(now.addingTimeInterval(-7300), now: now), "2h")
        XCTAssertEqual(PacketTicker.age(now.addingTimeInterval(10), now: now), "0s", "clock skew never goes negative")
    }

    func testKeyValueCopyText() {
        let items = [KeyValueItem(key: "type", value: "REPEATER"), KeyValueItem(key: "fw", value: "1.8.2")]
        XCTAssertEqual(KeyValueGrid.text(items), "type: REPEATER\nfw: 1.8.2")
    }
}
