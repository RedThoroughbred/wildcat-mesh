import XCTest
import WildcatRadioCore
@testable import WildcatGames

final class MeshCoreSetupTests: XCTestCase {
    private let key = Data([0xA1, 0xB2, 0xC3, 0xD4] + [UInt8](repeating: 7, count: 28))

    private func me(name: String, f: Double = 910.525, bw: Double = 62.5, sf: Int = 7, cr: Int = 5,
                    tele: UInt8 = 0) -> MeshCore.SelfInfo {
        // SelfInfo has no public init: start from the practice node's and change what matters.
        var m = MeshCoreSession.demo().me!
        m.publicKey = key
        m.telemetryModes = tele
        m.frequency = f
        m.bandwidth = bw
        m.spreadingFactor = sf
        m.codingRate = cr
        m.name = name
        return m
    }

    // MARK: Presets

    func testOwnersNodeIsOnUSA() {
        let p = MeshCorePresets.match(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5)
        XCTAssertNotNil(p)
        XCTAssertEqual(MeshCorePresets.match(me(name: "X"), regionCode: "US")?.title, "USA")
        XCTAssertEqual(MeshCorePresets.match(me(name: "X"), regionCode: "CA")?.title, "Canada")
        XCTAssertEqual(MeshCorePresets.label(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5), "USA / Canada")
        XCTAssertEqual(MeshCorePresets.match(me(name: "X"))?.title, "USA", "no region: USA")
    }

    func testPresetMatchingIsExact() {
        XCTAssertNil(MeshCorePresets.match(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 8, codingRate: 5))
        XCTAssertNil(MeshCorePresets.match(frequency: 915, bandwidth: 250, spreadingFactor: 10, codingRate: 5))
        XCTAssertEqual(MeshCorePresets.match(frequency: 869.618, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8)?.title, "EU/UK (Narrow)")
        // A float that came back through the firmware's kHz integers still matches.
        XCTAssertNotNil(MeshCorePresets.match(frequency: 916.5750001, bandwidth: 62.5, spreadingFactor: 7, codingRate: 7))
    }

    func testPresetTableIsSane() {
        XCTAssertEqual(Set(MeshCorePresets.all.map(\.title)).count, MeshCorePresets.all.count, "titles are ids")
        for p in MeshCorePresets.all {
            XCTAssertTrue(MeshCoreNodeLimits.isValidRadio(frequency: p.frequency, bandwidth: p.bandwidth,
                                                          spreadingFactor: p.spreadingFactor, codingRate: p.codingRate), p.title)
            XCTAssertFalse(p.regions.isEmpty, p.title)
        }
        for (_, title) in MeshCorePresets.defaults { XCTAssertNotNil(MeshCorePresets.named(title), title) }
    }

    func testGuessFromRegion() {
        XCTAssertEqual(MeshCorePresets.guess(regionCode: "US")?.title, "USA")
        XCTAssertEqual(MeshCorePresets.guess(regionCode: "gb")?.title, "EU/UK (Narrow)")
        XCTAssertEqual(MeshCorePresets.guess(regionCode: "NZ")?.title, "New Zealand (Narrow)")
        XCTAssertNil(MeshCorePresets.guess(regionCode: "AU"), "several Australian presets: let the user pick")
        XCTAssertNil(MeshCorePresets.guess(regionCode: "JP"))
        XCTAssertNil(MeshCorePresets.guess(regionCode: nil))
        XCTAssertEqual(MeshCorePresets.suggested(regionCode: "US").first?.title, "USA")
        XCTAssertEqual(MeshCorePresets.suggested(regionCode: "AU").count, 5)
        XCTAssertFalse(MeshCorePresets.suggested(regionCode: "VN").contains { $0.deprecated })
    }

    // MARK: Needs setup

    func testDefaultNames() {
        XCTAssertTrue(MeshCoreSetupCheck.isDefaultName("a1b2c3d4", publicKey: key))
        XCTAssertTrue(MeshCoreSetupCheck.isDefaultName("A1B2C3D4", publicKey: key))
        XCTAssertTrue(MeshCoreSetupCheck.isDefaultName("NONAME", publicKey: key))
        XCTAssertTrue(MeshCoreSetupCheck.isDefaultName("  ", publicKey: key))
        XCTAssertFalse(MeshCoreSetupCheck.isDefaultName("MAYA Trail", publicKey: key))
        XCTAssertFalse(MeshCoreSetupCheck.isDefaultName("deadbeef", publicKey: key))
    }

