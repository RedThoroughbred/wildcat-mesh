import XCTest
@testable import WildcatRadioCore

/// Port of the Den's tests/test_foxhunt.py: the phone referee must rule exactly as the Den does.
final class FoxRefereeTests: XCTestCase {
    typealias R = FoxReferee
    let fox = NodeNum(0xA303_B917)        // relay byte 0x17
    let maya = NodeNum(0x1111_1111), dex = NodeNum(0x2222_2222)

    func texts(_ out: [R.Output]) -> [String] { out.compactMap { $0.say?.text } }

    func hunt(_ mode: R.Mode = .code) -> R {
        var r = R()
        r.handle(.create(t: 0, fox: fox, foxCode: "4417", code: "FOX7", mode: mode, foxLabel: "ZEUZ"))
        return r
    }

    func live(_ mode: R.Mode = .code) -> R {
        var r = hunt(mode)
        r.handle(.join(t: 1, node: maya, name: "maya"))
        r.handle(.join(t: 2, node: dex, label: "DX-9"))
        r.handle(.start(t: 10))
        return r
    }

    @discardableResult
    func sig(_ r: inout R, _ t: TimeInterval, _ node: NodeNum, _ rssi: Double? = nil, snr: Double? = nil,
             src: R.Source = .mesh, hops: Int? = nil) -> [String] {
        texts(r.handle(.sig(t: t, node: node, rssi: rssi, snr: snr, src: src, hops: hops)))
    }

    func found(_ r: inout R, _ t: TimeInterval, _ node: NodeNum, _ code: String = "", relay: UInt32? = nil, hops: Int? = nil) -> [String] {
        texts(r.handle(.found(t: t, node: node, code: code, relayNode: relay, hops: hops)))
    }

    // MARK: Grammar

    func testParseCommandDropsHuntCode() {
        XCTAssertEqual(R.parseCommand("WG SIG FOX7 -88 6")?.verb, "SIG")
        XCTAssertEqual(R.parseCommand("WG SIG FOX7 -88 6")?.args, ["-88", "6"])
        XCTAssertEqual(R.parseCommand("wg found 4417")?.args, ["4417"])
        XCTAssertNil(R.parseCommand("WG PING"))
        XCTAssertNil(R.parseCommand("hello"))
    }

    func testParseSigForms() {
        func p(_ a: [String]) -> [Double?] { let r = R.parseSig(a); return [r.rssi, r.snr] }
        XCTAssertEqual(p(["-88"]), [-88, nil])
        XCTAssertEqual(p(["-88", "6.5"]), [-88, 6.5])
        XCTAssertEqual(p(["-88dBm", "6.5dB"]), [-88, 6.5])
        XCTAssertEqual(p(["SNR", "6.5"]), [nil, 6.5])
        XCTAssertEqual(p(["S-3.25"]), [nil, -3.25])
        XCTAssertEqual(p(["6.5"]), [nil, 6.5])
        XCTAssertEqual(p(["-200"]), [nil, nil])
        XCTAssertEqual(p(["banana"]), [nil, nil])
    }

    func testEventFromPacketCarriesRelayAndHops() {
        let pkt = MeshPacket(from: maya, to: NodeNum(0xFFFF_FFFF), channel: 5, id: 9, hopLimit: 2, hopStart: 3, relayNode: 0x17,
                             portnum: .text, text: "WG FOUND 4417")
        guard case let .found(_, node, code, relay, hops, channel, _, _) = R.event(from: pkt, text: "WG FOUND 4417", label: nil, at: 100)
        else { return XCTFail() }
        XCTAssertEqual([node.raw, relay ?? 0, UInt32(hops ?? -1), UInt32(channel ?? -1)], [maya.raw, 0x17, 1, 5])
        XCTAssertEqual(code, "4417")
    }

    // MARK: Lobby, join, names

    func testJoinReplyNamesAndFox() {
        var r = hunt()
        let out = r.handle(.join(t: 1, node: maya, name: "maya", channel: 5))
        XCTAssertEqual(texts(out), ["WG OK JOIN FOX7 MAYA 1 HUNTING LOBBY FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>"])
        XCTAssertEqual(out.first?.say?.channel, 5)
        r.handle(.join(t: 2, node: dex, label: "DX-9"))
        XCTAssertEqual(r.hunters[dex]?.name, "DX-9")
        // The join reply parses with the hunter-side parser.
        XCTAssertEqual(WG.Reply(texts(out)[0]), .joined(hunt: "FOX7", name: "MAYA", hunters: 1, phase: .lobby, fox: "ZEUZ"))
    }

