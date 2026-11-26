import XCTest
@testable import WildcatRadioCore

final class AdminTests: XCTestCase {
    private var vectors: [String: String] = [:]
    private let me = NodeNum(0xDEAD_BEEF)
    private let pk = Data(1...8)

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "meshtastic-vectors", withExtension: "json"))
        vectors = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private func hex(_ k: String) throws -> Data {
        let s = try XCTUnwrap(vectors[k], k)
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    func testAdminPacketsMatchOfficialBytes() throws {
        XCTAssertEqual(Admin.getOwner(node: me, id: 1000), try hex("admin_get_owner"))
        XCTAssertEqual(Admin.beginEdit(node: me, passkey: pk, id: 1001), try hex("admin_begin"))
        XCTAssertEqual(Admin.commitEdit(node: me, passkey: pk, id: 1002), try hex("admin_commit"))
        XCTAssertEqual(Admin.reboot(node: me, seconds: 5, passkey: pk, id: 1003), try hex("admin_reboot"))
    }

    func testOwnerPatchKeepsEverythingElse() throws {
        var owner = Owner(raw: try hex("user_raw"))
        XCTAssertEqual(owner.longName, "Seth Walker")
        XCTAssertEqual(owner.shortName, "SW")
        owner.longName = "Wildcat Scout"
        owner.shortName = "WCS"
        XCTAssertEqual(Admin.setOwner(owner.patched, node: me, passkey: pk, id: 1004), try hex("admin_set_owner"))
    }

    func testLoRaPatchSetsRegionAndKeepsUnknownFields() throws {
        guard case .config(.lora, let raw) = try MeshCodec.decodeFromRadio(hex("fromradio_config_lora")) else { return XCTFail() }
        XCTAssertEqual(raw, try hex("lora_raw"))
        var lora = LoRaSettings(raw: raw)
        XCTAssertEqual(lora.region, .unset)
        XCTAssertEqual(lora.preset, .longFast)
        XCTAssertEqual(lora.hopLimit, 3)
        XCTAssertTrue(lora.txEnabled)
        lora.region = .us
        lora.hopLimit = 4
        XCTAssertEqual(lora.patched, try hex("lora_patched_raw"), "boosted gain, ignore list and mqtt flag survive")
        XCTAssertEqual(Admin.setConfig(.lora, lora.patched, node: me, passkey: pk, id: 1005), try hex("admin_set_lora"))
    }

    func testDevicePositionAndMetadata() throws {
        guard case .config(.device, let d) = try MeshCodec.decodeFromRadio(hex("fromradio_config_device")) else { return XCTFail() }
        XCTAssertEqual(DeviceSettings(raw: d).role, .client)
        guard case .config(.position, let p) = try MeshCodec.decodeFromRadio(hex("fromradio_config_position")) else { return XCTFail() }
        let pos = PositionSettings(raw: p)
        XCTAssertEqual(pos.broadcastSecs, 900)
        XCTAssertTrue(pos.smart)
        XCTAssertFalse(pos.fixed)
        XCTAssertEqual(try MeshCodec.decodeFromRadio(hex("fromradio_metadata")), .metadata(firmware: "2.7.11.ee68575"))
    }

    func testChannelsSetAndRemove() throws {
        guard case .channel(let ch) = try MeshCodec.decodeFromRadio(hex("fromradio_channel_full")) else { return XCTFail() }
        XCTAssertEqual(ch.name, "WGHUNT")
        let settings = try XCTUnwrap(ch.settings)
        XCTAssertEqual(ChannelSettings(raw: settings).keyKind, "private")
        XCTAssertEqual(Admin.setChannel(index: 1, settings: settings, role: .secondary, node: me, passkey: pk, id: 1006),
                       try hex("admin_set_channel"))
        XCTAssertEqual(Admin.setChannel(index: 2, settings: nil, role: .disabled, node: me, passkey: pk, id: 1007),
                       try hex("admin_remove_channel"))
    }

    func testSessionPicksUpPasskeyAndConfig() throws {
        var s = MeshSession(configID: 1)
        _ = s.handle(.myInfo(me))
        _ = s.handle(try MeshCodec.decodeFromRadio(hex("fromradio_config_lora")))
        XCTAssertTrue(s.needsRegion)
        XCTAssertNil(s.validPasskey())
        _ = s.handle(try MeshCodec.decodeFromRadio(hex("fromradio_admin_owner_response")))
        XCTAssertEqual(s.validPasskey(), pk)
        XCTAssertNil(s.validPasskey(now: Date().addingTimeInterval(600)), "expires")
    }

    /// The fixtures carry the ChannelSet as the reference tool encodes it; Wildcat
    /// wraps the same bytes in its own link (wildcat://channel#…).
    private func wildcatLink(_ key: String) throws -> String {
        let reference = try XCTUnwrap(vectors[key])
        let hash = try XCTUnwrap(reference.range(of: "#"))
        let add = reference[..<hash.lowerBound].contains("add=true")
        return "wildcat://channel" + (add ? "?add=true" : "") + reference[hash.lowerBound...]
    }

    func testChannelLinks() throws {
        let full = try wildcatLink("channelset_url")
        let link = try XCTUnwrap(ChannelLink(url: full))
        XCTAssertFalse(link.add)
        XCTAssertEqual(link.channels.map(\.name), ["", "WGHUNT"])
        XCTAssertEqual(link.channels[0].keyKind, "default")
        XCTAssertEqual(LoRaSettings(raw: try XCTUnwrap(link.lora)).region, .us)
        XCTAssertEqual(link.url, full, "round trip is byte-exact")
        let addLink = try wildcatLink("channelset_hunt_only_add_url")
        let add = try XCTUnwrap(ChannelLink(url: addLink))
        XCTAssertTrue(add.add)
        XCTAssertEqual(add.channels.map(\.name), ["WGHUNT"])
        XCTAssertEqual(add.url, addLink)
        XCTAssertTrue(add.url.hasPrefix("wildcat://channel?add=true#"))
        XCTAssertNil(ChannelLink(url: "https://example.com/#abc"))
    }

    /// Meshtastic's own link format is not read or made (Meshtastic LLC's request, 2026-11-25).
    func testMeshtasticLinksAreNotUsed() throws {
        XCTAssertNil(ChannelLink(url: try XCTUnwrap(vectors["channelset_url"])))
        XCTAssertNil(ChannelLink(url: try XCTUnwrap(vectors["channelset_hunt_only_add_url"])))
        let made = ChannelLink(channels: [ChannelSettings(raw: Data([0x3a, 0x02, 0x08, 0x0d]))], lora: nil, add: true).url
        XCTAssertFalse(made.contains("meshtastic"))
    }

    func testPatchRemovesDefaults() {
        let raw = Proto.patch(Data(), [1: Proto.varint(true), 8: Proto.varint(3)])
        XCTAssertEqual(Proto.patch(raw, [8: Proto.varint(0)]), Proto.patch(Data(), [1: Proto.varint(true)]))
    }

    func testModuleConfigFromTheNodeAndPatchedBack() throws {
        guard case .moduleConfig(let section, let raw) = try MeshCodec.decodeFromRadio(hex("fromradio_module_telemetry"))
        else { return XCTFail() }
        XCTAssertEqual(section, .telemetry)
        var s = MeshSession()
        _ = s.handle(.moduleConfig(section, raw))
        var tel = try XCTUnwrap(s.telemetry)
        XCTAssertEqual(tel.deviceUpdateSecs, 1800)
        XCTAssertFalse(tel.deviceTelemetryEnabled)
        tel.deviceUpdateSecs = 60
        tel.deviceTelemetryEnabled = true
        XCTAssertEqual(Admin.setModuleConfig(.telemetry, tel.patched, node: me, passkey: pk, id: 1015),
                       try hex("admin_set_module_telemetry"), "environment settings survive")
    }

    func testChirpAndStoreForwardModules() throws {
        var ext = ExternalNotificationSettings(raw: Data())
        ext.enabled = true; ext.outputMs = 1000; ext.alertMessage = true; ext.alertMessageBuzzer = true; ext.usePWM = true
        XCTAssertEqual(Admin.setModuleConfig(.externalNotification, ext.patched, node: me, passkey: pk, id: 1016),
                       try hex("admin_set_module_extnotif"))
        var sf = StoreForwardSettings(raw: Data())
        sf.enabled = true; sf.isServer = true
        XCTAssertEqual(Admin.setModuleConfig(.storeForward, sf.patched, node: me, passkey: pk, id: 1017),
                       try hex("admin_set_module_storeforward"))
    }

    func testHidingPositionTurnsGPSOff() throws {
        guard case .config(.position, let raw) = try MeshCodec.decodeFromRadio(hex("fromradio_config_position_gps"))
        else { return XCTFail() }
        var p = PositionSettings(raw: raw)
        XCTAssertEqual(p.gpsMode, .enabled)
        p.broadcastSecs = 43200; p.smart = false; p.gpsMode = .disabled
        XCTAssertEqual(Admin.setConfig(.position, p.patched, node: me, passkey: pk, id: 1018), try hex("admin_set_position_hidden"))
    }
}
