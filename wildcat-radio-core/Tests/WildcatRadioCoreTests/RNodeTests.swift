import XCTest
@testable import WildcatRadioCore

/// The RNode host protocol against frames captured from a real RNode (RAK4631 WisBlock,
/// firmware 1.86) over USB serial: `Fixtures/rnode-wisblock.json`, made by `capture_rnode.py`.
/// The same bytes travel over Bluetooth LE.
final class RNodeTests: XCTestCase {
    struct Fixture: Decodable {
        struct Exchange: Decodable { let name: String; let sent: String; let received: String }
        struct Info: Decodable {
            let product: String, device_signature: String, firmware_version: String, hardware_revision: String
            let serial_number: String, modem_chip: String, frequency_range: String, max_tx_power: String
            let manufactured_local: String, device_mode: String
        }
        let rnodeconf_info: Info
        let exchanges: [Exchange]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "rnode-wisblock", withExtension: "json")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").compactMap { UInt8($0, radix: 16) })
    }

    func exchange(_ name: String) -> Fixture.Exchange { Self.fixture.exchanges.first { $0.name == name }! }

    func frames(_ name: String) -> [RNode.Frame] {
        var d = RNode.Decoder()
        return d.feed(bytes(exchange(name).received))
    }

    // MARK: KISS framing

    func testCommandsAreTheBytesRnodeconfSends() {
        XCTAssertEqual(RNode.Command.detect.data, bytes("c0 08 73 c0"))
        XCTAssertEqual(RNode.Command.readEEPROM.data, bytes(exchange("rom_read").sent))
        XCTAssertEqual(RNode.Command.getFrequency.data, bytes(exchange("frequency").sent))
        XCTAssertEqual(RNode.Command.getBandwidth.data, bytes(exchange("bandwidth").sent))
        XCTAssertEqual(RNode.Command.getTxPower.data, bytes(exchange("txpower").sent))
        XCTAssertEqual(RNode.Command.getSpreadingFactor.data, bytes(exchange("spreading_factor").sent))
        XCTAssertEqual(RNode.Command.getCodingRate.data, bytes(exchange("coding_rate").sent))
        XCTAssertEqual(RNode.Command.getRadioState.data, bytes(exchange("radio_state").sent))
        XCTAssertEqual(RNode.Command.statRX.data, bytes(exchange("stat_rx").sent))
        XCTAssertEqual(RNode.Command.statTX.data, bytes(exchange("stat_tx").sent))
        XCTAssertEqual(RNode.Command.statRSSI.data, bytes(exchange("stat_rssi").sent))
        XCTAssertEqual(RNode.Command.ready.data, bytes(exchange("ready").sent))
        XCTAssertEqual(RNode.Command.leave.data, bytes(exchange("leave").sent))
        // rnodeconf's detect bundle: detect, version, platform, mcu, board, device hash, both firmware hashes
        let bundle = [RNode.Command.detect, .firmwareVersion, .platform, .mcu, .board, .deviceHash,
                      .firmwareHash(expected: true), .firmwareHash(expected: false)].map(\.data).reduce(Data(), +)
        XCTAssertEqual(bundle, bytes(exchange("detect").sent))
    }

    func testSettersMatchReticulumsFrames() {
        // RNodeInterface.setFrequency: big-endian, escaped; one-byte settings raw.
        XCTAssertEqual(RNode.Command.setFrequency(hz: 914_875_000).data, bytes("c0 01 36 87 e2 78 c0"))
        XCTAssertEqual(RNode.Command.setBandwidth(hz: 125_000).data, bytes("c0 02 00 01 e8 48 c0"))
        XCTAssertEqual(RNode.Command.setTxPower(dBm: 22).data, bytes("c0 03 16 c0"))
        XCTAssertEqual(RNode.Command.setSpreadingFactor(8).data, bytes("c0 04 08 c0"))
        XCTAssertEqual(RNode.Command.setCodingRate(5).data, bytes("c0 05 05 c0"))
        XCTAssertEqual(RNode.Command.setRadioState(on: true).data, bytes("c0 06 01 c0"))
        XCTAssertEqual(RNode.Command.setRadioState(on: false).data, bytes("c0 06 00 c0"))
        XCTAssertEqual(RNode.Command.bluetooth(.pair).data, bytes("c0 46 02 c0"))
        XCTAssertEqual(RNode.Command.bluetooth(.on).data, bytes("c0 46 01 c0"))
    }

    func testEscapesFendAndFescInsidePayloads() {
        XCTAssertEqual(RNode.Command.setFrequency(hz: 0x00C0_00DB).data, bytes("c0 01 00 db dc 00 db dd c0"))
        XCTAssertEqual(RNode.KISS.escape([0xC0, 0xDB, 0x01]), [0xDB, 0xDC, 0xDB, 0xDD, 0x01])
        var d = RNode.Decoder()
        XCTAssertEqual(d.feed(bytes("c0 01 00 db dc 00 db dd c0")), [.frequency(0x00C0_00DB)])
    }

    func testDecoderKeepsItsPlaceAcrossNotifications() {
        // The 204-byte EEPROM frame, cut as Bluetooth would cut it, in pieces of 20 bytes.
        let all = bytes(exchange("rom_read").received)
        var d = RNode.Decoder()
        var out: [RNode.Frame] = []
        var i = all.startIndex
        while i < all.endIndex {
            let j = min(i + 20, all.endIndex)
            out += d.feed(all[i..<j])
            i = j
        }
        XCTAssertEqual(out.count, 1)
        guard case .eeprom(let e) = out[0] else { return XCTFail("not an EEPROM frame") }
        XCTAssertEqual(e.count, RNode.eepromSize, "200 bytes once the escaped 0xDB is unescaped")
        XCTAssertEqual(e[0x90], 0xDB, "the signature's escaped byte (db dd on the wire)")
    }

    // MARK: Frames from the real RNode

    func testDetectBundleFromTheWisBlock() {
        let f = frames("detect")
        XCTAssertEqual(f.count, 8)
        XCTAssertEqual(f[0], .detect(true))
        XCTAssertEqual(f[1], .firmwareVersion(major: 1, minor: 86))
        XCTAssertEqual(f[2], .platform(0x70))
        XCTAssertEqual(f[3], .mcu(0x71))
        XCTAssertEqual(f[4], .board(0x51))
        guard case .deviceHash(let h) = f[5] else { return XCTFail("no device hash") }
        XCTAssertEqual(h.count, 32)
        guard case .firmwareHash(true, let expected) = f[6], case .firmwareHash(false, let actual) = f[7] else { return XCTFail("no hashes") }
        XCTAssertEqual(expected, actual, "the running firmware is the one the EEPROM was signed for")
        XCTAssertEqual(RNode.platforms[0x70], "NRF52")
        XCTAssertEqual(RNode.mcus[0x71], "Nordic Semiconductor nRF52840")
        XCTAssertEqual(RNode.boards[0x51], "RAK4631")
    }

    func testEEPROMFromTheWisBlock() throws {
        guard case .eeprom(let d) = try XCTUnwrap(frames("rom_read").first) else { return XCTFail("not EEPROM") }
        let e = try XCTUnwrap(RNode.EEPROM(d))
        XCTAssertTrue(e.isProvisioned)
        XCTAssertEqual(e.product, 0x10)
        XCTAssertEqual(e.model, 0x12)
        XCTAssertEqual(e.hardwareRevision, 1)
        XCTAssertEqual(e.serialLine, "00:00:00:03")
        XCTAssertEqual(e.made, Date(timeIntervalSince1970: 1_791_419_385))
        XCTAssertEqual(e.checksumValid, true, "MD5 over product…made matches the stored checksum, as rnodeconf found")
        XCTAssertTrue(e.hasSignature)
        XCTAssertNil(e.tncConfiguration, "host-controlled: no TNC config saved")
        XCTAssertEqual(e.bluetoothEnabled, true, "rnodeconf -b was run")
        XCTAssertEqual(e.bytes.prefix(7).map { String(format: "%02x", $0) }.joined(separator: ":"), "10:12:01:00:00:00:03")
    }

    func testRadioParameterFramesFromTheWisBlock() {
        XCTAssertEqual(frames("frequency"), [.frequency(914_875_000)])
        XCTAssertEqual(frames("bandwidth"), [.bandwidth(125_000)])
        XCTAssertEqual(frames("txpower"), [.txPower(7)])
        XCTAssertEqual(frames("spreading_factor"), [.spreadingFactor(8)])
        XCTAssertEqual(frames("coding_rate"), [.codingRate(5)])
        XCTAssertEqual(frames("radio_state"), [.radioState(false)])
        XCTAssertEqual(frames("stat_rx"), [.statRX(0)])
        XCTAssertEqual(frames("stat_tx"), [.statTX(0)])
        XCTAssertEqual(frames("ready"), [.ready(true)])
        XCTAssertEqual(frames("random"), [.random(0xDE)])
        // Nothing heard yet: the firmware's -292 sentinel comes out as -36 (RNS decodes it the same way).
        XCTAssertEqual(frames("stat_rssi"), [.rssi(-36)])
    }

    // MARK: Device info as rnodeconf --info prints it

    func readySession() -> RNodeSession {
        var s = RNodeSession()
        s.begin()
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        for name in ["detect", "rom_read", "frequency", "bandwidth", "txpower", "spreading_factor", "coding_rate", "radio_state", "stat_rx", "stat_tx"] {
            for f in frames(name) { _ = s.handle(f, now: now) }
        }
        return s
    }

    func testInfoLinesMatchRnodeconf() {
        let s = readySession()
        let info = Self.fixture.rnodeconf_info
        let lines = s.device.infoLines(timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(lines[0], "Product            : \(info.product)")
        XCTAssertEqual(lines[1], "Device signature   : Signed", "rnodeconf said \(info.device_signature); the app can't hold its keys")
        XCTAssertEqual(lines[2], "Firmware version   : \(info.firmware_version)")
        XCTAssertEqual(lines[3], "Hardware revision  : \(info.hardware_revision)")
        XCTAssertEqual(lines[4], "Serial number      : \(info.serial_number)")
        XCTAssertEqual(lines[5], "Modem chip         : \(info.modem_chip)")
        XCTAssertEqual(lines[6], "Frequency range    : \(info.frequency_range)")
        XCTAssertEqual(lines[7], "Max TX power       : \(info.max_tx_power)")
        XCTAssertEqual(lines[8], "Manufactured       : \(info.manufactured_local)", "captured on a Mac in US Eastern time")
        XCTAssertEqual(lines[9], "Device mode        : \(info.device_mode)")
    }

    func testDeviceInfoDerivedValues() {
        let s = readySession()
        let d = s.device
        XCTAssertEqual(d.firmwareVersion, "1.86")
        XCTAssertEqual(d.firmwareIsCurrentEnough, true)
        XCTAssertEqual(d.productName, "RAK4631")
        XCTAssertEqual(d.bandText, "779–928 MHz")
        XCTAssertEqual(d.modemChip, "SX1262")
        XCTAssertEqual(d.frequencyRange, 779_000_000...928_000_000)
        XCTAssertEqual(d.maxTxPower, 22)
        XCTAssertEqual(d.codes, "10:12:51")
        XCTAssertEqual(d.platformName, "NRF52")
        XCTAssertEqual(d.boardName, "RAK4631")
        XCTAssertEqual(d.signatureState, .signed)
        XCTAssertEqual(s.productText, "RAK4631 779–928 MHz")
        XCTAssertEqual(d.firmwareHashMatches, true, "the detect bundle carried both hashes and they agree")
    }

    func testSessionWalksConnectDetectInfoParameters() {
        var s = RNodeSession()
        XCTAssertEqual(s.phase, .idle)
        s.begin()
        XCTAssertEqual(s.phase, .detecting)
        let now = Date()
        XCTAssertEqual(s.handle(.detect(true), now: now), [.detected(true)])
        XCTAssertEqual(s.phase, .readingInfo)
        for f in frames("detect").dropFirst() { _ = s.handle(f, now: now) }
        XCTAssertEqual(s.phase, .readingInfo)
        for f in frames("rom_read") { _ = s.handle(f, now: now) }
        XCTAssertEqual(s.phase, .readingParameters)
        var events: [RNodeSession.Event] = []
        for name in ["frequency", "bandwidth", "txpower", "spreading_factor", "coding_rate"] {
            for f in frames(name) { events += s.handle(f, now: now) }
        }
        XCTAssertEqual(s.phase, .readingParameters, "radio state is still to come")
        XCTAssertFalse(events.contains(.ready))
        events = s.handle(.radioState(false), now: now)
        XCTAssertEqual(events, [.parametersChanged, .ready])
        XCTAssertEqual(s.phase, .ready)
        let p = s.parameters
        XCTAssertEqual(p.frequencyHz, 914_875_000)
        XCTAssertEqual(p.frequencyMHz ?? 0, 914.875, accuracy: 1e-9)
        XCTAssertEqual(p.bandwidthHz, 125_000)
        XCTAssertEqual(p.txPower, 7)
        XCTAssertEqual(p.spreadingFactor, 8)
        XCTAssertEqual(p.codingRate, 5)
        XCTAssertEqual(p.radioOn, false)
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.bitrateKbps ?? 0, 3.125, accuracy: 1e-9)
        XCTAssertEqual(p.txPowerMilliwatts ?? 0, 5.012, accuracy: 0.001)
    }

    func testNotAnRNode() {
        var s = RNodeSession()
        s.begin()
        XCTAssertEqual(s.handle(.detect(false), now: Date()), [.detected(false)])
        XCTAssertEqual(s.phase, .notAnRNode)
        for f in frames("frequency") + frames("bandwidth") + frames("txpower") + frames("spreading_factor") + frames("coding_rate") + frames("radio_state") {
            XCTAssertFalse(s.handle(f, now: Date()).contains(.ready))
        }
        XCTAssertEqual(s.phase, .notAnRNode)
    }

    func testUnsetParametersAreNil() {
        var s = RNodeSession()
        _ = s.handle(.frequency(0), now: Date())
        _ = s.handle(.bandwidth(0), now: Date())
        _ = s.handle(.txPower(0xFF), now: Date())
        _ = s.handle(.spreadingFactor(0), now: Date())
        _ = s.handle(.codingRate(0), now: Date())
        XCTAssertEqual(s.parameters, RNode.RadioParameters())
        XCTAssertFalse(s.parameters.canTurnOn)
        XCTAssertNil(s.parameters.bitrateKbps)
    }

    // MARK: Stats, signal, battery (frame layouts from RNodeInterface.readLoop)

    func testChannelStatsFrame() {
        // airtime 2.91% / 0.37%, load 12.00% / 3.05%, rssi 57-157 = -100, noise 37-157 = -120, no interference
        let f = RNode.Frame(command: 0x25, payload: Data([0x01, 0x23, 0x00, 0x25, 0x04, 0xB0, 0x01, 0x31, 57, 37, 0xFF]))
        guard case .channelStats(let s) = f else { return XCTFail("\(f)") }
        XCTAssertEqual(s.airtimeShort, 2.91, accuracy: 1e-9)
        XCTAssertEqual(s.airtimeLong, 0.37, accuracy: 1e-9)
        XCTAssertEqual(s.channelLoadShort, 12.0, accuracy: 1e-9)
        XCTAssertEqual(s.channelLoadLong, 3.05, accuracy: 1e-9)
        XCTAssertEqual(s.rssi, -100)
        XCTAssertEqual(s.noiseFloor, -120)
        XCTAssertNil(s.interference)
        let g = RNode.Frame(command: 0x25, payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 57, 37, 80]))
        guard case .channelStats(let t) = g else { return XCTFail("\(g)") }
        XCTAssertEqual(t.interference, -77)
        XCTAssertEqual(RNode.Frame(command: 0x25, payload: Data([1, 2, 3])), .unknown(command: 0x25, payload: Data([1, 2, 3])))
    }

    func testPhyBatteryTemperatureSNRAndErrors() {
        let phy = RNode.Frame(command: 0x26, payload: Data([0x00, 0x80, 0x1E, 0x61, 0x00, 0x12, 0x00, 0x27, 0x00, 0x05, 0x00, 0x0A]))
        guard case .phyStats(let p) = phy else { return XCTFail("\(phy)") }
        XCTAssertEqual(p.symbolTimeMs, 0.128, accuracy: 1e-9)
        XCTAssertEqual(p.symbolRate, 7777)
        XCTAssertEqual(p.preambleSymbols, 18)
        XCTAssertEqual(p.preambleTimeMs, 39)
        XCTAssertEqual(p.csmaSlotMs, 5)
        XCTAssertEqual(p.difsMs, 10)
        XCTAssertEqual(RNode.Frame(command: 0x27, payload: Data([0x02, 85])), .battery(RNode.Battery(rawState: 2, percent: 85)))
        XCTAssertEqual(RNode.Frame(command: 0x27, payload: Data([0x01, 200])), .battery(RNode.Battery(rawState: 1, percent: 100)))
        XCTAssertEqual(RNode.Battery(rawState: 2, percent: 85).state, .charging)
        XCTAssertEqual(RNode.Battery(rawState: 9, percent: 1).stateWord, "Unknown")
        XCTAssertEqual(RNode.Frame(command: 0x29, payload: Data([100])), .temperature(-20))
        XCTAssertEqual(RNode.Frame(command: 0x29, payload: Data([250])), .temperature(nil))
        XCTAssertEqual(RNode.Frame(command: 0x24, payload: Data([0xF0])), .snr(-4.0))
        XCTAssertEqual(RNode.Frame(command: 0x24, payload: Data([0x29])), .snr(10.25))
        XCTAssertEqual(RNode.Frame(command: 0x23, payload: Data([57])), .rssi(-100))
        XCTAssertEqual(RNode.Frame(command: 0x90, payload: Data([0x01])), .error(.initRadio))
        XCTAssertEqual(RNode.Frame(command: 0x90, payload: Data([0x77])), .error(.other(0x77)))
        XCTAssertEqual(RNode.Frame(command: 0x62, payload: Data([0x00, 0x0C, 0x7A, 0xA0])), .bluetoothPIN(817_824))
        XCTAssertEqual(RNode.Frame(command: 0x28, payload: Data([1, 2, 3])), .csma(RNode.CSMA(band: 1, minimum: 2, maximum: 3)))
    }

    func testPacketCarriesThePrecedingRSSIAndSNR() {
        var s = RNodeSession()
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        var events = s.handle(.rssi(-101), now: now)
        events += s.handle(.snr(6.5), now: now)
        XCTAssertTrue(events.isEmpty, "signal is reported with the packet it belongs to")
        XCTAssertNil(s.signal)
        events = s.handle(.data(Data([1, 2, 3])), now: now)
        XCTAssertEqual(events, [.packet(Data([1, 2, 3]))])
        XCTAssertEqual(s.signal?.rssi, -101)
        XCTAssertEqual(s.signal?.snr, 6.5)
        XCTAssertEqual(s.packetsHeard, 1)
        XCTAssertEqual(s.lastPacketAt, now)
        XCTAssertEqual(RNode.signalQuality(snr: 6.5, spreadingFactor: 7), 100)
        XCTAssertEqual(RNode.signalQuality(snr: -9, spreadingFactor: 7), 0)
        XCTAssertEqual(RNode.signalQuality(snr: -11, spreadingFactor: 8), 0)
        XCTAssertEqual(RNode.signalQuality(snr: -1.5, spreadingFactor: 7), 50)
    }

    // MARK: Settings checks

    func testParameterProblems() {
        let rak = RNode.models[0x12]!
        XCTAssertEqual(RNode.RadioParameters.problems(frequencyHz: 914_875_000, bandwidthHz: 125_000, spreadingFactor: 8, codingRate: 5, txPower: 22, model: rak), [])
        XCTAssertEqual(RNode.RadioParameters.problems(frequencyHz: 433_000_000, model: rak), [.frequencyOutsideBand(779_000_000...928_000_000)])
        XCTAssertEqual(RNode.RadioParameters.problems(frequencyHz: 100_000_000, model: rak), [.frequencyOutsideLimits])
        XCTAssertEqual(RNode.RadioParameters.problems(bandwidthHz: 100_000), [.bandwidthUnsupported])
        XCTAssertEqual(RNode.RadioParameters.problems(spreadingFactor: 13), [.spreadingFactorOutOfRange])
        XCTAssertEqual(RNode.RadioParameters.problems(codingRate: 4), [.codingRateOutOfRange])
        XCTAssertEqual(RNode.RadioParameters.problems(txPower: 30, model: rak), [.txPowerAboveModel(max: 22)])
        XCTAssertEqual(RNode.RadioParameters.problems(txPower: 40), [.txPowerOutOfRange])
        XCTAssertEqual(RNode.bitrateKbps(spreadingFactor: 7, bandwidthHz: 125_000, codingRate: 5) ?? 0, 5.46875, accuracy: 1e-9)
        XCTAssertNil(RNode.bitrateKbps(spreadingFactor: 4, bandwidthHz: 125_000, codingRate: 5))
        XCTAssertEqual(RNode.kHzText(125_000), "125")
        XCTAssertEqual(RNode.kHzText(62_500), "62.5")
        XCTAssertEqual(RNode.kHzText(7_800), "7.8")
        XCTAssertEqual(RNode.mHzText(914_875_000), "914.875")
        XCTAssertEqual(RNode.mHzText(915_000_000), "915.0")
    }

    // MARK: Hostile input (anything over Bluetooth can be garbage)

    func testGarbageNeverTraps() {
        var d = RNode.Decoder()
        _ = d.feed(Data([0xC0, 0xC0, 0xC0, 0xDB, 0xDB, 0xC0, 0x51, 0xC0]))
        _ = d.feed(Data(repeating: 0xFF, count: 5000))
        _ = d.feed(Data([0xC0, 0x25] + Array(repeating: 0x00, count: 3000) + [0xC0]))
        XCTAssertEqual(d.dropped, 2, "both over-long frames were dropped")
        for cmd in UInt8(0)...UInt8(255) {
            for n in [0, 1, 2, 3, 4, 5, 11, 12, 32, 33, 199, 200] {
                _ = RNode.Frame(command: cmd, payload: Data(repeating: 0xAB, count: n))
            }
        }
        XCTAssertNil(RNode.EEPROM(Data(repeating: 0xFF, count: 10)))
        let blank = RNode.EEPROM(Data(repeating: 0xFF, count: 200))!
        XCTAssertFalse(blank.isProvisioned)
        var info = RNode.DeviceInfo()
        info.eeprom = blank
        XCTAssertEqual(info.signatureState, .unprovisioned)
        XCTAssertNil(info.productLine)
        XCTAssertEqual(info.infoLines().count, 1)
        // An escaped frame cut off mid-escape, then a good frame.
        var e = RNode.Decoder()
        XCTAssertEqual(e.feed(Data([0xC0, 0x01, 0xDB])), [])
        XCTAssertEqual(e.feed(Data([0xC0, 0x04, 0x08, 0xC0])), [.unknown(command: 0x01, payload: Data()), .spreadingFactor(8)])
    }
}