    func testFoundBeforeStartIsRejected() {
        var r = hunt()
        XCTAssertEqual(found(&r, 5, maya, "4417"), ["WG NO FOUND FOX7 NOT STARTED"])
    }

    func testStartTellsEveryHunter() {
        var r = hunt()
        r.handle(.join(t: 1, node: maya))
        XCTAssertTrue(texts(r.handle(.start(t: 10)))[0].hasPrefix("WG GO FOX7 HUNT IS LIVE"))
    }

    // MARK: Signal and warmth

    func testWarmerColderAndBest() {
        var r = live()
        XCTAssertEqual(sig(&r, 20, maya, -100), ["WG W FOX7 FIRST -100 BEST -100"])
        XCTAssertEqual(sig(&r, 40, maya, -94), ["WG W FOX7 WARMER -100>-94 BEST -94"])
        XCTAssertEqual(sig(&r, 60, maya, -99), ["WG W FOX7 COLDER -94>-99 BEST -94"])
        XCTAssertEqual(sig(&r, 80, maya, -98), ["WG W FOX7 STEADY -99>-98 BEST -94"])
    }

    func testHotPromptsForTheCode() {
        var r = live()
        XCTAssertEqual(sig(&r, 20, maya, -70, snr: 9), ["WG W FOX7 HOT -70 BEST -70 · FOUND <code>"])
    }

    func testSNROnlyTrend() {
        var r = live()
        sig(&r, 20, maya, snr: -5)
        XCTAssertTrue(sig(&r, 40, maya, snr: -2)[0].contains("WARMER S-5.0>S-2.0"))
    }

    func testSigReplyCooldownStillRecordsSamples() {
        var r = live()
        sig(&r, 20, maya, -100)
        XCTAssertEqual(sig(&r, 25, maya, -90), [])
        XCTAssertEqual(r.hunters[maya]?.samples.count, 2)
        XCTAssertEqual(r.hunters[maya]?.best?.rssi, -90)
    }

    func testAppSamplesNeverTriggerRadioReplies() {
        var r = live()
        XCTAssertEqual(sig(&r, 20, maya, -90, src: .app, hops: 0), [])
    }

    func testRelayedSamplesAreRecordedNotScored() {
        var r = live()
        sig(&r, 20, maya, -60, src: .app, hops: 1)
        XCTAssertEqual(r.hunters[maya]?.samples.count, 1)
        XCTAssertNil(r.hunters[maya]?.best)
        XCTAssertNil(r.hunters[maya]?.last)
    }

    func testUnknownSigAutoJoinsAndBadFormatIsExplained() {
        var r = live()
        let other = NodeNum(0x3333_3333)
        sig(&r, 20, other, -100)
        XCTAssertNotNil(r.hunters[other])
        XCTAssertEqual(sig(&r, 50, other), ["WG NO SIG FORMAT · WG SIG -88 6.5"])
    }

    func testFoxCannotHuntItself() {
        var r = live()
        XCTAssertEqual(r.handle(.sig(t: 20, node: fox, rssi: -40)), [])
        XCTAssertNil(r.hunters[fox])
    }

    // MARK: Finds and proof tags

    func testBadCodeCountsAndLocks() {
        var r = live()
        for i in 1...5 {
            XCTAssertEqual(found(&r, Double(20 + i), maya, "0000"), ["WG NO FOUND FOX7 BADCODE \(i)/5"])
        }
        XCTAssertEqual(found(&r, 30, maya, "4417"), ["WG NO FOUND FOX7 LOCKED"])
    }

    func testCodeOnlyFind() {
        var r = live()
        let out = found(&r, 10 + 14 * 60, maya, "4417")
        XCTAssertEqual(out[0], "WG OK FOUND FOX7 #1 +100 CODE T+14M")
        XCTAssertTrue(out.contains("WG FOUND FOX7 MAYA #1 T+14M"))
        XCTAssertEqual(WG.Reply(out[0]), .youFound(hunt: "FOX7", place: 1, points: 100, proofs: [.code], minutes: 14))
    }

