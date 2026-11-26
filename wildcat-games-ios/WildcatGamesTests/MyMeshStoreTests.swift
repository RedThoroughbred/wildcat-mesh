import XCTest
import WildcatRadioCore
@testable import WildcatGames

@MainActor
final class MyMeshStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("mymesh-\(UUID()).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.appendingPathExtension("bad"))
    }

    /// A connected Meshtastic router on US LongFast with two channels.
    private func meshtasticSession(battery: Int = 80) -> MeshSession {
        var s = MeshSession(configID: 7)
        let me = NodeNum(0x1234_ABCD)
        _ = s.handle(.myInfo(me))
        var info = NodeInfo(num: me, userID: me.id, longName: "Home Base", shortName: "HOME")
        info.hwModel = 9
        info.metrics = DeviceMetrics(batteryLevel: battery, voltage: 4.01)
        _ = s.handle(.nodeInfo(info))
        var friend = NodeInfo(num: NodeNum(0x0000_BEEF), longName: "Trail Relay", shortName: "TRL")
        friend.lastHeard = Date()
        _ = s.handle(.nodeInfo(friend))
        _ = s.handle(.config(.lora, Data([0x08, 0x01, 0x38, 0x01, 0x50, 0x1B])))   // preset on, US, 27 dBm
        _ = s.handle(.config(.device, Data([0x08, 0x02])))                          // router
        _ = s.handle(.config(.position, Data()))                                     // no GPS, not fixed
        _ = s.handle(.channel(ChannelInfo(index: 0, name: "", role: .primary)))
        _ = s.handle(.channel(ChannelInfo(index: 1, name: "WGHUNT", role: .secondary)))
        _ = s.handle(.metadata(firmware: "2.6.11"))
        return s
    }

    private var hilltop: MeshCore.Contact {
        MeshCoreSession.demo().contacts.values.first { $0.name == "Hilltop Repeater" }!
    }

    func testMergeKeepsKnownFactsAndMovesTimesForward() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var old = OwnedNode(network: .meshcore, nodeID: "AABBCCDDEEFF", name: "Solar", hardware: "RAK", roleCode: 2,
                            radio: .init(frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, txPowerDBm: 22),
                            batteryVolts: 3.9, lastHeard: t0.addingTimeInterval(100), origin: .admin, added: t0)
        XCTAssertEqual(old.nodeID, "aabbccddeeff", "ids are lowercased so both sources match")
        var fresh = OwnedNode(network: .meshcore, nodeID: "aabbccddeeff", name: "Solar Hill", batteryVolts: 4.1,
                              lastHeard: t0, origin: .manual, added: t0.addingTimeInterval(500))
        fresh.radio = .init(frequencyMHz: 915, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 8, inferred: true)
        old.merge(fresh)
        XCTAssertEqual(old.name, "Solar Hill")
        XCTAssertEqual(old.hardware, "RAK", "unknown in the fresh report: kept")
        XCTAssertEqual(old.batteryVolts, 4.1)
        XCTAssertEqual(old.lastHeard, t0.addingTimeInterval(100), "an older report doesn't move last heard back")
        XCTAssertEqual(old.radio?.frequencyMHz, 910.525, "copied settings never replace ones read from the node")
        XCTAssertEqual(old.origin, .admin)
        XCTAssertEqual(old.added, t0)
        let other = OwnedNode(network: .meshtastic, nodeID: "aabbccddeeff", name: "Nope", origin: .manual)
        let before = old
        old.merge(other)
        XCTAssertEqual(old, before, "a different node is never merged in")
    }

    func testMeshtasticConnectAddsAndPacketsOnlyUpdate() throws {
        let store = MyMeshStore(file: file)
        let s = meshtasticSession()
        let bt = UUID()
        store.connected(meshtastic: s, bluetoothID: bt)
        let n = try XCTUnwrap(store.saved.first)
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(n.id, "meshtastic:!1234abcd")
        XCTAssertEqual(n.name, "Home Base")
        XCTAssertEqual(n.hardware, "RAK4631")
        XCTAssertEqual(n.firmware, "2.6.11")
        XCTAssertEqual(n.meshtasticRole, .router)
        XCTAssertEqual(n.radio?.summary, "US 915 · Long Fast · slot 20 · 27 dBm")
        XCTAssertEqual(n.radio?.channels, ["LongFast", "WGHUNT"])
        XCTAssertEqual(n.batteryPercent, 80)
        XCTAssertEqual(n.sharesLocation, false)
        XCTAssertEqual(n.bluetoothID, bt)
        XCTAssertTrue(n.roleExplanation.hasPrefix("Router:"))

        // A stranger's packet adds nothing; our node's own telemetry updates the record.
        store.heard(meshtastic: s, from: NodeNum(0x0000_BEEF))
        XCTAssertEqual(store.saved.count, 1)
        store.heard(meshtastic: meshtasticSession(battery: 55), from: NodeNum(0x1234_ABCD))
        XCTAssertEqual(store.saved.first?.batteryPercent, 55)

        // Marked as mine: now its packets update it too.
        store.markMine(.meshtastic(s.nodes[NodeNum(0x0000_BEEF)]!))
        XCTAssertEqual(store.saved.count, 2)
        XCTAssertTrue(store.contains("meshtastic:!0000beef"))

        // Removed: packets don't bring it back, only a new connection does.
        store.remove(n.id)
        store.heard(meshtastic: s, from: NodeNum(0x1234_ABCD))
        XCTAssertFalse(store.contains(n.id))
        store.connected(meshtastic: s, bluetoothID: bt)
        XCTAssertTrue(store.contains(n.id))
    }

    func testMeshCoreCompanionRepeaterLoginAndStatus() throws {
        let store = MyMeshStore(file: file)
        let demo = MeshCoreSession.demo()
        store.connected(meshcore: demo, bluetoothID: nil)
        let companion = try XCTUnwrap(store.saved.first)
        XCTAssertEqual(companion.meshcoreKind, .chat)
        XCTAssertEqual(companion.radio?.summary, "910.525 MHz · 62.5 kHz · SF7 · CR5 · 22 dBm")
        XCTAssertEqual(companion.batteryVolts, 3.91)
        XCTAssertEqual(companion.sharesLocation, false)
        XCTAssertEqual(companion.firmware, "v1.17.1")
        XCTAssertTrue(companion.roleExplanation.contains("never repeats"))

        // A status reply from a repeater we don't own is ignored.
        store.repeaterStatus(prefix: hilltop.prefix, .init(uptimeSeconds: 60, at: Date()))
        XCTAssertEqual(store.saved.count, 1)

        store.adminLogin(hilltop, companion: demo.me)
        let r = try XCTUnwrap(store.saved.first { $0.meshcoreKind == .repeater })
        XCTAssertEqual(r.origin, .admin)
        XCTAssertEqual(r.radio?.inferred, true)
        XCTAssertNil(r.radio?.txPowerDBm, "the companion's power says nothing about the repeater's")
        XCTAssertEqual(r.sharesLocation, true)
        XCTAssertTrue(r.roleExplanation.contains("doesn't send messages of its own"))

        let at = Date()
        store.repeaterStatus(prefix: hilltop.prefix, .init(uptimeSeconds: 7200, packetsRelayed: 321, noiseFloor: -110,
                                                           batteryMillivolts: 4120, at: at))
        let updated = try XCTUnwrap(store.saved.first { $0.id == r.id })
        XCTAssertEqual(updated.repeater?.packetsRelayed, 321)
        XCTAssertEqual(updated.batteryVolts, 4.12)
        XCTAssertEqual(updated.lastHeard, at)
    }

    func testPersistenceRoundTrip() throws {
        let store = MyMeshStore(file: file)
        store.connected(meshtastic: meshtasticSession(), bluetoothID: UUID())
        store.connected(meshcore: .demo(), bluetoothID: nil)
        store.adminLogin(hilltop, companion: MeshCoreSession.demo().me)
        store.repeaterStatus(prefix: hilltop.prefix, .init(uptimeSeconds: 99, at: Date()))
        store.save()
        let again = MyMeshStore(file: file)
        XCTAssertEqual(again.saved.count, 3)
        XCTAssertEqual(again.saved, store.saved)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("secret"), "no keys or passwords in the file")
    }

    func testTolerantDecode() throws {
        let json = """
        {"nodes": [
          {"network": "meshcore", "nodeID": "0102030405AA"},
          {"network": "zigbee", "nodeID": "x"},
          {"network": "meshtastic", "nodeID": "!0000beef", "name": "Trail", "batteryVolts": "lots", "newField": [1, 2],
           "radio": {"region": "US 915", "slot": "twenty"}, "repeater": 5}
        ]}
        """
        try Data(json.utf8).write(to: file)
        let store = MyMeshStore(file: file)
        XCTAssertEqual(store.saved.count, 2, "the unreadable node is skipped, not the file")
        let mc = try XCTUnwrap(store.saved.first { $0.network == .meshcore })
        XCTAssertEqual(mc.nodeID, "0102030405aa")
        XCTAssertEqual(mc.name, "0102030405aa")
        XCTAssertEqual(mc.origin, .manual)
        let mt = try XCTUnwrap(store.saved.first { $0.network == .meshtastic })
        XCTAssertEqual(mt.name, "Trail")
        XCTAssertNil(mt.batteryVolts)
        XCTAssertEqual(mt.radio?.region, "US 915")
        XCTAssertNil(mt.radio?.slot)
        XCTAssertNil(mt.repeater)
    }

    func testUnreadableFileIsKeptAside() throws {
        try Data("not json".utf8).write(to: file)
        let store = MyMeshStore(file: file)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("bad").path))
    }

    func testPracticeNodesShownButNeverSaved() throws {
        let radio = Radio()
        let store = MyMeshStore(file: file)
        store.attach(radio: radio)
        radio.startPractice()
        defer { radio.stopPractice() }
        XCTAssertTrue(store.isPracticeRunning)
        let shown = store.nodes
        XCTAssertEqual(shown.count, 3)
        XCTAssertTrue(shown.allSatisfy { $0.origin == .practice })
        XCTAssertEqual(Set(shown.map(\.roleTitle)), ["Companion", "Repeater", "Client"])
        XCTAssertTrue(store.isConnected(shown[0]), "the practice handheld counts as connected, so it sorts first")
        XCTAssertTrue(store.saved.isEmpty, "the practice mesh's connection isn't recorded")
        store.markMine(shown[1])
        XCTAssertTrue(store.saved.isEmpty)
        store.save()
        XCTAssertTrue(MyMeshStore(file: file).saved.isEmpty)
        radio.stopPractice()
        XCTAssertTrue(store.nodes.isEmpty)
    }

    func testAgoIsPlainEnglish() {
        let now = Date()
        XCTAssertEqual(OwnedNode.ago(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(OwnedNode.ago(now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(OwnedNode.ago(now.addingTimeInterval(-3600), now: now), "1 hour ago")
        XCTAssertEqual(OwnedNode.ago(now.addingTimeInterval(-2 * 86_400), now: now), "2 days ago")
        XCTAssertEqual(OwnedNode.ago(nil, now: now), "never")
    }
}
