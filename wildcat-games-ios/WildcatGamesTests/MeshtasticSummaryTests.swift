import XCTest
import WildcatRadioCore
@testable import WildcatGames

final class MeshtasticSummaryTests: XCTestCase {
    func testSentence() {
        let s = MeshtasticSummary.sentence(heard: 5, direct: 3, channelUse: 4, needsRegion: false, practice: false)
        XCTAssertEqual(s.plain, "All good. Hearing 5 nodes, 3 of them direct.")
        XCTAssertEqual(s.emphasis, "Hearing 5 nodes")
        XCTAssertEqual(MeshtasticSummary.sentence(heard: 1, direct: 1, channelUse: nil, needsRegion: false, practice: false).plain,
                       "All good. Hearing 1 node, direct.")
        XCTAssertEqual(MeshtasticSummary.sentence(heard: 2, direct: 2, channelUse: nil, needsRegion: false, practice: false).tail,
                       ", all of them direct.")
        XCTAssertEqual(MeshtasticSummary.sentence(heard: 0, direct: 0, channelUse: nil, needsRegion: false, practice: false).plain,
                       "Connected. Nobody heard yet.")
        XCTAssertTrue(MeshtasticSummary.sentence(heard: 3, direct: 0, channelUse: 45, needsRegion: false, practice: false)
            .lead.hasPrefix("Crowded"))
        XCTAssertTrue(MeshtasticSummary.sentence(heard: 3, direct: 1, channelUse: 5, needsRegion: true, practice: false)
            .plain.contains("No region set"))
    }

    func testChannelWordAndUptime() {
        XCTAssertEqual(MeshtasticSummary.channelWord(2.1), "Quiet channel")
        XCTAssertEqual(MeshtasticSummary.channelWord(30), "Busy channel")
        XCTAssertEqual(MeshtasticSummary.channelWord(.nan), "No report yet")
        XCTAssertEqual(MeshtasticSummary.uptime(42 * 60).value, "42")
        XCTAssertEqual(MeshtasticSummary.uptime(5 * 3600 + 60).unit, "h")
        XCTAssertEqual(MeshtasticSummary.uptime(3 * 86_400 + 4 * 3600).value, "3d 04")
        XCTAssertEqual(MeshtasticSummary.uptime(-5).value, "0")
    }

    func testSignedUsesTrueMinus() {
        XCTAssertEqual(MeshtasticSummary.signed(-3.25, digits: 2), "−3.25")
        XCTAssertEqual(MeshtasticSummary.signed(6), "6.0")
        XCTAssertEqual(MeshtasticSummary.signed(.infinity), "—")
    }

    /// The heard rows and Best SNR readout read like the MeshCore tab's: no trailing ".0", up to two decimals.
    func testNumberAndDBMatchMeshCoreRows() {
        XCTAssertEqual(MeshtasticSummary.number(9), "9")
        XCTAssertEqual(MeshtasticSummary.number(9.5), "9.5")
        XCTAssertEqual(MeshtasticSummary.number(9.75), "9.8")
        XCTAssertEqual(MeshtasticSummary.number(.nan), "—")
        XCTAssertEqual(MeshtasticSummary.db(6), "6 dB")
        XCTAssertEqual(MeshtasticSummary.db(-3.25), "−3.25 dB")
        XCTAssertEqual(MeshtasticSummary.db(-3.25), MeshCoreFormat.db(-3.25))
    }

    func testInfrastructureRoles() {
        XCTAssertTrue(MeshtasticSummary.isInfrastructure(role: DeviceRole.router.rawValue))
        XCTAssertTrue(MeshtasticSummary.isInfrastructure(role: DeviceRole.repeater.rawValue))
        XCTAssertFalse(MeshtasticSummary.isInfrastructure(role: DeviceRole.client.rawValue))
        XCTAssertFalse(MeshtasticSummary.isInfrastructure(role: nil))
    }

    func testBestSNROnlyDirect() {
        var a = NodeInfo(num: NodeNum(1), snr: 4); a.hopsAway = 0
        var b = NodeInfo(num: NodeNum(2), snr: 12); b.hopsAway = 2
        var c = NodeInfo(num: NodeNum(3), snr: 9); c.hopsAway = 0; c.viaMQTT = true
        var me = NodeInfo(num: NodeNum(4), snr: 20); me.hopsAway = 0
        XCTAssertEqual(MeshtasticSummary.bestSNR([a, b, c, me], excluding: NodeNum(4)), 4)
        XCTAssertNil(MeshtasticSummary.bestSNR([b], excluding: nil))
    }

    func testRingStep() {
        XCTAssertEqual(MeshtasticSummary.ringStep(farthest: 0), 1000)
        XCTAssertEqual(MeshtasticSummary.ringStep(farthest: 800), 500)
        XCTAssertEqual(MeshtasticSummary.ringStep(farthest: 2800), 1000)
        XCTAssertEqual(MeshtasticSummary.ringStep(farthest: 2900), 2000)   // needs a little room past the last ring
        XCTAssertEqual(MeshtasticSummary.ringStep(farthest: 4000), 2000)
        XCTAssertEqual(MeshtasticSummary.ringStep(farthest: 1e9), 50_000)
    }

    func testCacheKeepsNamesNotKeys() throws {
        var s = MeshSession(configID: 1)
        _ = s.handle(.myInfo(NodeNum(0x0A)))
        _ = s.handle(.nodeInfo(NodeInfo(num: NodeNum(0x0A), longName: "Trail Pack", shortName: "TPK")))
        var heard = NodeInfo(num: NodeNum(0x0B), longName: "MAYA", shortName: "MAYA", snr: 7)
        heard.lastHeard = Date(timeIntervalSince1970: 1000)
        heard.hopsAway = 0
        _ = s.handle(.nodeInfo(heard))
        _ = s.handle(.channel(ChannelInfo(index: 0, name: "", role: .primary, settings: Data([1, 2, 3]))))
        _ = s.handle(.channel(ChannelInfo(index: 1, name: "WGHUNT", role: .secondary, settings: Data([4, 5, 6]))))
        let cache = try XCTUnwrap(MeshtasticCache(session: s, now: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(cache.longName, "Trail Pack")
        XCTAssertEqual(cache.channels.map(\.name), ["", "WGHUNT"])
        XCTAssertEqual(cache.heard.map(\.longName), ["MAYA"])
        XCTAssertEqual(cache.heard.first?.snr, 7)

        let data = try JSONEncoder().encode(cache)
        XCTAssertEqual(try JSONDecoder().decode(MeshtasticCache.self, from: data), cache)
        // Channel settings (which hold the keys) are never written.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("settings"))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MeshtasticSummaryTests"))
        defaults.removePersistentDomain(forName: "MeshtasticSummaryTests")
        XCTAssertNil(MeshtasticCache.load(defaults))
        cache.save(defaults)
        XCTAssertEqual(MeshtasticCache.load(defaults), cache)
        defaults.removePersistentDomain(forName: "MeshtasticSummaryTests")
    }

    func testCacheNeedsMyNode() {
        XCTAssertNil(MeshtasticCache(session: MeshSession(configID: 1)))
    }
}
