import XCTest
@testable import WildcatRadioCore

/// Hunt for 2–3 friends (Small Play 2): pieces, rounds that swap who hides, the hide walk's
/// claim calibration, the time limit per round, totals and the invite.
final class HuntGameTests: XCTestCase {
    typealias G = HuntGame
    let zeus = NodeNum(0xA303_B917), loot = NodeNum(0x9E76_6B18)
    let maya = NodeNum(0x1111_1111), dex = NodeNum(0x2222_2222)
    let hostNode = NodeNum(0xA038_8880)
    let channel = ChannelSettings(name: "WGHUNT", psk: Data(repeating: 7, count: 32)).raw

    func texts(_ out: [G.Output]) -> [String] { out.compactMap { $0.output.say?.text } }

    /// N0CALL hides ZEUZ (label 7316) and LOOT (2048); 2 rounds of 20 minutes.
    func hosted(mode: FoxReferee.Mode = .either, rounds: Int = 2, limit: TimeInterval? = 1200) throws -> G {
        try G(hosting: "g1", code: "foxk7", me: "n0call",
              pieces: [.init(node: zeus, name: "ZEUZ", code: "7316"), .init(node: loot, name: "LOOT", code: "2048")],
              settings: .init(rounds: rounds, timeLimit: limit, mode: mode), at: 0)
    }

    /// Both pieces hidden next to strong readings, MAYA joined both, started at 100.
    func live(mode: FoxReferee.Mode = .either, limit: TimeInterval? = 1200) throws -> G {
        var g = try hosted(mode: mode, limit: limit)
        _ = g.handle(.join(t: 1, node: maya, name: "maya"), piece: 1)
        _ = g.handle(.join(t: 2, node: maya, name: "maya"), piece: 2)
        XCTAssertTrue(g.hide(piece: 1, spot: Coordinate(latitude: 38.9, longitude: -84.6), reading: .init(rssi: -41, snr: 11), at: 30))
        XCTAssertTrue(g.hide(piece: 2, spot: Coordinate(latitude: 38.901, longitude: -84.6), reading: .init(rssi: -44), at: 60))
        _ = g.start(at: 100)
        return g
    }

    // MARK: Codes

    func testGameAndPieceCodes() throws {
        XCTAssertTrue(G.isValidCode("FOXK7"))
        XCTAssertTrue(G.isValidCode("fox9"))
        XCTAssertFalse(G.isValidCode("FOX"))
        XCTAssertFalse(G.isValidCode("FOXABC"), "no room for the round and piece digits")
        XCTAssertFalse(G.isValidCode("FOX-7"))
        XCTAssertFalse(G.isValidCode("BOXK7"))
        let g = try hosted()
        XCTAssertEqual(g.code, "FOXK7")
        XCTAssertEqual(g.huntCode(round: 2, piece: 1), "FOXK721")
        XCTAssertEqual(g.address(of: "foxk712")?.round, 1)
        XCTAssertEqual(g.address(of: "FOXK712")?.piece, 2)
        XCTAssertNil(g.address(of: "FOXK713"), "no third piece")
        XCTAssertNil(g.address(of: "FOXK731"), "two rounds")
        XCTAssertNil(g.address(of: "FOXK7"))
        XCTAssertNil(g.address(of: "FOXQ711"))
        XCTAssertTrue(g.owns(huntCode: "FOXK721"))
        XCTAssertTrue(G.isPieceCode("FOXK711"))
        XCTAssertTrue(G.isPieceCode("FOX933"))
        XCTAssertFalse(G.isPieceCode("FOX7"))
        XCTAssertFalse(G.isPieceCode("FOXK74"))
        XCTAssertFalse(G.isPieceCode("FOXK701"))
        // Every piece code is a hunt code the WG grammar already reads (FOX + 1–4 characters).
        XCTAssertEqual(FoxReferee.huntCode(in: "WG SIG FOXK712 -88"), "FOXK712")
        XCTAssertEqual(WG.Reply("WG NO FOUND FOXK712 NEED CODE"), .rejected(verb: "FOUND", hunt: "FOXK712", reason: "NEED CODE"))
    }

