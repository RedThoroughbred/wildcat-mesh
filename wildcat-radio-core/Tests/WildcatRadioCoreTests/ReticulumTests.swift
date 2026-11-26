import XCTest
@testable import WildcatRadioCore

/// Wildcat's rules around the Reticulum stack: addresses, radio settings, and the checks before a start.
final class ReticulumTests: XCTestCase {
    private let test = Reticulum.RadioSettings(frequencyHz: 914_875_000, bandwidthHz: 125_000, spreadingFactor: 8, codingRate: 5, txPower: 7)

    private func device(_ major: UInt8?, _ minor: UInt8?) -> RNode.DeviceInfo {
        var d = RNode.DeviceInfo()
        d.firmwareMajor = major
        d.firmwareMinor = minor
        return d
    }

    func testAddresses() {
        XCTAssertEqual(Reticulum.address(" <53802FDD0123456789abcdef0123a41c>\n"), "53802fdd0123456789abcdef0123a41c")
        XCTAssertNil(Reticulum.address("53802fdd"))
        XCTAssertNil(Reticulum.address("53802fdd0123456789abcdef0123a41g"))
        XCTAssertNil(Reticulum.address("53802fdd0123456789abcdef0123a41c00"))
        XCTAssertNil(Reticulum.address("５３８０２ｆｄｄ０１２３４５６７８９ａｂｃｄｅｆ０１２３ａ４１ｃ"), "full-width digits aren't hex")
        XCTAssertEqual(Reticulum.shortAddress("53802fdd0123456789abcdef0123a41c"), "53802fdd…a41c")
        XCTAssertEqual(Reticulum.shortAddress("abc"), "abc")
    }

    func testRadioSettingsFromTheRNodeNeedAllFive() {
        var p = RNode.RadioParameters(frequencyHz: 914_875_000, bandwidthHz: 125_000, txPower: 7, spreadingFactor: 8)
        XCTAssertNil(Reticulum.RadioSettings(p), "no coding rate yet")
        p.codingRate = 5
        XCTAssertEqual(Reticulum.RadioSettings(p), test)
        XCTAssertEqual(test.line, "914.875 MHz · 125 kHz · SF8 · CR 4/5 · 7 dBm")
        XCTAssertEqual(test.command, ["frequency": 914_875_000, "bandwidth": 125_000, "txpower": 7, "spreadingfactor": 8, "codingrate": 5])
    }

    func testAStartUsesThePersonsSettingsNeverADefault() {
        let other = Reticulum.RadioSettings(frequencyHz: 868_100_000, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 6, txPower: 14)
        let set = RNode.RadioParameters(frequencyHz: 914_875_000, bandwidthHz: 125_000, txPower: 7, spreadingFactor: 8, codingRate: 5)
        // The RNode's own settings win, even over what the last start used.
        XCTAssertEqual(Reticulum.settingsForStart(rnode: set, lastUsed: other)?.settings, test)
        XCTAssertEqual(Reticulum.settingsForStart(rnode: set, lastUsed: other)?.source, .rnode)
        // A rebooted RNode has none: the last start's.
        let rebooted = RNode.RadioParameters()
        XCTAssertEqual(Reticulum.settingsForStart(rnode: rebooted, lastUsed: other)?.settings, other)
        XCTAssertEqual(Reticulum.settingsForStart(rnode: rebooted, lastUsed: other)?.source, .lastUsed)
        // Half set is not set.
        let half = RNode.RadioParameters(frequencyHz: 914_875_000, bandwidthHz: 125_000)
        XCTAssertEqual(Reticulum.settingsForStart(rnode: half, lastUsed: other)?.source, .lastUsed)
        // Nothing anywhere: no start (and startProblem says to set the radio).
        XCTAssertNil(Reticulum.settingsForStart(rnode: rebooted, lastUsed: nil))
    }

    func testRadioSettingsSaveAndLoad() throws {
        let back = try JSONDecoder().decode(Reticulum.RadioSettings.self, from: JSONEncoder().encode(test))
        XCTAssertEqual(back, test)
        let old = #"{"frequencyHz":868000000,"bandwidthHz":125000,"spreadingFactor":9,"txPower":14}"#
        XCTAssertEqual(try JSONDecoder().decode(Reticulum.RadioSettings.self, from: Data(old.utf8)).codingRate, 5)
    }

