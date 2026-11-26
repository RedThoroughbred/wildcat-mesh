import XCTest
@testable import WildcatRadioCore

/// The practice node (App Review and screenshots have no radio): its history carries
/// the same message details a real mesh gives, and it answers what the app sends.
final class MeshCorePracticeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// Runs the practice node second by second, feeding what it says into the session.
    func run(_ p: inout MeshCorePractice, _ s: inout MeshCoreSession, from start: Date, seconds: Int,
             until done: (MeshCoreSession) -> Bool = { _ in false }) -> Int? {
        for k in 1...seconds {
            let now = start.addingTimeInterval(Double(k))
            for f in p.step(now: now, session: s) { _ = s.handle(f, now: now) }
            if done(s) { return k }
        }
        return nil
    }

    func testHistoryCarriesMessageDetails() throws {
        let s = MeshCoreSession.demo(now: t0)
        let public_ = s.conversationChats.filter { $0.origin == .channel(0) }
        XCTAssertGreaterThanOrEqual(public_.count, 6)
        let senders = Set(public_.compactMap(\.channelSender))
        XCTAssertGreaterThanOrEqual(senders.count, 3)
        for c in public_ where c.direction == .received {
            XCTAssertNotNil(c.rssi, c.text)
            XCTAssertNotNil(c.packetHash, c.text)
            XCTAssertNotNil(c.size, c.text)
            XCTAssertNotNil(c.airtimeMs, c.text)
            XCTAssertNotNil(c.receivedAt, c.text)
            XCTAssertEqual(c.path?.count, c.hops, c.text)
        }
        XCTAssertEqual(Set(public_.compactMap { $0.path?.count }), [0, 1, 2], "varied hops")

        let bridged = try XCTUnwrap(public_.first { $0.bridged != nil }?.bridged)
        XCTAssertEqual(bridged.network, .meshtastic)
        XCTAssertEqual(bridged.channel, "LongFast")
        XCTAssertEqual(bridged.via, "Park Bridge")
        XCTAssertEqual(bridged.senderName, "KITE")

        let mine = try XCTUnwrap(public_.first { $0.direction == .sent })
        XCTAssertEqual(mine.heardBy, 3)
        XCTAssertEqual(mine.heardFrom?.count, 3)
        XCTAssertNotNil(mine.packetHash)

        let maya = MeshCorePractice.key(0x51).prefix(6)
        let dm = s.conversationChats.filter { $0.origin == .contact(maya) }
        XCTAssertGreaterThanOrEqual(dm.filter { $0.direction == .received && $0.rssi != nil }.count, 2)
        let sentDM = dm.filter { $0.direction == .sent }
        XCTAssertFalse(sentDM.isEmpty)
        XCTAssertTrue(sentDM.allSatisfy { $0.confirmed && $0.roundTripMs != nil })
    }

    func testChannelSendIsRepeatedThenAnswered() throws {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 7)
        let before = s.chats.count
        let id = s.sent("Test from the park", to: .channel(0), at: t0)
        XCTAssertEqual(p.command(.sendChannelText(channel: 0, text: "Test from the park", at: t0), session: s, now: t0), [.ok])

        let heard = run(&p, &s, from: t0, seconds: 6) { ($0.chats.first { $0.id == id }?.heardBy ?? 0) >= 2 }
        XCTAssertNotNil(heard, "repeaters echo it within a few seconds")
        let c = try XCTUnwrap(s.chats.first { $0.id == id })
        XCTAssertNotNil(c.packetHash)
        XCTAssertNotNil(c.size)

        let replied = run(&p, &s, from: t0.addingTimeInterval(6), seconds: 6) {
            $0.chats.dropFirst(before + 1).contains { $0.direction == .received && $0.origin == .channel(0) && $0.rssi != nil }
        }
        XCTAssertNotNil(replied, "someone answers 5-10 s later, with signal and path")
    }

    func testOneReplyAtATime() {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 3)
        let before = s.conversationChats.filter { $0.direction == .received }.count
        for k in 0..<5 {
            let at = t0.addingTimeInterval(Double(k))
            _ = s.sent("spam \(k)", to: .channel(0), at: at)
            _ = p.command(.sendChannelText(channel: 0, text: "spam \(k)", at: at), session: s, now: at)
        }
        _ = run(&p, &s, from: t0, seconds: 12)
        let replies = s.conversationChats.filter { $0.direction == .received }.count - before
        XCTAssertEqual(replies, 1)
    }

    func testDirectMessageIsConfirmedAndAnswered() throws {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 11)
        let maya = try XCTUnwrap(s.contacts.values.first { $0.name == "MAYA Field Unit" })
        let id = s.sent("hi", to: .contact(maya.prefix), at: t0)
        let first = p.command(.sendText(to: maya.prefix, text: "hi", at: t0), session: s, now: t0)
        guard case .sent(_, let ack, _)? = first.first else { return XCTFail("the node says it's on its way") }
        s.attachAck(ack, to: id)
        XCTAssertNotNil(run(&p, &s, from: t0, seconds: 4) { $0.chats.first { $0.id == id }?.confirmed == true })
        XCTAssertNotNil(s.chats.first { $0.id == id }?.roundTripMs)
        XCTAssertNotNil(run(&p, &s, from: t0.addingTimeInterval(4), seconds: 8) {
            $0.chats.last.map { $0.direction == .received && $0.origin == .contact(maya.prefix) && $0.rssi != nil } ?? false
        }, "MAYA writes back, and her packet is paired with the message")
    }

    func testAirKeepsBusyWithParseablePackets() throws {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 5)
        var raws: [Data] = []
        for k in 1...40 {
            let now = t0.addingTimeInterval(Double(k))
            for f in p.step(now: now, session: s) {
                if case .rxLog(_, _, let raw) = f { raws.append(raw) }
                _ = s.handle(f, now: now)
            }
        }
        XCTAssertGreaterThanOrEqual(raws.count, 8, "a packet every few seconds")
        let packets = raws.compactMap(MeshCorePacket.init)
        XCTAssertEqual(packets.count, raws.count, "every one parses")
        let adverts = packets.compactMap(\.advert)
        XCTAssertGreaterThanOrEqual(Set(adverts.map(\.name)).count, 3)
        XCTAssertTrue(adverts.allSatisfy { a in s.contacts[a.publicKey]?.name == a.name })
        XCTAssertTrue(packets.contains { $0.type == .groupText })
        XCTAssertLessThanOrEqual(s.conversationChats.count, MeshCoreSession.demo(now: t0).conversationChats.count,
                                 "no chatter in the first 40 s")
    }

    func testTrimKeepsNewestPerConversation() {
        var s = MeshCoreSession.demo(now: t0)
        for k in 0..<30 { _ = s.sent("line \(k)", to: .channel(0), at: t0.addingTimeInterval(Double(k))) }
        let dm = s.conversationChats.filter { $0.origin != .channel(0) }.count
        s.trimChats(keepingPerConversation: MeshCorePractice.keepPerChat)
        let pub = s.chats.filter { $0.origin == .channel(0) }
        XCTAssertEqual(pub.count, 20)
        XCTAssertEqual(pub.last?.text, "line 29")
        XCTAssertEqual(s.conversationChats.filter { $0.origin != .channel(0) }.count, dm, "other chats untouched")
    }

    // MARK: 1.1: placed anywhere, settings, adding contacts, the fox

    /// Sends a command to the practice node the way the link does: its answer goes to
    /// `answered`, every frame to `handle`, and follow-ups are sent in turn.
    @discardableResult
    func perform(_ c: MeshCore.Command, _ p: inout MeshCorePractice, _ s: inout MeshCoreSession, now: Date) -> [MeshCoreSession.Event] {
        var events: [MeshCoreSession.Event] = []
        var answered = false
        for f in p.command(c, session: s, now: now) {
            if !answered, MeshCoreSession.completes(c, with: f) {
                answered = true
                let r = s.answered(c, with: f, now: now)
                events += r.events
                for x in r.follow { events += perform(x, &p, &s, now: now) }
            }
            events += s.handle(f, now: now).events
        }
        return events
    }

    func testCentredWhereTheAppSays() {
        // Made-up coordinates (not anyone's real location).
        let centre = Coordinate(latitude: 37.8044, longitude: -122.4100)
        let s = MeshCoreSession.demo(now: t0, center: centre)
        let placed = s.contacts.values.compactMap(\.position)
        XCTAssertEqual(placed.count, 4)
        XCTAssertTrue(placed.allSatisfy { PracticeGeo.distance($0, centre) < 3000 }, "around the given centre")
        let park = MeshCoreSession.demo(now: t0).contacts.values.compactMap(\.position)
        XCTAssertTrue(park.allSatisfy { PracticeGeo.distance($0, MeshCorePractice.park) < 3000 }, "else the park")
        let p = MeshCorePractice(now: t0, seed: 1, center: centre)
        XCTAssertEqual(PracticeGeo.distance(p.foxSpot, centre), 420, accuracy: 2, "the fox hides a short walk away")
    }

    func testSettingsChangeThePretendNode() throws {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 2)
        XCTAssertEqual(p.command(.setName("Trail Kit"), session: s, now: t0), [.ok])
        perform(.appStart(name: "Wildcat"), &p, &s, now: t0)   // refreshSelf, as the link does after each setting
        XCTAssertEqual(s.me?.name, "Trail Kit")

        XCTAssertEqual(p.command(.setRadio(frequency: 869.618, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8), session: s, now: t0), [.ok])
        XCTAssertEqual(p.command(.setRadio(frequency: 869.618, bandwidth: 62.5, spreadingFactor: 13, codingRate: 8), session: s, now: t0),
                       [.error(code: 6)], "the firmware's limits: SF 5-12")
        XCTAssertEqual(p.command(.setRadio(frequency: 100, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8), session: s, now: t0), [.error(code: 6)])
        XCTAssertEqual(p.command(.setTxPower(30), session: s, now: t0), [.error(code: 6)], "over the node's maximum")
        XCTAssertEqual(p.command(.setTxPower(14), session: s, now: t0), [.ok])
        let here = Coordinate(latitude: 37.77, longitude: -122.45)
        XCTAssertEqual(p.command(.setPosition(here), session: s, now: t0), [.ok])
        XCTAssertEqual(p.command(.setOtherParams(manualAddContacts: 1, telemetryModes: 0, advertLocationPolicy: 1, multiAcks: 1),
                                 session: s, now: t0), [.ok])
        perform(.appStart(name: "Wildcat"), &p, &s, now: t0)
        let me = try XCTUnwrap(s.me)
        XCTAssertEqual(me.frequency, 869.618, accuracy: 1e-9)
        XCTAssertEqual([me.spreadingFactor, me.codingRate, me.txPower], [8, 8, 14])
        XCTAssertEqual(me.bandwidth, 62.5)
        XCTAssertEqual(me.position, here)
        XCTAssertEqual([me.manualAddContacts, me.advertLocationPolicy, me.multiAcks], [1, 1, 1])

        XCTAssertEqual(p.command(.setPIN(1234), session: s, now: t0), [.error(code: 6)], "6 digits or 0")
        XCTAssertEqual(p.command(.setPIN(246_810), session: s, now: t0), [.ok])
        XCTAssertEqual(p.pin, 246_810)
        XCTAssertEqual(p.command(.getBatteryAndStorage, session: s, now: t0).count, 1)
        XCTAssertEqual(p.command(.deviceQuery, session: s, now: t0).count, 1)
    }

    func testChannelsAddAndRemoveLikeARealNode() {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 4)
        let key = Data(repeating: 0x42, count: 16)
        // addChannel: set, then read back.
        XCTAssertEqual(p.command(.setChannel(index: 2, name: "WGHUNT", secret: key), session: s, now: t0), [.ok], "OK only, like the firmware")
        perform(.getChannel(index: 2), &p, &s, now: t0)
        XCTAssertEqual(s.channels[2]?.name, "WGHUNT")
        XCTAssertEqual(s.channels[2]?.secret, key)
        // Slots past 7 exist on v1.17 (40).
        XCTAssertEqual(p.command(.setChannel(index: 12, name: "#park", secret: key), session: s, now: t0), [.ok])
        XCTAssertEqual(p.command(.getChannel(index: 40), session: s, now: t0), [.error(code: 2)])
        // Remove: empty name, zero key.
        perform(.setChannel(index: 2, name: "", secret: Data(count: 16)), &p, &s, now: t0)
        perform(.getChannel(index: 2), &p, &s, now: t0)
        XCTAssertNil(s.channels[2])
    }

    func testHeardOnlyContactIsAddedThenAnswers() throws {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 9)
        let nova = try XCTUnwrap(s.contacts.values.first { $0.name == "NOVA Hiker" })
        XCTAssertFalse(s.isOnNode(nova), "heard, not added")
        XCTAssertEqual(p.command(.sendText(to: nova.prefix, text: "hi", at: t0), session: s, now: t0), [.error(code: 2)],
                       "the practice node refuses, as a real one would")

        var p2 = MeshCorePractice(now: t0, seed: 9)
        let (id, cmds) = s.sendDirect("hi", to: nova, at: t0, now: t0)
        XCTAssertEqual(cmds.first, .addContact(nova))
        for c in cmds { perform(c, &p2, &s, now: t0) }
        XCTAssertTrue(s.isOnNode(nova))
        XCTAssertEqual(s.chats.first { $0.id == id }?.delivery, .sent(attempt: 0, flood: true))
        let delivered = try XCTUnwrap(run(&p2, &s, from: t0, seconds: 12) { $0.chats.first { $0.id == id }?.delivery == .delivered })
        XCTAssertNotNil(run(&p2, &s, from: t0.addingTimeInterval(Double(delivered)), seconds: 12) {
            $0.chats.contains { $0.origin == .contact(nova.prefix) && $0.direction == .received }
        }, "and she writes back")
        // The practice node now lists her.
        perform(.getContacts, &p2, &s, now: t0.addingTimeInterval(13))
        XCTAssertTrue(s.isOnNode(nova))
    }

    func testDexsFirstTryIsLostSoPracticeShowsARetry() throws {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 13)
        let dex = try XCTUnwrap(s.contacts.values.first { $0.name == "DEX Trail Node" })
        let (id, cmds) = s.sendDirect("you there?", to: dex, at: t0, now: t0)
        for c in cmds { perform(c, &p, &s, now: t0) }
        var seen: [MeshCoreSession.Chat.Delivery] = []
        for k in 1...30 {
            let now = t0.addingTimeInterval(Double(k))
            for f in p.step(now: now, session: s) {
                for e in s.handle(f, now: now).events { if case .delivery(id, let d) = e { seen.append(d) } }
            }
            let r = s.tick(now: now)
            for e in r.events { if case .delivery(id, let d) = e { seen.append(d) } }
            for c in r.follow { for e in perform(c, &p, &s, now: now) { if case .delivery(id, let d) = e { seen.append(d) } } }
        }
        XCTAssertEqual(seen.first, .sending(attempt: 1))
        XCTAssertTrue(seen.contains(.sent(attempt: 1, flood: false)))
        XCTAssertEqual(seen.last, .delivered)
    }

    func testFoxCanBeHuntedByPinging() throws {
        var s = MeshCoreSession.demo(now: t0)
        var p = MeshCorePractice(now: t0, seed: 21)
        let fox = try XCTUnwrap(s.contacts.values.first { $0.name == "Practice Fox RPT" })
        XCTAssertEqual(fox.kind, .repeater)
        XCTAssertNil(fox.position, "hidden: find it by signal")

        var readings: [(at: Int, rssi: Int)] = []
        func listen(_ seconds: ClosedRange<Int>) {
            for k in seconds {
                let now = t0.addingTimeInterval(Double(k))
                for f in p.step(now: now, session: s) {
                    if case .rxLog(_, let rssi, let raw) = f, MeshCorePacket(raw)?.transmitted(by: fox.publicKey) == true {
                        readings.append((k, rssi))
                    }
                    _ = s.handle(f, now: now)
                }
            }
        }
        listen(1...20)
        XCTAssertGreaterThanOrEqual(readings.count, 3, "it's on air every few seconds, heard straight from it")
        XCTAssertFalse(p.hunting)

        // A ping (status request) answers with a packet from the fox itself, and starts the walk.
        guard case .sent? = p.command(.statusRequest(publicKey: fox.publicKey), session: s, now: t0.addingTimeInterval(20)).first
        else { return XCTFail("the node says the request went out") }
        XCTAssertTrue(p.hunting)
        var statuses = 0
        for k in 21...24 {
            let now = t0.addingTimeInterval(Double(k))
            for f in p.step(now: now, session: s) {
                if case .status(let prefix, _) = f, prefix == fox.prefix { statuses += 1 }
                if case .rxLog(_, _, let raw) = f, let pk = MeshCorePacket(raw), pk.type == .response {
                    XCTAssertTrue(pk.transmitted(by: fox.publicKey), "the answer counts as a reading")
                }
            }
        }
        XCTAssertEqual(statuses, 1)
        readings.removeAll()
        listen(25...200)
        let early = readings.prefix(4).map(\.rssi).reduce(0, +) / 4
        let late = readings.suffix(4).map(\.rssi).reduce(0, +) / 4
        XCTAssertGreaterThan(late, early + 15, "louder as you close in")
        XCTAssertLessThan(p.distanceToFox, 100)
    }

    func testFoxFollowsThePlayersRealPosition() throws {
        let centre = Coordinate(latitude: 37.8044, longitude: -122.4100)
        var s = MeshCoreSession.demo(now: t0, center: centre)
        var p = MeshCorePractice(now: t0, seed: 5, center: centre)
        let fox = MeshCorePractice.key(MeshCorePractice.fox.byte)
        func loudest(_ from: Int) -> Int {
            var best = -200
            for k in from..<(from + 12) {
                let now = t0.addingTimeInterval(Double(k))
                for f in p.step(now: now, session: s) {
                    if case .rxLog(_, let rssi, let raw) = f, MeshCorePacket(raw)?.transmitted(by: fox) == true { best = max(best, rssi) }
                    _ = s.handle(f, now: now)
                }
            }
            return best
        }
        p.walker = centre
        let far = loudest(1)
        p.walker = PracticeGeo.offset(p.foxSpot, metres: 8, bearing: 0)
        XCTAssertEqual(p.distanceToFox, 8, accuracy: 0.5)
        let near = loudest(13)
        XCTAssertLessThan(far, -95)
        XCTAssertGreaterThan(near, -70)
    }
}