    func testSetupErrors() {
        let p = G.NewPiece(node: zeus, name: "ZEUZ", code: "7316")
        func make(_ code: String = "FOXK7", _ me: String = "N0CALL", _ pieces: [G.NewPiece]) -> G.SetupError? {
            do { _ = try G(hosting: "g", code: code, me: me, pieces: pieces, settings: .init(), at: 0); return nil }
            catch { return error as? G.SetupError }
        }
        XCTAssertEqual(make("FOXABC", "N0CALL", [p]), .badGameCode)
        XCTAssertEqual(make("FOXK7", "N0CALL", []), .noPieces)
        XCTAssertEqual(make("FOXK7", "N0CALL", Array(repeating: p, count: 4)), .tooManyPieces)
        XCTAssertEqual(make("FOXK7", "N0CALL", [p, p]), .samePieceTwice)
        XCTAssertEqual(make("FOXK7", "N0CALL", [.init(node: zeus, name: "ZEUZ", code: "73")]), .badLabelCode)
        XCTAssertEqual(make("FOXK7", "!!", [p]), .noName)
        XCTAssertNil(make("FOXK7", "N0CALL", [p]))
        XCTAssertEqual(G.Settings(rounds: 9, timeLimit: -5).rounds, 3)
        XCTAssertNil(G.Settings(rounds: 0, timeLimit: .nan).timeLimit)
        XCTAssertEqual(G.Settings(rounds: 0).rounds, 1)
    }

    // MARK: Hiding and calibration

    func testHidingCalibratesEachPieceAndKeepsEarlyJoins() throws {
        var g = try hosted()
        XCTAssertTrue(g.isHiding)
        XCTAssertEqual(g.current?.referees.map(\.code), ["FOXK711", "FOXK712"])
        // A hunter joins while the hider is still out: answered from the lobby.
        let joined = texts(g.handle(.join(t: 5, node: maya, name: "maya", channel: 1), piece: 1))
        XCTAssertEqual(joined, ["WG OK JOIN FOXK711 MAYA 1 HUNTING LOBBY FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>"])
        XCTAssertFalse(g.canStart)
        XCTAssertEqual(g.start(at: 10), [], "not before every piece is hidden")
        XCTAssertTrue(g.hide(piece: 1, spot: Coordinate(latitude: 38.9, longitude: -84.6), reading: .init(rssi: -41, snr: 11),
                             offset: (90, 10), at: 30))
        let r1 = try XCTUnwrap(g.current?.referees[0])
        XCTAssertEqual(r1.hunt?.thresholdRSSI, -55, "the hider's -41 minus 14: within a few steps")
        XCTAssertEqual(r1.hunt?.thresholdSNR, 7)
        XCTAssertEqual(r1.hunters[maya]?.name, "MAYA", "the join survives the recalibration")
        XCTAssertEqual(r1.hunters[maya]?.channel, 1)
        let hidden = try XCTUnwrap(g.current?.hidden(1))
        XCTAssertEqual(hidden.spot, Coordinate(latitude: 38.9, longitude: -84.6))
        XCTAssertNotEqual(hidden.sharedSpot, hidden.spot, "the guide's spot is moved")
        XCTAssertLessThan(ScentGuide.distance(try XCTUnwrap(hidden.sharedSpot), hidden.spot!), 25)
        XCTAssertFalse(g.canStart)
        // Hiding it again moves it and calibrates again.
        XCTAssertTrue(g.hide(piece: 1, spot: nil, reading: .init(rssi: -50), at: 40))
        XCTAssertEqual(g.current?.referees[0].hunt?.thresholdRSSI, -64)
        XCTAssertNil(g.current?.hidden(1)?.sharedSpot)
        XCTAssertEqual(g.hiddenCount, 1)
        XCTAssertTrue(g.hide(piece: 2, spot: nil, reading: nil, at: 50))
        XCTAssertEqual(g.current?.referees[1].hunt?.thresholdRSSI, -75, "not heard: the referee's default")
        XCTAssertTrue(g.canStart)
        // GO goes to the hunters of each piece.
        let out = g.start(at: 100)
        XCTAssertEqual(texts(out), ["WG GO FOXK711 HUNT IS LIVE · FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>"])
        XCTAssertEqual(g.current?.stage, .live)
        XCTAssertEqual(g.current?.startedAt, 100)
        XCTAssertFalse(g.hide(piece: 1, spot: nil, reading: nil, at: 110), "no moving pieces once it's live")
    }

