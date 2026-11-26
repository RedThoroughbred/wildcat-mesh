import XCTest
import WildcatRadioCore
@testable import WildcatGames

@MainActor
final class HuntModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var radio: Radio!
    private var hunt: HuntModel!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "hunt-tests-\(UUID())")
        radio = Radio()
        hunt = HuntModel(radio: radio, defaults: defaults)
        radio.startPractice()
    }

    override func tearDown() async throws {
        radio.stopPractice()
    }

    private func foxPacket(rssi: Int) -> MeshPacket {
        MeshPacket(from: PracticeMesh.fox, to: .broadcast, id: 1, rxSNR: 5, rxRSSI: rssi, hopLimit: 3, hopStart: 3,
                   portnum: .position)
    }

    private func denText(_ text: String) -> MeshPacket {
        MeshPacket(from: PracticeMesh.den, to: PracticeMesh.me, channel: 1, id: 2, portnum: .text, text: text)
    }

    func testJoinUsesTheHuntChannelAndResolvesTheFoxByName() {
        hunt.playerName = "maya"
        hunt.join()
        XCTAssertEqual(hunt.stage, .joining)
        XCTAssertEqual(hunt.huntChannel, 1)
        XCTAssertEqual(hunt.log.last?.text, "WG JOIN FOX7 MAYA")
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 2 HUNTING LIVE FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>")))
        XCTAssertEqual(hunt.stage, .hunting)
        XCTAssertEqual(hunt.fox, PracticeMesh.fox)
        XCTAssertEqual(hunt.foxLabel(), "ZEUZ")
        XCTAssertEqual(hunt.den, PracticeMesh.den)
    }

    func testFoxByShortHex() {
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 2 HUNTING LIVE FOX 6b18")))
        XCTAssertEqual(hunt.fox, PracticeMesh.fox)
    }

    func testDirectReadingsAreReportedToTheDen() {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        hunt.clock = { now }
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 1 HUNTING LIVE FOX ZEUZ")))
        hunt.handle(.packet(foxPacket(rssi: -97)))
        XCTAssertEqual(hunt.tracker?.samples.count, 1)
        XCTAssertEqual(hunt.log.last?.text, "WG SIG FOX7 -97 5.0")
        now += 2
        hunt.handle(.packet(foxPacket(rssi: -96)))
        XCTAssertEqual(hunt.log.filter { $0.direction == .sent }.count, 1, "throttled")
        now += 6
        hunt.handle(.packet(foxPacket(rssi: -89)))
        XCTAssertEqual(hunt.log.last?.text, "WG SIG FOX7 -89 5.0", "a jump is reported")
        XCTAssertEqual(hunt.tracker?.trend, .warmer)
    }

    func testRepliesDrivenStages() {
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 1 HUNTING LIVE FOX ZEUZ")))
        hunt.handle(.packet(denText("WG W FOX7 WARMER -94>-88 BEST -85 BRG 045")))
        guard case .warmth(_, .warmer, _, _, _, 45, false) = hunt.warmth else { return XCTFail("\(String(describing: hunt.warmth))") }
        hunt.handle(.packet(denText("WG NO FOUND FOX7 BADCODE 2/5")))
        XCTAssertEqual(hunt.notice, "Wrong code (2/5 tries used).")
        hunt.handle(.packet(denText("WG OK FOUND FOX7 #1 +175 CODE+RF-B T+14M")))
        XCTAssertEqual(hunt.stage, .found(place: 1, points: 175, proofs: [.code, .rfAttested], minutes: 14))
        hunt.handle(.packet(denText("WG END FOX7 MAYA WINS 1/2 FOUND")))
        XCTAssertEqual(hunt.stage, .ended(winner: "MAYA", found: 1, total: 2))
    }

    func testATimeUpEndSaysTimeRanOut() {
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 2 HUNTING LIVE FOX ZEUZ")))
        hunt.handle(.packet(denText("WG END FOX7 NO FINDS 0/2 FOUND · TIME UP")))
        XCTAssertEqual(hunt.stage, .ended(winner: nil, found: 0, total: 2))
        XCTAssertTrue(hunt.endedOnTime)
        hunt.reset()
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 2 HUNTING LIVE FOX ZEUZ")))
        hunt.handle(.packet(denText("WG END FOX7 MAYA WINS 1/2 FOUND")))
        XCTAssertFalse(hunt.endedOnTime)
    }

    private func timedInvite(_ minutes: Int?) -> HuntInvite {
        HuntInvite(code: "FOX7", channel: ChannelSettings(name: "WGHUNT", psk: Data([1])).raw, fox: PracticeMesh.fox,
                   host: PracticeMesh.den, limitMinutes: minutes)
    }

    func testTheCountdownStartsAtTheGo() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        hunt.clock = { now }
        hunt.join(invite: timedInvite(20))
        XCTAssertEqual(hunt.timeLimit, 1200)
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 1 HUNTING LOBBY FOX ZEUZ")))
        XCTAssertEqual(hunt.timeRemaining(at: now.addingTimeInterval(500)), 1200, "the whole limit until the GO")
        XCTAssertNil(hunt.deadline)
        hunt.handle(.packet(denText("WG GO FOX7 HUNT IS LIVE · FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>")))
        XCTAssertEqual(hunt.deadline, now.addingTimeInterval(1200))
        XCTAssertEqual(hunt.timeRemaining(at: now.addingTimeInterval(200)), 1000)
        XCTAssertEqual(hunt.timeRemaining(at: now.addingTimeInterval(5000)), 0)
    }

    func testJoiningATimedHuntAlreadyLiveAsksHowLongItHasRun() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        hunt.clock = { now }
        hunt.join(invite: timedInvite(20))
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 2 HUNTING LIVE FOX ZEUZ")))
        XCTAssertEqual(hunt.log.last { $0.direction == .sent }?.text, "WG HUNT")
        XCTAssertNil(hunt.timeRemaining(at: now), "unknown until the host says")
        hunt.handle(.packet(denText("WG HUNT FOX7 LIVE T+5M 2 HUNTERS 0 FOUND FOX ZEUZ")))
        XCTAssertEqual(hunt.timeRemaining(at: now), 1200 - 330, "the middle of the fifth minute")
    }

    func testNoLimitNoCountdown() {
        hunt.join(invite: timedInvite(nil))
        hunt.handle(.packet(denText("WG OK JOIN FOX7 MAYA 2 HUNTING LIVE FOX ZEUZ")))
        XCTAssertNil(hunt.timeRemaining(at: Date()))
        XCTAssertEqual(hunt.log.last { $0.direction == .sent }?.text, "WG JOIN FOX7", "no status question without a limit")
    }

    func testRejectionsDontAssumeADen() {
        XCTAssertEqual(HuntModel.explain(verb: "JOIN", reason: "NO HUNT"), "No hunt with that code is running.")
        XCTAssertEqual(HuntModel.explain(verb: "SIG", reason: "FORMAT"), "The host didn't understand that reading.")
        XCTAssertEqual(HuntModel.explain(verb: "FOUND", reason: "WHATEVER"), "The host said no: FOUND WHATEVER")
        for r in ["NO HUNT", "FORMAT", "X", "LOCKED", "OVER"] {
            XCTAssertFalse(HuntModel.explain(verb: "FOUND", reason: r).contains("Den"), r)
        }
    }

    func testRepliesForSomeoneElseAreIgnored() {
        let other = MeshPacket(from: PracticeMesh.den, to: NodeNum(0x1234), channel: 1, id: 3, portnum: .text,
                               text: "WG OK FOUND FOX7 #1 +100 CODE T+3M")
        hunt.handle(.packet(other))
        XCTAssertEqual(hunt.stage, .idle)
        XCTAssertFalse(hunt.log.contains { $0.direction == .received })
    }

    func testRejectedJoinReturnsToIdle() {
        hunt.join()
        hunt.handle(.packet(denText("WG NO JOIN FOX7 OVER")))
        XCTAssertEqual(hunt.stage, .idle)
        XCTAssertEqual(hunt.notice, "That hunt is over.")
    }

    func testPracticeDenAnswersLikeTheReferee() async throws {
        hunt.join()
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(hunt.stage, .hunting)
        hunt.claim(code: "0000")
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(hunt.notice, "Wrong code (1/5 tries used).")
        hunt.claim(code: PracticeMesh.code)
        try await Task.sleep(for: .milliseconds(1300))
        guard case .found(1, _, let proofs, _) = hunt.stage else { return XCTFail("\(hunt.stage)") }
        XCTAssertTrue(proofs.contains(.code))
    }

    func testJoinGivesUpWhenNobodyAnswers() async throws {
        hunt.joinTimeout = .milliseconds(50)
        hunt.join()
        XCTAssertEqual(hunt.stage, .joining)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(hunt.stage, .idle)
        XCTAssertNotNil(hunt.notice)
    }

    func testCancelJoinStopsWaiting() async throws {
        hunt.joinTimeout = .milliseconds(50)
        hunt.join()
        hunt.cancelJoin()
        XCTAssertEqual(hunt.stage, .idle)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(hunt.notice, "a cancelled join doesn't time out later")
    }
}
