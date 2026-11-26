import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// A phone-hosted hunt survives the app closing: saved, picked up within 12 hours,
/// never from a finished, stale or broken file.
@MainActor
final class HostedHuntTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent(HostedHuntSave.fileName) }
    private let fox = NodeNum(0xA303_B917), maya = NodeNum(0x1111_1111)
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-hunt-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        SaveFile.flush()
        try? FileManager.default.removeItem(at: dir)
    }

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Live since t0 + 10 with a 20-minute limit: a reading, a wrong code.
    private func liveReferee() -> FoxReferee {
        let t = t0.timeIntervalSince1970
        var r = FoxReferee()
        r.handle(.create(t: t, fox: fox, foxCode: "4417", code: "FOXQ7", foxLabel: "ZEUZ", timeLimit: 1200))
        r.handle(.join(t: t + 1, node: maya, name: "maya", channel: 1))
        r.handle(.start(t: t + 10))
        r.handle(.sig(t: t + 20.25, node: maya, rssi: -91.5, snr: 4.25))
        r.handle(.found(t: t + 30, node: maya, code: "0000"))
        return r
    }

    private func save(_ r: FoxReferee, at date: Date) -> HostedHuntSave {
        let channel = ChannelSettings(name: "WGHUNT", psk: Data(repeating: 7, count: 32)).raw
        return HostedHuntSave(savedAt: date, referee: r,
                              invite: HuntInvite(code: "FOXQ7", channel: channel, fox: fox, host: NodeNum(0xA038_8880), limitMinutes: 20))
    }

    // MARK: The save file

    func testSaveRoundTripsExactly() throws {
        let s = save(liveReferee(), at: t0.addingTimeInterval(31))
        s.writeNow(to: url)
        let back = try XCTUnwrap(HostedHuntSave.load(from: url, now: t0.addingTimeInterval(90)))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.referee.board, s.referee.board)
        XCTAssertEqual(back.invite?.timeLimit, 1200)
        // The restored referee rules exactly as the original would.
        var a = s.referee, b = back.referee
        let next = FoxReferee.Event.found(t: t0.timeIntervalSince1970 + 100, node: maya, code: "4417")
        XCTAssertEqual(a.handle(next), b.handle(next))
        XCTAssertEqual(a.board, b.board)
    }

    func testOlderThanTwelveHoursIsDropped() {
        save(liveReferee(), at: t0).writeNow(to: url)
        XCTAssertNotNil(HostedHuntSave.load(from: url, now: t0.addingTimeInterval(12 * 3600 - 60)))
        XCTAssertNil(HostedHuntSave.load(from: url, now: t0.addingTimeInterval(12 * 3600 + 1)))
        XCTAssertFalse(exists, "a stale save is deleted")
    }

    func testAFinishedHuntIsNotPickedUp() {
        var r = liveReferee()
        r.handle(.end(t: t0.timeIntervalSince1970 + 60))
        save(r, at: t0).writeNow(to: url)
        XCTAssertNil(HostedHuntSave.load(from: url, now: t0.addingTimeInterval(61)))
        XCTAssertFalse(exists)
        XCTAssertFalse(save(FoxReferee(), at: t0).isRestorable(at: t0), "no hunt at all")
    }

    func testALobbyIsPickedUp() {
        var r = FoxReferee()
        r.handle(.create(t: t0.timeIntervalSince1970, fox: fox, foxCode: "4417"))
        XCTAssertTrue(save(r, at: t0).isRestorable(at: t0.addingTimeInterval(3600)))
    }

    func testCorruptOrForeignFilesAreDiscardedNeverRestored() throws {
        for bytes in [Data("{\"version\":1,\"referee\":".utf8), Data([0xFF, 0x00, 0x13]), Data("[]".utf8),
                      Data("{\"version\":1,\"savedAt\":1790000000,\"referee\":{\"hunters\":[],\"finds\":[],\"events\":[{\"zap\":{}}]}}".utf8)] {
            try bytes.write(to: url)
            XCTAssertNil(HostedHuntSave.load(from: url, now: t0))
            XCTAssertFalse(exists, "set aside, so the next save starts clean")
        }
        var newer = save(liveReferee(), at: t0)
        newer.version = 99
        newer.writeNow(to: url)
        XCTAssertNil(HostedHuntSave.load(from: url, now: t0), "a newer app's save is not guessed at")
        XCTAssertNil(HostedHuntSave.load(from: dir.appendingPathComponent("missing.json"), now: t0))
    }

    // MARK: The phone referee

    func testTheRefereePicksUpASavedHuntAtLaunch() {
        let s = save(liveReferee(), at: t0.addingTimeInterval(31))
        s.writeNow(to: url)
        let host = PhoneReferee(radio: Radio(), saveURL: url, now: t0.addingTimeInterval(300))
        XCTAssertTrue(host.isHosting)
        XCTAssertTrue(host.resumed)
        XCTAssertEqual(host.referee, s.referee)
        XCTAssertEqual(host.invite, s.invite)
        XCTAssertEqual(host.timeRemaining(at: t0.addingTimeInterval(110)), 1100)
    }

    func testNothingToPickUpStartsEmpty() {
        let host = PhoneReferee(radio: Radio(), saveURL: url, now: t0)
        XCTAssertFalse(host.isHosting)
        XCTAssertFalse(host.resumed)
    }

    func testAHostedHuntIsSavedAsItChangesAndForgottenWhenItEnds() async throws {
        let radio = Radio()
        radio.startPractice()
        defer { radio.stopPractice() }
        let host = PhoneReferee(radio: radio, saveURL: url)
        var now = Date()
        host.clock = { now }
        let invite = try XCTUnwrap(host.create(fox: PracticeMesh.fox, foxCode: "4417", mode: .code, code: "foxq7", timeLimit: 1200))
        XCTAssertEqual(invite.limitMinutes, 20)
        XCTAssertEqual(invite.timeLimit, 1200)
        host.start()
        // Saved shortly after the change, without being asked.
        try await Task.sleep(for: .milliseconds(1600))
        SaveFile.flush()
        let saved = try XCTUnwrap(HostedHuntSave.load(from: url, now: now))
        XCTAssertEqual(saved.referee, host.referee)
        XCTAssertEqual(saved.invite, invite)
        // A "restart": a new referee over the same file carries on.
        do {
            let again = PhoneReferee(radio: radio, saveURL: url, now: now)
            XCTAssertEqual(again.board, host.board)
            XCTAssertTrue(again.resumed)
        }
        // Time runs out: the clock tick ends it, and the save goes.
        now += 1201
        host.tick()
        XCTAssertFalse(host.isHosting)
        XCTAssertEqual(host.board?.hunt.endReason, .time)
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertFalse(exists, "a finished hunt isn't kept to pick up")
    }

    func testNewHuntForgetsTheSave() throws {
        save(liveReferee(), at: t0).writeNow(to: url)
        let host = PhoneReferee(radio: Radio(), saveURL: url, now: t0)
        XCTAssertTrue(host.isHosting)
        host.reset()
        XCTAssertFalse(exists)
        XCTAssertFalse(host.isHosting)
    }
}
