import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// "Heard on air" wording: rows, counts, the detail fields and the autotest's log line.
final class RNodeHeardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_791_500_000)
    let dest = Data([0x53, 0x80, 0x2f, 0xdd, 0xce, 0xca, 0xc9, 0x9e, 0x39, 0xbf, 0x61, 0x44, 0xe3, 0xe1, 0xde, 0x1d])

    /// A header as the manual lays it out: flags, hops, [transport id], destination, context, data.
    func packet(_ flags: UInt8, hops: UInt8 = 0, transport: Bool = false, context: UInt8 = 0, dataLength: Int = 150) -> Data {
        var d = Data([flags, hops])
        if transport { d += Data(repeating: 0xAA, count: 16) }
        d += dest
        d.append(context)
        d += Data(repeating: 0x11, count: dataLength)
        return d
    }

    func heard(_ raw: Data, rssi: Int? = -101, snr: Double? = 6.5, airtime: Int? = nil) -> RNodeSession.HeardPacket {
        RNodeSession.HeardPacket(id: 1, at: t0, size: raw.count, rssi: rssi, snr: snr, reading: ReticulumPacket.read(raw), airtimeMs: airtime)
    }

    func testDestinationAndHops() {
        XCTAssertEqual(RNodeHeardFormat.destination(dest), "<53802fdd…>")
        XCTAssertEqual(RNodeHeardFormat.fullHash(dest), "<53802fddcecac99e39bf6144e3e1de1d>")
        XCTAssertEqual(RNodeHeardFormat.destination(Data([1, 2])), "<0102>")
        XCTAssertEqual(RNodeHeardFormat.hops(0), "direct")
        XCTAssertEqual(RNodeHeardFormat.hops(1), "1 hop")
        XCTAssertEqual(RNodeHeardFormat.hops(4), "4 hops")
    }

    func testRowSubtitles() {
        // An announce heard directly.
        XCTAssertEqual(RNodeHeardFormat.subtitle(heard(packet(0x01))), "single · direct · 169 B · −101 dBm · SNR 6.5")
        // Relayed: header type 2 says it's in transport.
        XCTAssertEqual(RNodeHeardFormat.subtitle(heard(packet(0x51, hops: 2, transport: true), rssi: nil, snr: nil)),
                       "via transport · 2 hops · 185 B")
        // A keepalive on a link names its context.
        XCTAssertEqual(RNodeHeardFormat.subtitle(heard(packet(0x0C, context: 0xFA, dataLength: 1), snr: nil)),
                       "link · direct · keepalive · 20 B · −101 dBm")
        XCTAssertEqual(RNodeHeardFormat.subtitle(heard(Data(repeating: 0x80, count: 40), rssi: nil, snr: nil)), "masked · 40 B")
        XCTAssertEqual(RNodeHeardFormat.subtitle(heard(Data([1, 2, 3]), rssi: nil, snr: -2.25)), "not Reticulum · 3 B · SNR −2.25")
        // Rows: RSSI only.
        XCTAssertEqual(RNodeHeardFormat.subtitle(heard(packet(0x01)), snr: false), "single · direct · 169 B · −101 dBm")
        XCTAssertEqual(RNodeHeardFormat.subtitle(heard(Data([1, 2, 3]), rssi: nil, snr: -2.25), snr: false), "not Reticulum · 3 B")
    }

    func testCountsAndOtherLines() {
        var s = RNodeSession()
        XCTAssertEqual(RNodeHeardFormat.countsLine(s.heardCounts, since: nil), "Nothing heard yet.")
        for raw in [packet(0x01), packet(0x01), packet(0x00), packet(0x08, dataLength: 32), Data([9]), Data(repeating: 0x80, count: 30)] {
            _ = s.handle(.data(raw), now: t0)
        }
        let c = s.heardCounts
        XCTAssertEqual(c.total, 6)
        XCTAssertEqual(RNodeHeardFormat.otherCount(c), 2, "the plain-destination data packet counts as data")
        let line = RNodeHeardFormat.countsLine(c, since: t0)
        XCTAssertTrue(line.hasPrefix("2 announces · 2 data · 2 other, since "), line)
        XCTAssertEqual(RNodeHeardFormat.otherLine(c), "1 masked, 1 unreadable")
        XCTAssertEqual(RNodeHeardFormat.otherLine(RNodeSession.HeardCounts()), "links, proofs, paths")
        XCTAssertEqual(RNodeHeardFormat.otherLine(RNodeSession.HeardCounts([.pathRequest: 3, .proof: 1, .linkRequest: 2])),
                       "3 path requests, 2 links, +1 more")
        XCTAssertEqual(RNodeHeardFormat.otherLine(RNodeSession.HeardCounts([.proof: 1, .linkRequest: 2])), "2 links, 1 proof")
        XCTAssertEqual(RNodeHeardFormat.destinationsLine(0), "none yet")
        XCTAssertEqual(RNodeHeardFormat.destinationsLine(1), "from 1 destination")
        XCTAssertEqual(RNodeHeardFormat.destinationsLine(3), "from 3 destinations")
        s.clearHeard(now: t0)
        XCTAssertTrue(RNodeHeardFormat.countsLine(s.heardCounts, since: t0).hasPrefix("Nothing heard since "))
        XCTAssertEqual(RNodeHeardFormat.sinceLine(nil, total: 0), "Every packet, with what its header says")
    }

    func testFiltersCoverEveryKindOnce() {
        let union = RNodeHeardFormat.Filter.allCases.reduce(Set<ReticulumPacket.Kind>()) { $0.union($1.kinds) }
        XCTAssertEqual(union, Set(ReticulumPacket.Kind.allCases))
        XCTAssertTrue(RNodeHeardFormat.Filter.all.kinds.isEmpty, "all = no filter")
        XCTAssertEqual(RNodeHeardFormat.Filter.announces.kinds, [.announce])
    }

    func testDetailFields() {
        let h = heard(packet(0x51, hops: 1, transport: true, context: 0x0B), airtime: 553)
        let f = Dictionary(RNodeHeardFormat.fields(h).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(f["Kind"], "Announce")
        XCTAssertEqual(f["Destination"], "53802fddcecac99e39bf6144e3e1de1d")
        XCTAssertEqual(f["Header"], "type 2 (in transport)")
        XCTAssertEqual(f["Transport"], String(repeating: "aa", count: 16))
        XCTAssertEqual(f["Propagation"], "transport")
        XCTAssertEqual(f["Context"], "path response (0x0b)")
        XCTAssertEqual(f["Data"], "150 B")
        XCTAssertEqual(f["Size"], "185 B · 1 frame")
        XCTAssertEqual(f["Airtime"], "≈ 553 ms")
        XCTAssertEqual(f["RSSI"], "−101 dBm")
        XCTAssertEqual(RNodeHeardFormat.highlights(h), [2..<35])
        // A long packet went as two LoRa frames; an unreadable one says why.
        let long = heard(packet(0x08, dataLength: 400))
        XCTAssertEqual(Dictionary(RNodeHeardFormat.fields(long).map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })["Size"],
                       "419 B · 2 frames")
        let bad = heard(Data([0x00, 0xC8] + Array(repeating: UInt8(1), count: 30)))
        XCTAssertEqual(RNodeHeardFormat.fields(bad).first?.value, "200 hops: past Reticulum's limit of 128")
        XCTAssertTrue(RNodeHeardFormat.headline(bad).hasPrefix("Not a Reticulum packet: 200 hops"))
        XCTAssertTrue(RNodeHeardFormat.highlights(bad).isEmpty)
    }

    func testHeadlinesNameTheDestination() {
        XCTAssertEqual(RNodeHeardFormat.headline(heard(packet(0x01))),
                       "<53802fddcecac99e39bf6144e3e1de1d> told the network it exists and how to reach it, heard directly.")
        XCTAssertTrue(RNodeHeardFormat.headline(heard(packet(0x51, hops: 3, transport: true))).hasSuffix("after 3 hops."))
        XCTAssertEqual(RNodeHeardFormat.headline(heard(packet(0x00))), "Encrypted data for <53802fddcecac99e39bf6144e3e1de1d>.")
        XCTAssertEqual(RNodeHeardFormat.headline(heard(packet(0x0C))), "Encrypted data for <53802fddcecac99e39bf6144e3e1de1d> (a link).")
        XCTAssertEqual(RNodeHeardFormat.headline(heard(packet(0x02))), "Someone is opening an encrypted link to <53802fddcecac99e39bf6144e3e1de1d>.")
    }

    #if DEBUG
    func testRadioLockTextNamesWhatIsStillUnset() {
        var p = RNode.RadioParameters(frequencyHz: 914_875_000, codingRate: 5)
        let text = RNodeFormat.radioLockText(p)
        XCTAssertTrue(text.contains("its bandwidth, spreading factor and transmit power yet"), text)
        XCTAssertFalse(text.contains("coding rate"), "the firmware doesn't need it for the switch")
        p.bandwidthHz = 125_000
        p.spreadingFactor = 8
        XCTAssertTrue(RNodeFormat.radioLockText(p).contains("its transmit power yet"))
        p.txPower = 7
        XCTAssertTrue(p.canTurnOn)
        XCTAssertEqual(RNodeFormat.radioLockText(p), "")
    }

    func testAutoTestLogLine() {
        XCTAssertEqual(RNodeAutoTest.describe(heard(packet(0x01))),
                       "Announce <53802fdd…> single · direct · 169 B · −101 dBm · SNR 6.5 · dest 53802fddcecac99e39bf6144e3e1de1d")
        XCTAssertEqual(RNodeAutoTest.describe(heard(Data([7]), rssi: nil, snr: nil)),
                       "Unreadable not Reticulum · 1 B · 1 byte, too short for a Reticulum header (20+)")
        XCTAssertEqual(RNodeAutoTest.listenSettings.frequencyHz, 914_875_000)
    }
    #endif
}