    func testCalibrationLines() {
        typealias C = G.Calibration
        XCTAssertEqual(C(reading: .init(rssi: -41)).claimRSSI, -55)
        XCTAssertEqual(C(reading: .init(rssi: -10)).claimRSSI, -30, "never stricter than -30")
        XCTAssertEqual(C(reading: .init(rssi: -90)).claimRSSI, -95, "never looser than -95")
        XCTAssertEqual(C(reading: .init(snr: 12)).claimSNR, 8)
        XCTAssertEqual(C(reading: .init(snr: 12)).claimRSSI, -75, "no RSSI: the default")
        XCTAssertEqual(C(reading: .init(snr: 30)).claimSNR, 10)
        XCTAssertEqual(C(reading: nil).claimRSSI, -75)
        XCTAssertEqual(C(reading: .init(rssi: .nan)).reading, nil, "nonsense is no reading")
        XCTAssertTrue(C(reading: nil).isWeak)
        XCTAssertTrue(C(reading: .init(rssi: -80)).isWeak)
        XCTAssertFalse(C(reading: .init(rssi: -60)).isWeak)
        XCTAssertFalse(C(reading: .init(snr: 9)).isWeak)
        let c = C(reading: .init(rssi: -41))
        XCTAssertTrue(c.isInZone(.init(rssi: -55)))
        XCTAssertFalse(c.isInZone(.init(rssi: -56)))
        XCTAssertTrue(c.isInZone(.init(snr: 9)), "SNR only: against the SNR line")
        XCTAssertFalse(c.isInZone(.init()))
    }

    func testCalibrationReadingIsTheRecentMedian() {
        let s: [(t: TimeInterval, reading: G.Reading)] = [
            (0, .init(rssi: -20)),              // carried in the hand, too long ago
            (100, .init(rssi: -44, snr: 10)), (120, .init(rssi: -40)), (150, .init(rssi: -60, snr: 9)),
            (200, .init(rssi: -10)),            // after the tap: not counted
        ]
        XCTAssertEqual(G.calibrationReading(s, at: 160), .init(rssi: -44, snr: 9.5))
        XCTAssertEqual(G.calibrationReading(s, at: 125), .init(rssi: -42, snr: 10))
        XCTAssertNil(G.calibrationReading(s, at: 95), "the hand-held reading is over 90 s old")
        XCTAssertNil(G.calibrationReading([], at: 0))
    }

    // MARK: Refereeing a round

    func testCommandsAreRoutedToTheirPiece() throws {
        let g = try live()
        XCTAssertEqual(g.pieces(forCommand: "WG SIG FOXK712 -88"), [2])
        XCTAssertEqual(g.pieces(forCommand: "WG FOUND foxk711 7316"), [1])
        XCTAssertNil(g.pieces(forCommand: "WG SIG FOXK721 -88"), "next round's code")
        XCTAssertNil(g.pieces(forCommand: "WG JOIN FOX7 MAYA"), "another hunt")
        XCTAssertEqual(g.pieces(forCommand: "WG LEAVE"), [1, 2])
        XCTAssertEqual(g.pieces(forCommand: "WG HUNT"), [1])
        XCTAssertNil(g.pieces(forCommand: "hello"))
        XCTAssertEqual(g.piece(node: loot), 2)
        XCTAssertNil(g.piece(node: maya))
    }

    func testTheRoundEndsWhenEveryPieceIsFound() throws {
        var g = try live(mode: .code)
        XCTAssertEqual(texts(g.handle(.found(t: 480, node: maya, code: "7316"), piece: 1)).first, "WG OK FOUND FOXK711 #1 +100 CODE T+6M")
        XCTAssertEqual(g.current?.stage, .live, "one piece to go")
        XCTAssertEqual(g.current?.results.first?.finds, [G.Find(piece: 1, elapsed: 380, proofs: [.code])])
        let out = texts(g.handle(.found(t: 808, node: maya, code: "2048"), piece: 2))
        XCTAssertTrue(out.contains("WG END FOXK712 MAYA WINS 1/1 FOUND"))
        let round = try XCTUnwrap(g.current)
        XCTAssertEqual(round.stage, .over)
        XCTAssertEqual(round.endReason, .allFound)
        XCTAssertEqual(round.endedAt, 808)
        XCTAssertEqual(round.results.count, 1)
        XCTAssertEqual(g.roundTime(round.results[0], in: round), 708, "11:48: the last piece")
        XCTAssertEqual(g.nextRoundNumber, 2)
        XCTAssertFalse(g.isOver)
    }

    func testASignalClaimUsesThePiecesOwnLine() throws {
        var g = try live(mode: .signal)
        // ZEUZ's line is -55 (heard at -41 beside it).
        XCTAssertFalse(g.handle(.sig(t: 200, node: maya, rssi: -56, src: .app, hops: 0), piece: 1).contains { $0.output == .found(maya) })
        XCTAssertTrue(g.handle(.sig(t: 220, node: maya, rssi: -55, src: .app, hops: 0), piece: 1).contains { $0.output == .found(maya) })
        // LOOT's line is -58: the same reading is a find there, from a hunter's mesh reading.
        let out = g.handle(.sig(t: 230, node: maya, rssi: -57), piece: 2)
        XCTAssertTrue(out.contains { $0.output == .found(maya) && $0.piece == 2 })
    }