    func testAttestedPlusCode() {
        var r = live()
        sig(&r, 100, maya, -70)
        XCTAssertTrue(found(&r, 200, maya, "4417")[0].hasPrefix("WG OK FOUND FOX7 #1 +125 RF-B+CODE"))
        XCTAssertEqual(r.hunters[maya]?.found?.proofs, [.rfAttested, .code])
    }

    func testAttestationExpires() {
        var r = live()
        sig(&r, 100, maya, -70)
        _ = found(&r, 100 + 301, maya, "4417")
        XCTAssertEqual(r.hunters[maya]?.found?.proofs, [.code])
    }

    func testWitnessedWhenTheFoxRelayedTheClaim() {
        var r = live()
        let out = found(&r, 50, maya, "4417", relay: 0x17, hops: 1)
        XCTAssertEqual(r.hunters[maya]?.found?.proofs, [.rfWitnessed, .code])
        XCTAssertTrue(out[0].contains("+150"))
    }

    func testRelayByteFromSomeoneElseIsNotWitnessed() {
        var r = live()
        _ = found(&r, 50, maya, "4417", relay: 0x42, hops: 1)
        XCTAssertEqual(r.hunters[maya]?.found?.proofs, [.code])
    }

    func testCodeModeNeedsTheCode() {
        var r = live()
        sig(&r, 20, maya, -60)
        XCTAssertEqual(found(&r, 30, maya), ["WG NO FOUND FOX7 NEED CODE"])
    }

    func testSignalModeAutoFindsOnThreshold() {
        var r = live(.signal)
        let out = sig(&r, 20, maya, -72, src: .app, hops: 0)
        XCTAssertEqual(r.hunters[maya]?.found?.proofs, [.rfAttested])
        XCTAssertEqual(out[0], "WG OK FOUND FOX7 #1 +125 RF-B T+0M")
    }

    func testEitherModeAcceptsACodelessClaimWithAttestation() {
        var r = live(.either)
        sig(&r, 20, maya, -80)
        XCTAssertTrue(found(&r, 30, maya)[0].contains("NEED CODE"))
        sig(&r, 40, maya, -74)
        XCTAssertEqual(r.hunters[maya]?.found?.proofs, [.rfAttested])
    }

    func testPlacesRepeatRulingsAndAutoEnd() {
        var r = live()
        _ = found(&r, 100, maya, "4417")
        XCTAssertEqual(found(&r, 110, maya, "4417"), ["WG OK FOUND FOX7 #1 +100 CODE T+1M"])
        let out = found(&r, 200, dex, "4417")
        XCTAssertEqual(out[0], "WG OK FOUND FOX7 #2 +70 CODE T+3M")
        XCTAssertEqual(r.hunt?.phase, .ended)
        XCTAssertEqual(r.hunt?.winner, "MAYA")
        XCTAssertTrue(out.contains("WG END FOX7 MAYA WINS 2/2 FOUND"))
    }

    func testFoundAfterEnd() {
        var r = live()
        r.handle(.end(t: 100))
        XCTAssertEqual(found(&r, 110, maya, "4417"), ["WG NO FOUND FOX7 OVER"])
    }

    // MARK: Secrecy and replay

    func testBoardHidesTheCodeAndFoxPositionUntilTheEnd() {
        var r = live()
        r.handle(.foxHeard(t: 30, node: fox, position: Coordinate(latitude: 38.9, longitude: -84.6)))
        let b = r.board!
        XCTAssertEqual(b.hunt.foxCode, "")
        XCTAssertNil(b.foxPosition)
        XCTAssertEqual(b.hunt.foxSeen, 30)
        r.handle(.end(t: 40))
        XCTAssertEqual(r.board?.foxPosition?.latitude, 38.9)
    }

    func testReplayReproducesTheHunt() {
        var r = live()
        r.handle(.position(t: 15, node: maya, position: Coordinate(latitude: 38.9, longitude: -84.6)))
        sig(&r, 20, maya, -90)
        sig(&r, 40, maya, -72)
        _ = found(&r, 60, maya, "4417", relay: 0x17, hops: 1)
        XCTAssertEqual(R.replay(r.events).board, r.board)
    }