    func testNeedsSetup() {
        XCTAssertFalse(MeshCoreSetupCheck.needsSetup(nil))
        XCTAssertFalse(MeshCoreSetupCheck.needsSetup(me(name: "MAYA Trail")))
        XCTAssertEqual(MeshCoreSetupCheck.keyWord(me(name: "MAYA Trail")), "Node")
        XCTAssertEqual(MeshCoreSetupCheck.reasons(me(name: "a1b2c3d4")), [.defaultName])
        XCTAssertEqual(MeshCoreSetupCheck.keyWord(me(name: "a1b2c3d4")), "Name!")
        XCTAssertEqual(MeshCoreSetupCheck.reasons(me(name: "MAYA", f: 915, bw: 250, sf: 10)), [.offPreset])
        XCTAssertEqual(MeshCoreSetupCheck.keyWord(me(name: "MAYA", f: 915, bw: 250, sf: 10)), "Radio!")
        XCTAssertEqual(MeshCoreSetupCheck.reasons(me(name: "NONAME", f: 915, bw: 250, sf: 10)), [.defaultName, .offPreset])
        XCTAssertEqual(MeshCoreSetupCheck.keyWord(me(name: "NONAME", f: 915, bw: 250, sf: 10)), "Setup!")
        XCTAssertNotNil(MeshCoreSetupCheck.line(me(name: "NONAME")))
        XCTAssertNil(MeshCoreSetupCheck.line(me(name: "MAYA")))
    }

    // MARK: Limits

    func testNameClampKeepsWholeCharacters() {
        XCTAssertEqual(MeshCoreNodeLimits.clamp("MAYA"), "MAYA")
        XCTAssertEqual(MeshCoreNodeLimits.clamp(String(repeating: "x", count: 40)).utf8.count, 31)
        let emoji = String(repeating: "🦊", count: 10)   // 4 bytes each
        XCTAssertEqual(MeshCoreNodeLimits.clamp(emoji), String(repeating: "🦊", count: 7))
    }

    func testFreeChannelSlotUsesTheNodesMax() {
        let full7 = Set(0...7)
        XCTAssertEqual(MeshCoreNodeLimits.freeChannelSlot(used: full7, maxChannels: 40), 8, "v1.17 has 40 slots")
        XCTAssertNil(MeshCoreNodeLimits.freeChannelSlot(used: full7, maxChannels: 8))
        XCTAssertNil(MeshCoreNodeLimits.freeChannelSlot(used: full7, maxChannels: nil))
        XCTAssertEqual(MeshCoreNodeLimits.freeChannelSlot(used: [0, 2], maxChannels: nil), 1)
        XCTAssertNil(MeshCoreNodeLimits.freeChannelSlot(used: Set(0..<40), maxChannels: 40))
    }

    func testRadioValidation() {
        XCTAssertTrue(MeshCoreNodeLimits.isValidRadio(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5))
        XCTAssertTrue(MeshCoreNodeLimits.isValidRadio(frequency: 869.5, bandwidth: 31.25, spreadingFactor: 12, codingRate: 8))
        XCTAssertFalse(MeshCoreNodeLimits.isValidRadio(frequency: 910.525, bandwidth: 60, spreadingFactor: 7, codingRate: 5))
        XCTAssertFalse(MeshCoreNodeLimits.isValidRadio(frequency: 91.0, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5))
        XCTAssertFalse(MeshCoreNodeLimits.isValidRadio(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 13, codingRate: 5))
        XCTAssertFalse(MeshCoreNodeLimits.isValidRadio(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 4))
    }

    func testTelemetryModesByte() {
        let m = MeshCoreTelemetryMode.Modes(byte: 0b10_01_10)
        XCTAssertEqual(m.base, .anyone)
        XCTAssertEqual(m.location, .allowed)
        XCTAssertEqual(m.environment, .anyone)
        XCTAssertEqual(m.byte, 0b10_01_10)
        var n = m
        n.location = .nobody
        XCTAssertEqual(n.byte, 0b10_00_10)
        XCTAssertEqual(MeshCoreTelemetryMode.Modes(byte: 0xFF).base, .nobody, "3 isn't a mode")
        XCTAssertEqual(MeshCoreTelemetryMode.Modes(byte: 0).byte, 0)
    }
}