    func testTheTimeLimitIsPerRound() throws {
        var g = try live(limit: 600)
        XCTAssertEqual(g.timeRemaining(at: 400), 300)
        XCTAssertEqual(g.tick(at: 699), [])
        let out = texts(g.tick(at: 700))
        XCTAssertEqual(out, ["WG END FOXK711 NO FINDS 0/1 FOUND · TIME UP", "WG END FOXK712 NO FINDS 0/1 FOUND · TIME UP"])
        XCTAssertEqual(g.current?.endReason, .time)
        XCTAssertEqual(g.current?.endedAt, 700)
        XCTAssertEqual(g.timeRemaining(at: 5000), 0)
        // Round 2 gets its own 10 minutes, from its own start.
        XCTAssertTrue(g.nextRound(iHide: true, at: 2000))
        XCTAssertEqual(g.current?.referees.map(\.code), ["FOXK721", "FOXK722"])
        XCTAssertEqual(g.timeRemaining(at: 2100), 600, "not running while hiding")
        _ = g.hide(piece: 1, spot: nil, reading: .init(rssi: -45), at: 2100)
        _ = g.hide(piece: 2, spot: nil, reading: .init(rssi: -45), at: 2200)
        _ = g.start(at: 3000)
        XCTAssertEqual(g.deadline, 3600)
        XCTAssertEqual(g.timeRemaining(at: 3300), 300)
    }

    func testTheHostEndsTheRound() throws {
        var g = try live()
        _ = g.handle(.found(t: 300, node: maya, code: "7316"), piece: 1)
        XCTAssertEqual(texts(g.endRound(at: 400)), ["WG END FOXK712 NO FINDS 0/1 FOUND"])
        XCTAssertEqual(g.current?.endReason, .host)
        XCTAssertEqual(g.current?.stage, .over)
        let r = try XCTUnwrap(g.current?.results.first)
        XCTAssertEqual(g.roundTime(r, in: g.current!), 300, "not every piece: the whole round")
    }

    func testLeaveTakesAHunterOffEveryPiece() throws {
        var g = try live()
        var out: [G.Output] = []
        for p in g.pieces(forCommand: "WG LEAVE") ?? [] { out += g.handle(.leave(t: 200, node: maya), piece: p) }
        XCTAssertEqual(texts(out), ["WG OK LEAVE FOXK711", "WG OK LEAVE FOXK712"])
    }

    // MARK: Hunting a round

    func testAHunterKeepsTheirOwnRound() throws {
        let host = try live()
        let invite = try XCTUnwrap(host.invite(host: hostNode, channel: channel))
        var g = G(joining: invite, me: "maya")
        XCTAssertEqual(g.me, "MAYA")
        XCTAssertEqual(g.current?.role, .hunter)
        XCTAssertEqual(g.current?.hider, "N0CALL")
        XCTAssertEqual(g.current?.stage, .live, "the invite was shown after the start")
        XCTAssertEqual(g.current?.startedAt, 100)
        XCTAssertEqual(g.current?.hidden(1)?.calibration.claimRSSI, -55, "the claim line came with the invite")
        XCTAssertNil(g.pieces[0].code, "a hunter isn't told the label codes")
        // Lines for other hunts or other rounds are not this round's.
        XCTAssertNil(g.heard(WG.Reply("WG GO FOX7 HUNT IS LIVE")!, at: 101))
        XCTAssertNil(g.heard(WG.Reply("WG GO FOXK721 HUNT IS LIVE")!, at: 101))
        XCTAssertEqual(g.heard(WG.Reply("WG OK FOUND FOXK711 #1 +125 CODE+RF-B T+6M")!, at: 480), 1)
        XCTAssertEqual(g.myFinds, [G.Find(piece: 1, elapsed: 380, proofs: [.code, .rfAttested])])
        _ = g.heard(WG.Reply("WG OK FOUND FOXK711 #1 +125 CODE+RF-B T+6M")!, at: 490)
        XCTAssertEqual(g.myFinds.count, 1, "a repeated answer isn't a second find")
        _ = g.heard(WG.Reply("WG END FOXK711 MAYA WINS 1/1 FOUND")!, at: 481)
        XCTAssertEqual(g.current?.stage, .live)
        _ = g.heard(WG.Reply("WG OK FOUND FOXK712 #1 +100 CODE T+11M")!, at: 808)
        let text = "WG END FOXK712 MAYA WINS 1/1 FOUND"
        _ = g.heard(WG.Reply(text)!, text: text, at: 809)
        XCTAssertEqual(g.current?.stage, .over)
        XCTAssertEqual(g.current?.endReason, .allFound)
        XCTAssertEqual(g.roundTime(g.current!.results[0], in: g.current!), 708)
    }

