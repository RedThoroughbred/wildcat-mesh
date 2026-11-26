import CoreLocation
import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// Hunt for 2–3 friends on the phone (Small Play 2): hosting through the node, hunting with a
/// node or the GPS guide, the save, the invite link, and leaving the single Fox Hunt alone.
@MainActor
final class GamePlayTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent(GameSave.fileName) }
    private var defaults: UserDefaults!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let maya = PracticeMesh.maya

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hunt-game-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "game-tests-\(UUID())")
        defaults.set("n0call", forKey: HuntModel.nameKey)
    }

    override func tearDown() async throws {
        SaveFile.flush()
        try? FileManager.default.removeItem(at: dir)
    }

    /// A practice radio whose pretend mesh is quiet (no beacons or replies of its own): the test feeds the packets.
    private func practiceRadio() -> Radio {
        let r = Radio()
        r.startPractice()
        r.practice?.stop()
        return r
    }

    private func beacon(_ node: NodeNum, rssi: Int) -> MeshPacket {
        MeshPacket(from: node, to: .broadcast, id: 1, rxSNR: 9, rxRSSI: rssi, hopLimit: 3, hopStart: 3, portnum: .position)
    }

    private func text(_ s: String, from: NodeNum, to: NodeNum = .broadcast) -> MeshPacket {
        MeshPacket(from: from, to: to, channel: PracticeMesh.huntChannel, id: 2, hopLimit: 3, hopStart: 3, portnum: .text, text: s)
    }

    // MARK: Hosting

    func testHidingCalibratesFromThisPhonesNodeAndRefereesJoins() async throws {
        let radio = practiceRadio()
        defer { radio.stopPractice() }
        let play = GamePlay(radio: radio, defaults: defaults, saveURL: url, now: t0)
        var now = t0
        play.clock = { now }
        XCTAssertTrue(play.host(pieces: [PracticeMesh.loot, PracticeMesh.gem], rounds: 2, limitMinutes: 20, mode: .either))
        let game = try XCTUnwrap(play.game)
        XCTAssertEqual(game.me, "N0CALL")
        XCTAssertTrue(HuntGame.isValidCode(game.code))
        XCTAssertEqual(game.pieces.map(\.name), ["LOOT", "GEM"])
        XCTAssertTrue(game.pieces.allSatisfy { $0.code.map { $0.count == 4 } ?? false }, "random label codes")
        XCTAssertTrue(play.isHider)
        // The invite carries the practice WGHUNT channel and the host's node.
        let invite = try XCTUnwrap(play.invite)
        XCTAssertEqual(invite.channelName, "WGHUNT")
        XCTAssertEqual(invite.hostNode, PracticeMesh.me)
        XCTAssertFalse(invite.isHidden)
        // The hider carries LOOT: their node hears it loud.
        for (i, rssi) in [-40, -44, -42].enumerated() {
            now = t0.addingTimeInterval(Double(i) * 10)
            play.handle(.packet(beacon(PracticeMesh.loot, rssi: rssi)))
        }
        XCTAssertEqual(play.reading(1)?.rssi, -42)
        // A hunter joins piece 1 while it's being hidden.
        play.handle(.packet(text("WG JOIN \(game.huntCode(round: 1, piece: 1)) MAYA", from: maya)))
        XCTAssertEqual(play.round?.referees[0].hunters[maya]?.name, "MAYA")
        XCTAssertNil(play.round?.referees[1].hunters[maya], "only the piece it named")
        now = t0.addingTimeInterval(25)
        let hidden = await play.hide(piece: 1)
        XCTAssertTrue(hidden)
        XCTAssertEqual(play.round?.hidden(1)?.calibration.reading?.rssi, -42, "the median of what the node heard")
        XCTAssertEqual(play.round?.referees[0].hunt?.thresholdRSSI, -56)
        XCTAssertEqual(play.round?.referees[0].hunters[maya]?.name, "MAYA", "the join is kept")
        XCTAssertFalse(play.game?.canStart ?? true)
        let second = await play.hide(piece: 2)
        XCTAssertTrue(second)
        XCTAssertEqual(play.round?.hidden(2)?.calibration.claimRSSI, -75, "GEM not heard: the usual line")
        play.start()
        XCTAssertEqual(play.round?.stage, .live)
        // Saved soon after, and a new GamePlay over the same file carries on.
        try await Task.sleep(for: .milliseconds(1600))
        SaveFile.flush()
        let again = GamePlay(radio: radio, defaults: defaults, saveURL: url, now: now)
        XCTAssertTrue(again.resumed)
        XCTAssertEqual(again.game, play.game)
        // Ending the game forgets it.
        play.endGame()
        XCTAssertNil(play.game)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHostingNeedsANodeWithTheHuntChannel() {
        let play = GamePlay(radio: Radio(), defaults: defaults, saveURL: nil)
        XCTAssertFalse(play.host(pieces: [PracticeMesh.loot], rounds: 1, limitMinutes: 10, mode: .code))
        XCTAssertEqual(play.error, "Connect your node first: it referees the hunt.")
        XCTAssertNil(play.game)
    }

    // MARK: Hunting

    private func hostInvite(started: TimeInterval? = nil) throws -> HuntGame.Invite {
        var host = try HuntGame(hosting: "g1", code: "FOXK7", me: "MAYA",
                                pieces: [.init(node: PracticeMesh.loot, name: "LOOT", code: "7316"), .init(node: PracticeMesh.gem, name: "GEM", code: "2048")],
                                settings: .init(rounds: 2, timeLimit: 1200, mode: .either), at: 0)
        _ = host.hide(piece: 1, spot: Coordinate(latitude: 38.9, longitude: -84.6), reading: .init(rssi: -41), at: 1)
        _ = host.hide(piece: 2, spot: Coordinate(latitude: 38.902, longitude: -84.6), reading: .init(rssi: -45), at: 2)
        if let started { _ = host.start(at: started) }
        return try XCTUnwrap(host.invite(host: maya, channel: ChannelSettings(name: "WGHUNT", psk: Data([1])).raw))
    }

    func testAHunterWithANodeJoinsEveryPieceAndKeepsTheReferees() async throws {
        let radio = practiceRadio()
        defer { radio.stopPractice() }
        let play = GamePlay(radio: radio, defaults: defaults, saveURL: nil)
        let now = t0
        play.clock = { now }
        play.join(invite: try hostInvite())
        XCTAssertFalse(play.guide)
        XCTAssertEqual(play.round?.role, .hunter)
        XCTAssertEqual(play.round?.hider, "MAYA")
        XCTAssertTrue(play.joining)
        // The referee's lines are the game's.
        play.handle(.packet(text("WG OK JOIN FOXK711 N0CALL 1 HUNTING LOBBY FOX LOOT", from: maya, to: PracticeMesh.me)))
        play.handle(.packet(text("WG OK JOIN FOXK712 N0CALL 1 HUNTING LOBBY FOX GEM", from: maya, to: PracticeMesh.me)))
        XCTAssertEqual(play.joined, [1, 2])
        XCTAssertFalse(play.joining)
        play.handle(.packet(text("WG GO FOXK711 HUNT IS LIVE · FOX LOOT", from: maya, to: PracticeMesh.me)))
        XCTAssertEqual(play.round?.stage, .live)
        XCTAssertEqual(play.round?.startedAt, t0.timeIntervalSince1970)
        // A line for someone else, or for another hunt, changes nothing.
        play.handle(.packet(text("WG OK FOUND FOXK711 #1 +100 CODE T+1M", from: maya, to: NodeNum(0x1234))))
        play.handle(.packet(text("WG OK FOUND FOX7 #1 +100 CODE T+1M", from: maya, to: PracticeMesh.me)))
        XCTAssertEqual(play.game?.myFinds, [])
        // Its own readings of a piece go to that piece's referee.
        play.handle(.packet(beacon(PracticeMesh.loot, rssi: -70)))
        XCTAssertEqual(play.reading(1)?.rssi, -70)
        XCTAssertFalse(play.isInZone(1), "LOOT's line is -55")
        play.handle(.packet(beacon(PracticeMesh.loot, rssi: -52)))
        XCTAssertTrue(play.isInZone(1))
        play.handle(.packet(text("WG OK FOUND FOXK711 #1 +125 RF-B T+0M", from: maya, to: PracticeMesh.me)))
        XCTAssertEqual(play.game?.myFinds.map(\.piece), [1])
        XCTAssertEqual(play.notice, "You found LOOT!")
    }

    func testAHunterWithNoNodeUsesTheGuideAndTheLabelCode() throws {
        let play = GamePlay(radio: Radio(), defaults: defaults, saveURL: nil)
        var now = t0
        play.clock = { now }
        play.noise = { 0 }
        play.join(invite: try hostInvite())
        XCTAssertTrue(play.guide)
        XCTAssertEqual(play.round?.stage, .hiding)
        play.go()
        XCTAssertEqual(play.round?.stage, .live)
        // 60 m south of LOOT's shared spot: the guide says 50–100 m, never a pin.
        let spot = try XCTUnwrap(play.round?.hidden(1)?.sharedSpot)
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: spot.latitude - 60 / 110_574, longitude: spot.longitude),
                             altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 8, timestamp: now)
        play.sampleScent(at: fix)
        XCTAssertEqual(play.scent[1]?.band, 2)
        XCTAssertEqual(play.scent[1]?.words, "50–100 m")
        now += 120
        XCTAssertEqual(play.claimByCode(piece: 1, code: "1111"), .wrongCode)
        XCTAssertEqual(play.claimByCode(piece: 1, code: "7316"), .found)
        XCTAssertEqual(play.game?.myFinds.first?.elapsed, 120)
    }

    func testAnInviteLinkOpensTheGameSheet() throws {
        let radio = Radio()
        let hunt = HuntModel(radio: radio, defaults: defaults)
        let play = GamePlay(radio: radio, defaults: defaults, saveURL: nil)
        let invites = InviteHandler(radio: radio, hunt: hunt, admin: NodeAdmin(radio: radio), games: play)
        XCTAssertTrue(invites.open(try hostInvite().link))
        XCTAssertNotNil(invites.pendingGame)
        XCTAssertNil(invites.pending)
        XCTAssertTrue(invites.gamePlan?.contains("GPS guide") ?? false, "no node: the guide")
        XCTAssertFalse(invites.open("wildcat://huntgame/nonsense"))
    }

    // MARK: Living next to the single Fox Hunt

    func testTheSingleFoxHuntLeavesTheGamesLinesAlone() {
        let radio = practiceRadio()
        defer { radio.stopPractice() }
        let hunt = HuntModel(radio: radio, defaults: defaults)
        hunt.handle(.packet(text("WG OK JOIN FOXK711 N0CALL 1 HUNTING LIVE FOX LOOT", from: maya, to: PracticeMesh.me)))
        hunt.handle(.packet(text("WG END FOXK712 MAYA WINS 1/1 FOUND", from: maya, to: PracticeMesh.me)))
        XCTAssertEqual(hunt.stage, .idle, "a game's piece isn't this hunt")
        hunt.handle(.packet(text("WG OK JOIN FOX7 N0CALL 1 HUNTING LIVE FOX ZEUZ", from: PracticeMesh.den, to: PracticeMesh.me)))
        XCTAssertEqual(hunt.stage, .hunting, "the single hunt still works")
    }

    func testThePracticeDenLeavesGameCodesAlone() {
        let mesh = PracticeMesh()
        var heard: [String] = []
        mesh.onEvent = { if case .packet(let p) = $0, let t = p.text { heard.append(t) } }
        mesh.receive(text: "WG JOIN FOXK711 N0CALL", channel: 1)
        XCTAssertTrue(heard.isEmpty)
    }

    // MARK: The save file

    func testTheSaveIsDroppedWhenOverStaleOrBroken() throws {
        var g = try HuntGame(hosting: "g9", code: "FOX9", me: "N0CALL", pieces: [.init(node: PracticeMesh.loot, name: "LOOT", code: "1111")],
                             settings: .init(rounds: 1, timeLimit: nil, mode: .code), at: 0)
        GameSave(savedAt: t0, game: g).writeNow(to: url)
        XCTAssertNotNil(GameSave.load(from: url, now: t0.addingTimeInterval(3600)))
        XCTAssertNil(GameSave.load(from: url, now: t0.addingTimeInterval(13 * 3600)), "stale")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        _ = g.hide(piece: 1, spot: nil, reading: nil, at: 1)
        _ = g.start(at: 2)
        _ = g.endRound(at: 3)
        XCTAssertTrue(g.isOver)
        GameSave(savedAt: t0, game: g).writeNow(to: url)
        XCTAssertNil(GameSave.load(from: url, now: t0), "a finished game isn't picked up")
        try Data("{\"version\":1,\"game\":".utf8).write(to: url)
        XCTAssertNil(GameSave.load(from: url, now: t0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "set aside")
    }
}
