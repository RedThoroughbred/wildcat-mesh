import XCTest
import WildcatRadioCore
@testable import WildcatGames

final class QuickSetupTests: XCTestCase {
    private let hunt = ChannelSettings(name: "WGHUNT", psk: Data(repeating: 7, count: 32)).raw

    /// An everyday node: default primary, a family channel, WGHUNT, fixed position, GPS on.
    private func everydayNode() -> MeshSession {
        var s = MeshSession(configID: 1)
        _ = s.handle(.myInfo(NodeNum(0x53FD_8B02)))
        _ = s.handle(.channel(ChannelInfo(index: 0, name: "", role: .primary, settings: ChannelSettings(name: "", psk: Data([1])).raw)))
        _ = s.handle(.channel(ChannelInfo(index: 1, name: "Family", role: .secondary, settings: ChannelSettings(name: "Family", psk: Data(repeating: 3, count: 32)).raw)))
        _ = s.handle(.channel(ChannelInfo(index: 2, name: "WGHUNT", role: .secondary, settings: hunt)))
        _ = s.handle(.config(.lora, Proto.patch(Data(), [1: Proto.varint(true), 7: Proto.varint(Region.us.rawValue), 10: Proto.varint(27)])))
        _ = s.handle(.config(.position, Proto.patch(Data(), [1: Proto.varint(900), 3: Proto.varint(true), 13: Proto.varint(1)])))
        _ = s.handle(.config(.device, Data()))
        _ = s.handle(.moduleConfig(.telemetry, Proto.patch(Data(), [1: Proto.varint(1800), 2: Proto.varint(900)])))
        return s
    }

    func testLearnsHuntChannelWithMeshSlotPinned() throws {
        let h = try XCTUnwrap(QuickSetup.huntChannel(in: everydayNode()))
        XCTAssertEqual(h.name, "WGHUNT")
        XCTAssertEqual(h.settings, hunt)
        let lora = try Proto.Message(XCTUnwrap(h.lora))
        XCTAssertEqual(lora.uint32(11), 20, "US LongFast slot")
    }

    func testFoxChanges() throws {
        let s = everydayNode()
        let h = try XCTUnwrap(QuickSetup.huntChannel(in: s))
        let changes = QuickSetup.fox(s, hunt: h)
        var channels: [Int: Data?] = [:]
        var position: PositionSettings?
        var lora: LoRaSettings?
        var telemetry: TelemetrySettings?
        var cleared = false
        for c in changes {
            switch c {
            case .channel(let i, let settings, _): channels[i] = settings
            case .config(.position, let d): position = PositionSettings(raw: d)
            case .config(.lora, let d): lora = LoRaSettings(raw: d)
            case .module(.telemetry, let d): telemetry = TelemetrySettings(raw: d)
            case .clearFixedPosition: cleared = true
            default: break
            }
        }
        XCTAssertEqual(channels[0], .some(hunt), "WGHUNT becomes primary")
        XCTAssertEqual(channels[1], .some(nil))
        XCTAssertEqual(channels[2], .some(nil))
        XCTAssertEqual(position?.gpsMode, .disabled)
        XCTAssertEqual(position?.fixed, false)
        XCTAssertTrue(cleared)
        XCTAssertEqual(telemetry?.deviceUpdateSecs, 3600, "hourly: at or below Meshtastic's default")
        XCTAssertEqual(telemetry?.deviceTelemetryEnabled, true)
        let l = try XCTUnwrap(lora)
        XCTAssertEqual(l.txPower, QuickSetup.foxPower)
        XCTAssertEqual(l.region, .us)
        XCTAssertEqual(try Proto.Message(l.raw).uint32(11), 20, "stays on the mesh's frequency")
        XCTAssertEqual(FrequencySlot.effective(lora: l, primaryName: "WGHUNT"), 20)
        // Environment telemetry settings survive the patch.
        XCTAssertEqual(try Proto.Message(XCTUnwrap(telemetry).raw).uint32(2), 900)
    }

    func testDenLiteAddsHuntChannelAndFixesPosition() throws {
        var s = everydayNode()
        _ = s.handle(.channel(ChannelInfo(index: 2, name: "", role: .disabled, settings: nil)))
        let h = QuickSetup.HuntChannel(settings: hunt, lora: nil)
        let changes = QuickSetup.denLite(s, at: Coordinate(latitude: 39.1, longitude: -84.5), altitude: 200, hunt: h)
        XCTAssertTrue(changes.contains { if case .channel(2, hunt, .secondary) = $0 { return true } else { return false } })
        XCTAssertTrue(changes.contains { if case .fixedPosition = $0 { return true } else { return false } })
        XCTAssertTrue(changes.contains { if case .module(.storeForward, let d) = $0 { return StoreForwardSettings(raw: d).isServer } else { return false } })
        XCTAssertFalse(changes.contains { if case .config(.device, _) = $0 { return true } else { return false } }, "client stays client")
    }

    /// Automatic sends stay at or below Meshtastic's defaults (Meshtastic LLC's request, 2026-11-25).
    func testAutomaticSendsStayAtOrBelowMeshtasticDefaults() {
        XCTAssertGreaterThanOrEqual(QuickSetup.foxHeartbeatSecs, 3600)
        XCTAssertGreaterThanOrEqual(QuickSetup.denTelemetrySecs, 3600)
        XCTAssertGreaterThanOrEqual(QuickSetup.denPositionSecs, 3600)
    }
}