    func testAHunterWhoJoinsLateLearnsTheStartFromTheStatus() throws {
        var host = try hosted()
        _ = host.hide(piece: 1, spot: nil, reading: .init(rssi: -45), at: 10)
        var g = G(joining: try XCTUnwrap(host.invite(host: hostNode, channel: channel)), me: "dex")
        XCTAssertEqual(g.current?.stage, .hiding)
        XCTAssertNil(g.current?.startedAt)
        _ = g.heard(WG.Reply("WG OK JOIN FOXK711 DEX 2 HUNTING LIVE FOX ZEUZ")!, at: 500)
        XCTAssertEqual(g.current?.stage, .live)
        XCTAssertNil(g.current?.startedAt, "the join doesn't say when")
        _ = g.heard(WG.Reply("WG HUNT FOXK711 LIVE T+3M 2 HUNTERS 0 FOUND FOX ZEUZ")!, at: 500)
        XCTAssertEqual(g.current?.startedAt, 290, "the middle of the fourth minute")
        _ = g.heard(WG.Reply("WG FOUND FOXK712 MAYA #1 T+5M")!, at: 620)
        XCTAssertEqual(g.current?.results.first, G.Result(name: "MAYA", finds: [G.Find(piece: 2, elapsed: 330)]))
        // A GO later doesn't move a known start.
        _ = g.heard(WG.Reply("WG GO FOXK712 HUNT IS LIVE")!, at: 700)
        XCTAssertEqual(g.current?.startedAt, 290)
    }

    func testAFindHeardBeforeTheStartIsKnownIsApproximate() throws {
        var g = G(joining: try XCTUnwrap(try hosted().invite(host: hostNode, channel: channel)), me: "dex")
        _ = g.heard(WG.Reply("WG FOUND FOXK711 MAYA #1 T+14M")!, at: 2000)
        XCTAssertEqual(g.current?.results.first?.finds.first, G.Find(piece: 1, elapsed: 870, approximate: true))
    }

    func testAHunterWhoHearsNoEndStopsAfterTheGrace() throws {
        var g = G(joining: try XCTUnwrap(try live(limit: 600).invite(host: hostNode, channel: channel)), me: "maya")
        _ = g.tick(at: 100 + 600 + 59)
        XCTAssertEqual(g.current?.stage, .live)
        _ = g.tick(at: 100 + 600 + 60)
        XCTAssertEqual(g.current?.stage, .over)
        XCTAssertEqual(g.current?.endReason, .time)
        XCTAssertEqual(g.current?.endedAt, 700)
    }

    func testAPhoneOnlyHunterClaimsByCode() throws {
        var host = try hosted()
        _ = host.hide(piece: 1, spot: Coordinate(latitude: 38.9, longitude: -84.6), reading: .init(rssi: -45), at: 10)
        _ = host.hide(piece: 2, spot: Coordinate(latitude: 38.901, longitude: -84.6), reading: .init(rssi: -45), at: 20)
        var g = G(joining: try XCTUnwrap(host.invite(host: hostNode, channel: channel)), me: "kite")
        XCTAssertNotNil(g.current?.hidden(1)?.sharedSpot, "the guide's spots came with the invite")
        XCTAssertNil(g.current?.hidden(1)?.spot, "never the real one")
        XCTAssertEqual(g.claimByCode(piece: 1, code: "7316", at: 50), .notStarted)
        g.go(at: 100)
        XCTAssertEqual(g.claimByCode(piece: 1, code: "1234", at: 200), .wrongCode)
        XCTAssertEqual(g.claimByCode(piece: 9, code: "7316", at: 200), .noSuchPiece)
        XCTAssertEqual(g.claimByCode(piece: 1, code: " 7316 ", at: 300), .found)
        XCTAssertEqual(g.claimByCode(piece: 1, code: "7316", at: 310), .alreadyFound)
        XCTAssertEqual(g.myFinds, [G.Find(piece: 1, elapsed: 200, proofs: [.code])])
        XCTAssertEqual(g.claimByCode(piece: 2, code: "2048", at: 500), .found)
        XCTAssertEqual(g.current?.stage, .over, "every piece found")
        XCTAssertEqual(g.claimByCode(piece: 2, code: "2048", at: 510), .over)
    }

