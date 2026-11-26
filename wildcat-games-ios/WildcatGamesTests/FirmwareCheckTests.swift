import XCTest
@testable import WildcatGames

final class FirmwareVersionTests: XCTestCase {
    func testMeshtasticVersionWithCommit() {
        let v = FirmwareVersion("2.7.15.567b8ea")
        XCTAssertEqual(v?.numbers, [2, 7, 15])
        XCTAssertEqual(v?.build, "567b8ea")
        XCTAssertEqual(v?.description, "2.7.15")
    }

    func testMeshtasticCommitThatIsAllDigitsIsNotAFourthPart() {
        XCTAssertEqual(FirmwareVersion("2.7.15.1234567")?.numbers, [2, 7, 15])
        XCTAssertEqual(FirmwareVersion("2.7.15.1234567")?.build, "1234567")
    }

    func testMeshCoreOfficialAndSelfBuiltStrings() {
        XCTAssertEqual(FirmwareVersion("v1.17.1-d929643")?.numbers, [1, 17, 1])
        XCTAssertEqual(FirmwareVersion("v1.17.1-d929643")?.build, "d929643")
        XCTAssertEqual(FirmwareVersion("v1.17.1")?.numbers, [1, 17, 1])
        XCTAssertNil(FirmwareVersion("v1.17.1")?.build)
        XCTAssertEqual(FirmwareVersion("1.17.1 (14 Aug 2026)")?.numbers, [1, 17, 1])
        XCTAssertEqual(FirmwareVersion("1.17.1 (14 Aug 2026)")?.build, "14 Aug 2026")
        XCTAssertEqual(FirmwareVersion("V1.12")?.numbers, [1, 12])
        XCTAssertEqual(FirmwareVersion("  v1.9.0-b92d9bd \n")?.numbers, [1, 9, 0])
    }

    func testReleaseTags() {
        XCTAssertEqual(FirmwareVersion("companion-v1.17.1")?.numbers, [1, 17, 1])
        XCTAssertEqual(FirmwareVersion("v2.7.26.54e0d8d")?.numbers, [2, 7, 26])
    }

    func testNotVersions() {
        for s in ["", "   ", "practice", "v", "2", "abc.def", "1.", ".1.2", "2.x", "99999.1.1", String(repeating: "1.", count: 60)] {
            XCTAssertNil(FirmwareVersion(s), s)
        }
        XCTAssertNil(FirmwareVersion(nil))
    }

    func testOrdering() throws {
        let a = try XCTUnwrap(FirmwareVersion("2.7.9.70724be"))
        let b = try XCTUnwrap(FirmwareVersion("2.7.15.567b8ea"))
        let c = try XCTUnwrap(FirmwareVersion("2.8.0.47db0e3"))
        XCTAssertLessThan(a, b)          // numeric, not string, order
        XCTAssertLessThan(b, c)
        XCTAssertEqual(FirmwareVersion("2.7.15.aaaaaaa"), FirmwareVersion("2.7.15.bbbbbbb"))   // commit ignored
        XCTAssertEqual(FirmwareVersion("v1.17"), FirmwareVersion("1.17.0"))
        XCTAssertLessThan(try XCTUnwrap(FirmwareVersion("v1.9.1")), try XCTUnwrap(FirmwareVersion("v1.17.1")))
    }

    func testTestedPatterns() throws {
        let any27 = try XCTUnwrap(FirmwareVersion(pattern: "2.7.x"))
        XCTAssertEqual(any27.numbers, [2, 7])
        XCTAssertTrue(try XCTUnwrap(FirmwareVersion("2.7.26.54e0d8d")).isWithin(any27))
        XCTAssertTrue(try XCTUnwrap(FirmwareVersion("2.6.11.60ec05e")).isWithin(any27))
        XCTAssertFalse(try XCTUnwrap(FirmwareVersion("2.8.1.8e6a88d")).isWithin(any27))

        let mc = try XCTUnwrap(FirmwareVersion(pattern: "1.17.1"))
        XCTAssertTrue(try XCTUnwrap(FirmwareVersion("v1.17.1-d929643")).isWithin(mc))
        XCTAssertTrue(try XCTUnwrap(FirmwareVersion("v1.17")).isWithin(mc))
        XCTAssertFalse(try XCTUnwrap(FirmwareVersion("v1.17.2")).isWithin(mc))
        XCTAssertFalse(try XCTUnwrap(FirmwareVersion("v1.18.0")).isWithin(mc))
    }
}

final class FirmwareVerdictTests: XCTestCase {
    private var manifest: FirmwareManifest!

    override func setUpWithError() throws {
        manifest = try FirmwareManifest.decode(Self.fixture())
    }