    func testStartIsRefusedBeforeReticulumCouldEndTheApp() {
        // Reticulum ends the process on firmware older than 1.52: Wildcat never lets it get that far.
        XCTAssertEqual(Reticulum.startProblem(connected: false, device: device(1, 86), settings: test), .noRNode)
        XCTAssertEqual(Reticulum.startProblem(connected: true, device: device(nil, nil), settings: test), .firmwareUnknown)
        XCTAssertEqual(Reticulum.startProblem(connected: true, device: device(1, 51), settings: test), .firmwareTooOld(have: "1.51"))
        XCTAssertEqual(Reticulum.startProblem(connected: true, device: device(0, 99), settings: test), .firmwareTooOld(have: "0.99"))
        XCTAssertNil(Reticulum.startProblem(connected: true, device: device(1, 52), settings: test))
        XCTAssertNil(Reticulum.startProblem(connected: true, device: device(2, 0), settings: test))
        XCTAssertEqual(Reticulum.startProblem(connected: true, device: device(1, 86), settings: nil), .noSettings)
        XCTAssertTrue(Reticulum.StartProblem.firmwareTooOld(have: "1.51").line.contains("1.52"))
    }

    func testStartIsRefusedOnSettingsNoRNodeTakes() {
        var bad = test
        bad.txPower = 40
        bad.spreadingFactor = 13
        XCTAssertEqual(Reticulum.startProblem(connected: true, device: device(1, 86), settings: bad),
                       .settings([.spreadingFactorOutOfRange, .txPowerOutOfRange]))
        bad = test
        bad.frequencyHz = 100_000_000
        XCTAssertEqual(Reticulum.startProblem(connected: true, device: device(1, 86), settings: bad), .settings([.frequencyOutsideLimits]))
        XCTAssertFalse(Reticulum.StartProblem.settings([.txPowerOutOfRange]).line.isEmpty)
    }
}

final class ReticulumInternetLinkTests: XCTestCase {
    func testAcceptsNamesAndIPv4AndSplitsAPastedPort() {
        XCTAssertEqual(Reticulum.internetLink(host: " Node.Example.org ", port: "4242"), .success(.init(host: "node.example.org", port: 4242)))
        XCTAssertEqual(Reticulum.internetLink(host: "192.168.1.20", port: "4965"), .success(.init(host: "192.168.1.20", port: 4965)))
        XCTAssertEqual(Reticulum.internetLink(host: "node.example.org:7822", port: "4242"), .success(.init(host: "node.example.org", port: 7822)),
                       "a pasted host:port wins over the port box")
        XCTAssertEqual(Reticulum.internetLink(host: "tcp://node.example.org:4242/", port: ""), .success(.init(host: "node.example.org", port: 4242)))
        XCTAssertEqual(Reticulum.InternetLink(host: "a.example", port: 1).line, "a.example:1")
    }

    func testRefusesWhatCouldNotBeAHostOrAPort() {
        XCTAssertEqual(Reticulum.internetLink(host: "  ", port: "4242"), .failure(.noHost))
        for bad in ["node example.org", "node\n  [[Evil]]", "node=1", "-node.example", "node..example", "a:b:c", "nöde.example", "node/../x",
                    String(repeating: "a", count: 64) + ".example"] {
            XCTAssertEqual(Reticulum.internetLink(host: bad, port: "4242"), .failure(.badHost), bad)
        }
        for bad in ["", "0", "65536", "42a", "-1", "４２４２", "123456"] {
            XCTAssertEqual(Reticulum.internetLink(host: "node.example.org", port: bad), .failure(.badPort), bad)
        }
    }

    func testStartPlan() {
        var device = RNode.DeviceInfo()
        device.firmwareMajor = 1
        device.firmwareMinor = 86
        let radio = Reticulum.RadioSettings(frequencyHz: 914_875_000, bandwidthHz: 125_000, spreadingFactor: 8, codingRate: 5, txPower: 7)
        let net = Reticulum.InternetLink(host: "node.example.org", port: 4242)
        // No RNode: the internet link alone is enough; nothing at all is not.
        XCTAssertEqual(Reticulum.startPlan(rnodeConnected: false, device: RNode.DeviceInfo(), settings: nil, internet: net),
                       .success(.init(radio: nil, internet: net)))
        XCTAssertEqual(Reticulum.startPlan(rnodeConnected: false, device: RNode.DeviceInfo(), settings: nil, internet: nil), .failure(.noRNode))
        // A connected RNode takes part, with or without the internet link.
        XCTAssertEqual(Reticulum.startPlan(rnodeConnected: true, device: device, settings: radio, internet: nil), .success(.init(radio: radio, internet: nil)))
        XCTAssertEqual(Reticulum.startPlan(rnodeConnected: true, device: device, settings: radio, internet: net), .success(.init(radio: radio, internet: net)))
        // A connected RNode with a problem stops the start, even with the internet link on.
        XCTAssertEqual(Reticulum.startPlan(rnodeConnected: true, device: device, settings: nil, internet: net), .failure(.noSettings))
        device.firmwareMinor = 40
        XCTAssertEqual(Reticulum.startPlan(rnodeConnected: true, device: device, settings: radio, internet: net), .failure(.firmwareTooOld(have: "1.40")))
    }
}