    // MARK: Swapping who hides

    func testTwoPlayersSwapWithoutAHandOver() throws {
        // N0CALL's phone hides round 1; MAYA's phone hunts it.
        var a = try live(mode: .code)
        var b = G(joining: try XCTUnwrap(a.invite(host: hostNode, channel: channel)), me: "maya")
        func say(_ out: [G.Output], to node: NodeNum = NodeNum(0x1111_1111), at t: TimeInterval) {
            for o in out { if let s = o.output.say, s.to == node, let r = WG.Reply(s.text) { b.heard(r, text: s.text, at: t) } }
        }
        say(a.handle(.found(t: 480, node: maya, code: "7316"), piece: 1), at: 481)
        say(a.handle(.found(t: 808, node: maya, code: "2048"), piece: 2), at: 809)
        XCTAssertEqual(a.current?.stage, .over)
        XCTAssertEqual(b.current?.stage, .over)
        // The hunter found them, so the hunter hides next: both phones agree without talking.
        XCTAssertEqual(a.suggestedHider(after: a.current!), "MAYA")
        XCTAssertTrue(b.shouldHideNext)
        XCTAssertFalse(a.shouldHideNext)
        XCTAssertTrue(a.nextRound(iHide: false, at: 900))
        XCTAssertEqual(a.current?.role, .hunter)
        XCTAssertEqual(a.current?.hider, "MAYA")
        XCTAssertTrue(b.nextRound(iHide: true, at: 900))
        XCTAssertEqual(b.current?.role, .hider)
        XCTAssertEqual(b.current?.referees.map(\.code), ["FOXK721", "FOXK722"])
        // MAYA's phone was never told the label codes: she types them from the labels as she hides.
        XCTAssertFalse(b.hide(piece: 1, spot: nil, reading: .init(rssi: -40), at: 950))
        XCTAssertFalse(b.learnCode(piece: 1, code: "7317"))
        XCTAssertTrue(b.learnCode(piece: 1, code: "7316"))
        XCTAssertTrue(b.learnCode(piece: 2, code: "2048"))
        XCTAssertTrue(b.hide(piece: 1, spot: nil, reading: .init(rssi: -40), at: 950))
        XCTAssertTrue(b.hide(piece: 2, spot: nil, reading: .init(rssi: -47), at: 1000))
        // N0CALL joins round 2 by its codes (or by scanning MAYA's new invite).
        XCTAssertTrue(a.merge(try XCTUnwrap(b.invite(host: maya, channel: channel))))
        XCTAssertEqual(a.rounds.count, 2, "the same game: round 1 is kept")
        XCTAssertEqual(a.current?.hidden(2)?.calibration.claimRSSI, -61)
        let n0 = hostNode
        func sayA(_ out: [G.Output], at t: TimeInterval) {
            for o in out { if let s = o.output.say, s.to == n0, let r = WG.Reply(s.text) { a.heard(r, text: s.text, at: t) } }
        }
        sayA(b.handle(.join(t: 1010, node: n0, name: "n0call"), piece: 1), at: 1011)
        sayA(b.handle(.join(t: 1012, node: n0, name: "n0call"), piece: 2), at: 1013)
        sayA(b.start(at: 1100), at: 1101)
        XCTAssertEqual(a.current?.startedAt, 1101, "from the GO, as heard")
        sayA(b.handle(.found(t: 1100 + 600, node: n0, code: "7316"), piece: 1), at: 1701)
        sayA(b.handle(.found(t: 1100 + 900, node: n0, code: "2048"), piece: 2), at: 2001)
        XCTAssertTrue(a.isOver)
        XCTAssertTrue(b.isOver)
        XCTAssertNil(a.nextRoundNumber)
        // Both phones rank MAYA first (about 11:48 against 15:00), each by the clock it saw:
        // MAYA's phone timed her own round from the GO it heard, a second late.
        XCTAssertEqual(b.standings.map(\.name), ["MAYA", "N0CALL"])
        XCTAssertEqual(b.standings.map(\.time), [709, 900])
        XCTAssertEqual(a.standings.map(\.name), ["MAYA", "N0CALL"])
        XCTAssertEqual(a.standings.map(\.time), [708, 900])
        XCTAssertEqual(a.standings.first { $0.isMe }?.name, "N0CALL")
        XCTAssertEqual(b.standings.first { $0.isMe }?.name, "MAYA")
    }