    static func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: FirmwareVerdictTests.self).url(forResource: "firmware-sample", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func verdict(_ n: MeshNetwork, _ current: String?, practice: Bool = false) -> FirmwareVerdict {
        FirmwareVerdict.evaluate(n, current: current, practice: practice, manifest: manifest)
    }

    func testFixtureDecodesAndIgnoresUnknownFields() throws {
        XCTAssertEqual(manifest.schema, 1)
        XCTAssertEqual(manifest.network(.meshtastic)?.latest.version, "2.7.26")
        XCTAssertEqual(manifest.network(.meshcore)?.latest.full, "v1.17.1-d929643")
        XCTAssertEqual(manifest.network(.meshcore)?.tested?.version, "1.17.1")
        XCTAssertEqual(manifest.network(.meshcore)?.latest.pageURL?.host, "github.com")
        XCTAssertEqual(manifest.network(.meshtastic)?.latest.dateText?.contains("2026"), true)
        // A release day stays that day in every time zone (24 June, not the 23rd west of UTC).
        XCTAssertEqual(manifest.network(.meshtastic)?.latest.dateText?.contains("24"), true)
    }

    func testTheGeneratedManifestShapeDecodes() throws {
        // Only the fields the app needs are required.
        let minimal = #"{"schema":2,"networks":{"meshcore":{"latest":{"version":"1.18.0"}}}}"#
        let m = try FirmwareManifest.decode(Data(minimal.utf8))
        XCTAssertEqual(m.network(.meshcore)?.latest.version, "1.18.0")
        XCTAssertNil(m.network(.meshtastic))
        XCTAssertNil(m.network(.meshcore)?.latest.pageURL)
    }

    func testOnlyHTTPSReleasePagesOpen() {
        var r = FirmwareManifest.Release(version: "1.0.0")
        r.url = "http://example.com/x"
        XCTAssertNil(r.pageURL)
        r.url = "javascript:alert(1)"
        XCTAssertNil(r.pageURL)
        r.url = "https://github.com/meshtastic/firmware/releases/tag/v2.7.26.54e0d8d"
        XCTAssertNotNil(r.pageURL)
    }

    func testUpdateAvailable() {
        let v = verdict(.meshtastic, "2.7.15.567b8ea")
        XCTAssertEqual(v.status, .updateAvailable)
        XCTAssertEqual(v.headline, "Update available: 2.7.15 → 2.7.26")
        XCTAssertTrue(v.wantsAttention)
        XCTAssertFalse(v.untested)

        let mc = verdict(.meshcore, "v1.14.1-467959c")
        XCTAssertEqual(mc.status, .updateAvailable)
        XCTAssertEqual(mc.headline, "Update available: 1.14.1 → 1.17.1")
    }

    func testUpToDateOnBothNetworks() {
        XCTAssertEqual(verdict(.meshtastic, "2.7.26.54e0d8d").status, .upToDate)
        XCTAssertEqual(verdict(.meshcore, "v1.17.1-d929643").status, .upToDate)
        XCTAssertEqual(verdict(.meshcore, "v1.17.1").status, .upToDate)            // self-built
        XCTAssertEqual(verdict(.meshtastic, "2.7.26.0000000").status, .upToDate)   // a different commit is the same version
        XCTAssertFalse(verdict(.meshcore, "v1.17.1").wantsAttention)
    }

    func testAheadOfStable() {
        let v = verdict(.meshtastic, "2.8.1.8e6a88d")
        XCTAssertEqual(v.status, .aheadOfStable)
        XCTAssertEqual(v.headline, "Newer than the latest stable (2.7.26)")
        XCTAssertTrue(v.untested)
        XCTAssertTrue(v.detail?.contains("2.7.x") == true)

        // A 2.7 alpha past the stable one is still within what Wildcat tested.
        let alpha = verdict(.meshtastic, "2.7.27.abcdef0")
        XCTAssertEqual(alpha.status, .aheadOfStable)
        XCTAssertFalse(alpha.untested)
    }

    func testNewerThanTestedWhenTheStableReleaseMovesOn() throws {
        var m = try XCTUnwrap(manifest)
        m.networks["meshcore"]?.latest.version = "1.18.0"
        let latest = FirmwareVerdict.evaluate(.meshcore, current: "v1.18.0-1234abc", practice: false, manifest: m)
        XCTAssertEqual(latest.status, .newerThanTested)
        XCTAssertTrue(latest.untested)
        XCTAssertFalse(latest.wantsAttention)

        // Behind a stable release that's newer than tested: an update, with a note about testing.
        let behind = FirmwareVerdict.evaluate(.meshcore, current: "v1.16.0", practice: false, manifest: m)
        XCTAssertEqual(behind.status, .updateAvailable)
        XCTAssertTrue(behind.detail?.contains("tested up to 1.17.1") == true)
    }

    func testUnknownVersions() {
        let none = verdict(.meshtastic, nil)
        XCTAssertEqual(none.status, .unknown)
        XCTAssertEqual(none.headline, "Unknown version")
        XCTAssertTrue(none.detail?.contains("didn't report") == true)

        let odd = verdict(.meshcore, "custom build")
        XCTAssertEqual(odd.status, .unknown)
        XCTAssertTrue(odd.detail?.contains("\"custom build\"") == true)
        XCTAssertTrue(odd.detail?.contains("1.17.1") == true)
    }

    func testPracticeNodesNeverClaimAnUpdate() {
        // The practice MeshCore node reports v1.17.1, the practice Meshtastic node nothing at all.
        for (n, fw) in [(MeshNetwork.meshcore, "v1.17.1" as String?), (.meshtastic, nil), (.meshtastic, "1.0.0")] {
            let v = verdict(n, fw, practice: true)
            XCTAssertEqual(v.status, .practice)
            XCTAssertFalse(v.wantsAttention)
            XCTAssertTrue(v.headline.contains("Practice"))
        }
    }

    func testANetworkMissingFromTheList() throws {
        let m = try FirmwareManifest.decode(Data(#"{"schema":1,"networks":{}}"#.utf8))
        let v = FirmwareVerdict.evaluate(.meshcore, current: "v1.17.1", practice: false, manifest: m)
        XCTAssertEqual(v.status, .unknown)
        XCTAssertTrue(v.headline.contains("MeshCore"))
    }

    func testSameWordingForBothNetworks() {
        // Equal treatment: the same situations read the same, only the name changes.
        let mt = verdict(.meshtastic, "2.7.26.54e0d8d"), mc = verdict(.meshcore, "v1.17.1-d929643")
        XCTAssertEqual(mt.headline, mc.headline)
        XCTAssertEqual(mt.detail?.replacingOccurrences(of: "2.7.26", with: "X").replacingOccurrences(of: "Meshtastic", with: "N"),
                       mc.detail?.replacingOccurrences(of: "1.17.1", with: "X").replacingOccurrences(of: "MeshCore", with: "N"))
    }
}

@MainActor
final class FirmwareCheckTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "FirmwareCheckTests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func response(_ code: Int, _ url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testNothingIsFetchedUntilAsked() {
        var calls = 0
        let c = FirmwareCheck(defaults: defaults) { url in calls += 1; return (Data(), self.response(200, url)) }
        XCTAssertNil(c.manifest)
        XCTAssertNil(c.verdict(.meshtastic, current: "2.7.15", practice: false))
        XCTAssertEqual(calls, 0)
    }

    func testCheckFetchesTheSiteListAndKeepsIt() async throws {
        let data = try FirmwareVerdictTests.fixture()
        var asked: [URL] = []
        let c = FirmwareCheck(defaults: defaults) { url in asked.append(url); return (data, self.response(200, url)) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        await c.check(now: now)
        XCTAssertEqual(asked, [FirmwareCheck.manifestURL])
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.checked, now)
        XCTAssertEqual(c.verdict(.meshtastic, current: "2.7.15.567b8ea", practice: false)?.status, .updateAvailable)

        // The next launch has the answer without asking again.
        let again = FirmwareCheck(defaults: defaults) { _ in XCTFail("no fetch on launch"); throw URLError(.badURL) }
        XCTAssertEqual(again.manifest, c.manifest)
        XCTAssertEqual(again.checked, now)
    }

    func testTheSiteAddressIsTheDefault() {
        XCTAssertEqual(FirmwareCheck.defaultURL.absoluteString, "https://redthoroughbred.github.io/wildcat/firmware.json")
        if UserDefaults.standard.string(forKey: "FirmwareManifestURL") == nil {
            XCTAssertEqual(FirmwareCheck.manifestURL, FirmwareCheck.defaultURL)
        }
    }

    func testFailuresKeepTheLastGoodList() async throws {
        let data = try FirmwareVerdictTests.fixture()
        var next: (URL) throws -> (Data, URLResponse) = { (data, self.response(200, $0)) }
        let c = FirmwareCheck(defaults: defaults) { try next($0) }
        await c.check()
        let good = c.manifest
        XCTAssertNotNil(good)

        next = { (Data("Not found".utf8), self.response(404, $0)) }
        await c.check()
        XCTAssertEqual(c.state, .failed("The Wildcat website answered 404. Try again later."))
        XCTAssertEqual(c.manifest, good)

        next = { (Data("<html>captive portal</html>".utf8), self.response(200, $0)) }
        await c.check()
        guard case .failed(let why) = c.state else { return XCTFail("expected a failure") }
        XCTAssertTrue(why.contains("firmware list"))
        XCTAssertEqual(c.manifest, good)

        next = { _ in throw URLError(.notConnectedToInternet) }
        await c.check()
        XCTAssertEqual(c.state, .failed("No internet connection. Try again when you have one."))

        next = { (Data(repeating: 0x20, count: FirmwareCheck.maxBytes + 1), self.response(200, $0)) }
        await c.check()
        guard case .failed = c.state else { return XCTFail("an oversized answer isn't a list") }
        XCTAssertEqual(c.manifest, good)
    }

    func testALocalFileWorksForDebugBuilds() async throws {
        // What `-FirmwareManifestURL /path/firmware.json` loads: a file URL, no HTTP status.
        let data = try FirmwareVerdictTests.fixture()
        let c = FirmwareCheck(defaults: defaults) { url in (data, URLResponse(url: url, mimeType: "application/json",
                                                                               expectedContentLength: data.count, textEncodingName: nil)) }
        await c.check()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.manifest?.network(.meshcore)?.latest.version, "1.17.1")
    }
}