    // MARK: Time limit

    /// A live hunt with a 10-minute limit: started at t = 10, so it runs out at 610.
    func timed(_ limit: TimeInterval? = 600) -> R {
        var r = R()
        r.handle(.create(t: 0, fox: fox, foxCode: "4417", code: "FOX7", foxLabel: "ZEUZ", timeLimit: limit))
        r.handle(.join(t: 1, node: maya, name: "maya"))
        r.handle(.join(t: 2, node: dex, label: "DX-9"))
        r.handle(.start(t: 10))
        return r
    }

    func testTimeLimitEndsTheHuntOnTheNextEventAfterTheDeadline() {
        var r = timed()
        XCTAssertEqual(sig(&r, 300, maya, -100), ["WG W FOX7 FIRST -100 BEST -100"])
        let out = found(&r, 700, maya, "4417")
        XCTAssertEqual(out, ["WG END FOX7 NO FINDS 0/2 FOUND · TIME UP", "WG END FOX7 NO FINDS 0/2 FOUND · TIME UP",
                             "WG NO FOUND FOX7 OVER"])
        XCTAssertEqual(r.hunt?.phase, .ended)
        XCTAssertEqual(r.hunt?.endedAt, 610, "it ended at the deadline, not when it was noticed")
        XCTAssertEqual(r.hunt?.endReason, .time)
        XCTAssertNil(r.hunters[maya]?.found)
    }

    func testTheEndBroadcastStillParsesAndSaysTimeUp() {
        var r = timed()
        let line = texts(r.handle(.tick(t: 610)))[0]
        XCTAssertEqual(WG.Reply(line), .ended(hunt: "FOX7", winner: nil, found: 0, total: 2))
        XCTAssertTrue(WG.isTimeUp(line))
        XCTAssertFalse(WG.isTimeUp("WG END FOX7 NO FINDS 0/2 FOUND"))
        XCTAssertFalse(WG.isTimeUp("WG END FOX7 NO FINDS 0/2 FOUND TIME UP"), "only as a hint after the dot")
    }

    func testTickBeforeTheDeadlineDoesNothing() {
        var r = timed()
        let before = r.events.count
        XCTAssertEqual(r.handle(.tick(t: 609.9)), [])
        XCTAssertEqual(r.events.count, before, "a tick that changes nothing isn't recorded")
        XCTAssertEqual(r.hunt?.phase, .live)
        let out = r.handle(.tick(t: 610))
        XCTAssertEqual(out.last, .ended)
        XCTAssertEqual(texts(out).count, 2, "both hunters told")
        XCTAssertEqual(r.events.last, .tick(t: 610), "the tick that ended it is recorded, so a replay ends too")
        XCTAssertEqual(r.handle(.tick(t: 700)), [], "ends once")
    }

    func testTheLimitCountsFromTheStartNotTheLobby() {
        var r = R()
        r.handle(.create(t: 0, fox: fox, foxCode: "4417", timeLimit: 600))
        r.handle(.join(t: 1, node: maya))
        XCTAssertEqual(r.handle(.tick(t: 5000)), [])
        XCTAssertEqual(r.hunt?.phase, .lobby)
        XCTAssertNil(r.deadline)
        XCTAssertEqual(r.timeRemaining(at: 5000), 600, "the whole limit until it starts")
        r.handle(.start(t: 6000))
        XCTAssertEqual(r.deadline, 6600)
        XCTAssertEqual(r.handle(.tick(t: 6599)), [])
        XCTAssertEqual(r.handle(.tick(t: 6600)).last, .ended)
    }

    func testDeadlineAndTimeRemaining() {
        var r = timed()
        XCTAssertEqual(r.deadline, 610)
        XCTAssertEqual(r.hunt?.timeLimit, 600)
        XCTAssertEqual(r.timeRemaining(at: 110), 500)
        XCTAssertEqual(r.timeRemaining(at: 900), 0, "never negative, even before the next event")
        XCTAssertEqual(r.board?.hunt.timeRemaining(at: 110), 500, "the board carries it too")
        r.handle(.end(t: 200))
        XCTAssertEqual(r.timeRemaining(at: 500), 410, "frozen at the end")
        XCTAssertEqual(r.hunt?.endReason, .host)
    }