    func testStandingsPreferMorePiecesThenTime() throws {
        var g = try live(mode: .code, limit: 1200)
        _ = g.handle(.join(t: 101, node: dex, name: "dex"), piece: 1)
        _ = g.handle(.join(t: 101, node: dex, name: "dex"), piece: 2)
        _ = g.handle(.found(t: 200, node: dex, code: "7316"), piece: 1)    // DEX is quick but finds one
        _ = g.handle(.found(t: 900, node: maya, code: "7316"), piece: 1)
        _ = g.handle(.found(t: 1000, node: maya, code: "2048"), piece: 2)
        _ = g.tick(at: 1300)
        XCTAssertEqual(g.current?.endReason, .time)
        let s = g.standings
        XCTAssertEqual(s.map(\.name), ["MAYA", "DEX"])
        XCTAssertEqual(s.map(\.found), [2, 1])
        XCTAssertEqual(s.map(\.time), [900, 1200], "DEX ran out of time")
        XCTAssertEqual(g.suggestedHider(after: g.current!), "MAYA")
    }

    func testThreeRoundsThenTheGameIsOver() throws {
        var g = try G(hosting: "g3", code: "FOX9", me: "n0call", pieces: [.init(node: zeus, name: "", code: "1111")],
                      settings: .init(rounds: 3, timeLimit: nil, mode: .code), at: 0)
        XCTAssertEqual(g.pieces[0].name, "PIECE 1")
        for n in 1...3 {
            if n > 1 { XCTAssertTrue(g.nextRound(iHide: true, at: Double(n) * 1000)) }
            _ = g.handle(.join(t: Double(n) * 1000 + 1, node: maya), piece: 1)
            _ = g.hide(piece: 1, spot: nil, reading: nil, at: Double(n) * 1000 + 2)
            _ = g.start(at: Double(n) * 1000 + 10)
            XCTAssertNil(g.timeRemaining(at: Double(n) * 1000 + 20), "no limit")
            _ = g.handle(.found(t: Double(n) * 1000 + 70, node: maya, code: "1111"), piece: 1)
            XCTAssertEqual(g.current?.stage, .over)
        }
        XCTAssertTrue(g.isOver)
        XCTAssertFalse(g.nextRound(iHide: true, at: 9000))
        XCTAssertEqual(g.standings.first?.roundsHunted, 3)
        XCTAssertEqual(g.standings.first?.averageTime, 60)
    }

    // MARK: The invite

    func testTheInviteRoundTripsAndStaysSmall() throws {
        let g = try live()
        let invite = try XCTUnwrap(g.invite(host: hostNode, channel: channel))
        XCTAssertEqual(invite.code, "FOXK7")
        XCTAssertEqual(invite.round, 1)
        XCTAssertEqual(invite.limit, 20)
        XCTAssertEqual(invite.started, 100)
        XCTAssertTrue(invite.isHidden)
        XCTAssertEqual(invite.pieces.map(\.claimRSSI), [-55, -58])
        let link = invite.link
        XCTAssertTrue(link.hasPrefix("wildcat://huntgame/"))
        XCTAssertLessThan(link.utf8.count, 900, "a QR code a phone reads at arm's length")
        XCTAssertFalse(link.contains("7316"))
        let back = try XCTUnwrap(G.Invite(link: link))
        XCTAssertEqual(back.game, invite.game)
        XCTAssertEqual(back.pieces.map(\.check), invite.pieces.map(\.check))
        XCTAssertEqual(back.pieces[0].spot, g.current?.hidden(1)?.sharedSpot)
        XCTAssertEqual(back.channelName, "WGHUNT")
        XCTAssertEqual(back.timeLimit, 1200)
        XCTAssertEqual(back.findMode, .either)
        XCTAssertEqual(back.id, "g1-1")
        // A hunter's phone has no invite to give.
        XCTAssertNil(G(joining: back, me: "maya").invite(host: maya, channel: channel))
    }

    func testBrokenOrHostileInvitesAreRefused() throws {
        let good = try XCTUnwrap(try live().invite(host: hostNode, channel: channel))
        func link(_ edit: (inout G.Invite) -> Void) -> String { var v = good; edit(&v); return v.link }
        XCTAssertNotNil(G.Invite(link: good.link))
        XCTAssertNotNil(G.Invite(link: "  WILDCAT://HUNTGAME/" + good.link.dropFirst(19) + "\n"))
        for bad in [
            link { $0.version = 2 }, link { $0.code = "FOXABCD" }, link { $0.rounds = 0 }, link { $0.round = 3 },
            link { $0.pieces = [] }, link { $0.pieces += $0.pieces }, link { $0.pieces[1].i = 1 }, link { $0.pieces[0].i = 4 },
            link { $0.pieces[0].check = "zz" }, link { $0.pieces[0].claimRSSI = 20 }, link { $0.pieces[0].claimSNR = .infinity },
            link { $0.pieces[0].spot = Coordinate(latitude: 95, longitude: 0) }, link { $0.limit = 0 }, link { $0.mode = "maybe" },
            link { $0.channel = Data() }, link { $0.started = -1 }, link { $0.pieces[0].name = "" },
            link { $0.pieces[1].node = $0.pieces[0].node },
            "wildcat://huntgame/", "wildcat://huntgame/!!!!", "wildcat://hunt/" + good.link.dropFirst(19), "hello",
            "wildcat://huntgame/" + Data("{\"v\":1}".utf8).base64EncodedString(),
            "wildcat://huntgame/" + Data("[1,2,3]".utf8).base64EncodedString(),
            "wildcat://huntgame/" + String(repeating: "A", count: 5000),
        ] {
            XCTAssertNil(G.Invite(link: bad), bad)
        }
    }

    func testAnInviteForAnotherGameIsNotMerged() throws {
        var g = G(joining: try XCTUnwrap(try live().invite(host: hostNode, channel: channel)), me: "maya")
        var other = try XCTUnwrap(try live().invite(host: hostNode, channel: channel))
        other.game = "g2"
        XCTAssertFalse(g.merge(other))
        XCTAssertEqual(g.rounds.count, 1)
    }

    // MARK: Saving

    func testASavedGameCarriesOnExactly() throws {
        var g = try live(mode: .either)
        _ = g.handle(.sig(t: 200, node: maya, rssi: -70, snr: 3.5, position: Coordinate(latitude: 38.9, longitude: -84.6)), piece: 1)
        _ = g.handle(.found(t: 300, node: maya, code: "7316"), piece: 1)
        let data = try JSONEncoder().encode(g)
        var back = try JSONDecoder().decode(G.self, from: data)
        XCTAssertEqual(back, g)
        let next = FoxReferee.Event.found(t: 500, node: maya, code: "2048")
        XCTAssertEqual(back.handle(next, piece: 2), g.handle(next, piece: 2))
        XCTAssertEqual(back, g)
        XCTAssertEqual(back.current?.stage, .over)
        // A file with nonsense settings can't bring back zero rounds.
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"rounds\":2", with: "\"rounds\":0")
        let odd = try JSONDecoder().decode(G.self, from: Data(json.utf8))
        XCTAssertEqual(odd.settings.rounds, 1)
        XCTAssertNil(odd.address(of: "FOXK721"))
    }

    func testReportPaceSparesTheChannel() throws {
        XCTAssertEqual(G.reportPace(focused: true, near: false), .init(interval: 30, jump: 3))
        XCTAssertEqual(G.reportPace(focused: false, near: true), .init(interval: 30, jump: 3))
        XCTAssertEqual(G.reportPace(focused: false, near: false), .init(interval: 120, jump: 10))
        let g = G(joining: try XCTUnwrap(try live().invite(host: hostNode, channel: channel)), me: "maya")
        // ZEUZ's claim line is -55: near from -61, in the zone from -55.
        XCTAssertFalse(g.isNear(piece: 1, reading: .init(rssi: -62)))
        XCTAssertTrue(g.isNear(piece: 1, reading: .init(rssi: -61)))
        XCTAssertFalse(g.isInZone(piece: 1, reading: .init(rssi: -56)))
        XCTAssertTrue(g.isInZone(piece: 1, reading: .init(rssi: -55)))
        XCTAssertTrue(g.isNear(piece: 1, reading: .init(snr: 4)), "SNR line 7, near from 4")
        XCTAssertFalse(g.isNear(piece: 1, reading: .init()))
    }

    func testReplyHuntCodes() {
        XCTAssertEqual(WG.Reply("WG W foxk711 WARMER -94>-88 BEST -85")?.huntCode, "FOXK711")
        XCTAssertEqual(WG.Reply("WG NO FOUND FOXK712 BADCODE 2/5")?.huntCode, "FOXK712")
        XCTAssertNil(WG.Reply("WG NO FOUND NO HUNT")?.huntCode)
        XCTAssertNil(WG.Reply("WG HUNT NONE")?.huntCode)
        XCTAssertNil(WG.Reply("WG PONG")?.huntCode)
    }
}