    func testNoLimitBehavesAsBefore() {
        var r = timed(nil)
        XCTAssertNil(r.hunt?.timeLimit)
        XCTAssertNil(r.deadline)
        XCTAssertNil(r.timeRemaining(at: 100))
        let before = r.events.count
        XCTAssertEqual(r.handle(.tick(t: 1e9)), [])
        XCTAssertEqual(r.events.count, before)
        XCTAssertEqual(found(&r, 1e9, maya, "4417")[0], "WG OK FOUND FOX7 #1 +100 CODE T+16666666M")
        XCTAssertEqual(r.hunt?.phase, .live)
        // Same events, same outputs as a hunt created without the new field at all.
        var plain = live()
        var limitless = R()
        limitless.handle(.create(t: 0, fox: fox, foxCode: "4417", code: "FOX7", mode: .code, foxLabel: "ZEUZ", timeLimit: nil))
        limitless.handle(.join(t: 1, node: maya, name: "maya"))
        limitless.handle(.join(t: 2, node: dex, label: "DX-9"))
        limitless.handle(.start(t: 10))
        for e: R.Event in [.sig(t: 20, node: maya, rssi: -90), .found(t: 30, node: maya, code: "4417"), .found(t: 40, node: dex, code: "4417")] {
            XCTAssertEqual(plain.handle(e), limitless.handle(e))
        }
        XCTAssertEqual(plain.board, limitless.board)
    }

    func testNonsenseLimitsMeanNoLimit() {
        for limit in [0, -5, .infinity, .nan] as [TimeInterval] {
            var r = R()
            r.handle(.create(t: 0, fox: fox, foxCode: "4417", timeLimit: limit))
            XCTAssertNil(r.hunt?.timeLimit, "\(limit)")
        }
    }

    func testEndReasonIsRecorded() {
        var host = live()
        host.handle(.end(t: 50))
        XCTAssertEqual(host.hunt?.endReason, .host)
        var all = timed()
        _ = found(&all, 100, maya, "4417")
        let out = found(&all, 200, dex, "4417")
        XCTAssertEqual(all.hunt?.endReason, .allFound)
        XCTAssertTrue(out.contains("WG END FOX7 MAYA WINS 2/2 FOUND"), "no time hint when time didn't end it")
        var time = timed()
        time.handle(.tick(t: 611))
        XCTAssertEqual(time.hunt?.endReason, .time)
        XCTAssertNil(live().hunt?.endReason)
    }

    func testReplayEndsOnTimeToo() {
        var r = timed()
        sig(&r, 20, maya, -90)
        r.handle(.tick(t: 300))
        r.handle(.tick(t: 615))
        XCTAssertEqual(R.replay(r.events), r)
        XCTAssertEqual(R.replay(r.events).hunt?.endReason, .time)
    }

    // MARK: Saving

    /// A hunt in full swing on real clock times: positions, a walk with a bearing, a wrong
    /// code, a find, someone who left, a time limit.
    func midHunt() -> R {
        let t0 = 1_790_000_000.123456
        var r = R()
        r.handle(.create(t: t0, fox: fox, foxCode: "4417", code: "FOXQ7", mode: .either, foxLabel: "ZEUZ", timeLimit: 1200))
        r.handle(.join(t: t0 + 1.5, node: maya, name: "maya", channel: 2))
        r.handle(.join(t: t0 + 2.25, node: dex, label: "DX-9"))
        r.handle(.join(t: t0 + 3, node: NodeNum(0x3333_3333)))
        r.handle(.start(t: t0 + 10.001))
        r.handle(.foxHeard(t: t0 + 11, node: fox, position: Coordinate(latitude: 38.912345678, longitude: -84.612345678)))
        let lat0 = 38.9, lon0 = -84.6, kx = 111_320 * cos(lat0 * .pi / 180)
        for (i, en) in [(0.0, 0.0), (40, 0), (0, 40), (40, 40), (20, 20)].enumerated() {
            r.handle(.sig(t: t0 + 20 + Double(i) * 16.7, node: maya, rssi: -100 + 0.2 * en.1, snr: 3.25,
                          position: Coordinate(latitude: lat0 + en.1 / 110_574, longitude: lon0 + en.0 / kx)))
        }
        r.handle(.position(t: t0 + 30, node: dex, position: Coordinate(latitude: 38.91, longitude: -84.61)))
        r.handle(.sig(t: t0 + 31, node: dex, rssi: -88, hops: 1))
        r.handle(.sig(t: t0 + 32, node: dex, snr: -7.5))
        r.handle(.found(t: t0 + 40, node: dex, code: "0000"))
        r.handle(.leave(t: t0 + 41, node: NodeNum(0x3333_3333)))
        r.handle(.found(t: t0 + 200.5, node: maya, code: "4417", relayNode: 0x17, hops: 1))
        return r
    }

    func testCodableRoundTripMidHuntGivesTheSameOutputs() throws {
        var original = midHunt()
        XCTAssertNotNil(original.hunters[maya]?.bearing, "the walk gave a bearing")
        let data = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(R.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.board, original.board)
        let t0 = 1_790_000_000.123456
        let next: [R.Event] = [
            .sig(t: t0 + 300, node: dex, rssi: -90),
            .status(t: t0 + 301, node: dex),
            .found(t: t0 + 302, node: dex, code: "1111"),
            .join(t: t0 + 303, node: NodeNum(0x4444_4444), name: "rio"),
            .tick(t: t0 + 400),
            .found(t: t0 + 500, node: NodeNum(0x4444_4444), code: "4417"),
            .tick(t: t0 + 1300),
            .found(t: t0 + 1301, node: dex, code: "4417"),
        ]
        for e in next {
            XCTAssertEqual(restored.handle(e), original.handle(e), "\(e)")
            XCTAssertEqual(restored.board, original.board, "\(e)")
        }
        XCTAssertEqual(restored, original)
        XCTAssertEqual(original.hunt?.endReason, .time)
    }

    func testSavedRefereeIsSmallAndOrdered() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let a = try enc.encode(midHunt()), b = try enc.encode(midHunt())
        XCTAssertEqual(a, b, "the same hunt saves byte for byte the same")
        let restored = try JSONDecoder().decode(R.self, from: a)
        XCTAssertEqual(try enc.encode(restored), a)
        XCTAssertEqual(R().board, try JSONDecoder().decode(R.self, from: enc.encode(R())).board)
    }

    func testBoardTiesFollowJoinOrder() {
        var r = hunt()
        for (i, raw) in [0x5555_5555, 0x1111_1111, 0x3333_3333] .enumerated() {
            r.handle(.join(t: Double(i), node: NodeNum(UInt32(raw))))
        }
        XCTAssertEqual(r.board?.hunters.map(\.id.raw), [0x5555_5555, 0x1111_1111, 0x3333_3333])
    }

    // MARK: Bearing

    func testBearingPointsUphill() {
        let lat0 = 38.9, lon0 = -84.6
        let kx = 111_320 * cos(lat0 * .pi / 180)
        let samples = [(0.0, 0.0), (40, 0), (0, 40), (40, 40), (20, 20)].enumerated().map { i, en in
            R.Sample(t: Double(i), rssi: nil, snr: nil, score: 50 + 0.2 * en.1, src: .mesh, hops: 0, direct: true,
                     position: Coordinate(latitude: lat0 + en.1 / 110_574, longitude: lon0 + en.0 / kx))
        }
        let b = try? XCTUnwrap(R.fitBearing(samples))
        XCTAssertNotNil(b)
        XCTAssertTrue((b?.degrees ?? 180) < 5 || (b?.degrees ?? 180) > 355)
    }

    func testNoBearingWithoutMovement() {
        let samples = (0..<6).map { i in
            R.Sample(t: Double(i), rssi: nil, snr: nil, score: 50 + Double(i), src: .mesh, hops: 0, direct: true,
                     position: Coordinate(latitude: 38.9, longitude: -84.6))
        }
        XCTAssertNil(R.fitBearing(samples))
    }

    func testRefereeHeardHunterPositionGivesTypedSamplesALocation() {
        var r = live()
        r.handle(.position(t: 15, node: maya, position: Coordinate(latitude: 38.9, longitude: -84.6)))
        sig(&r, 20, maya, -90)
        XCTAssertEqual(r.hunters[maya]?.samples.last?.position?.latitude, 38.9)
        sig(&r, 500, maya, -90)
        XCTAssertNil(r.hunters[maya]?.samples.last?.position)
    }
}
