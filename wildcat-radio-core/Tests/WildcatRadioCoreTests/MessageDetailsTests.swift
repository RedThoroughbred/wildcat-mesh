import XCTest
@testable import WildcatRadioCore

/// Message details: pairing each message with the packet that carried it (RX log,
/// 0x88), repeats of our own channel messages, round trips, bridged origins. Frames
/// are laid out byte for byte as companion firmware v1.17.1 sends them.
final class MessageDetailsTests: XCTestCase {
    let myKey = Data([0xB0] + (1..<32).map { UInt8($0) })
    let mayaKey = Data([0x51] + (1..<32).map { UInt8(0x80 + $0) })
    let secret = Data(repeating: 0x5A, count: 16)
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map {
            UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16) ?? 0
        })
    }

    /// PUSH_CODE_LOG_RX_DATA: snr×4, rssi, then the packet.
    func rxLog(snr: Double, rssi: Int, _ raw: Data) -> MeshCore.Frame {
        (try? MeshCore.decode(Data([0x88, UInt8(bitPattern: Int8(snr * 4)), UInt8(bitPattern: Int8(rssi))]) + raw)) ?? .ok
    }

    /// A flood group text: header 0x15 (flood | GRP_TXT << 2), path, payload.
    func groupText(path: [UInt8], payload: Data) -> Data { Data([0x15, UInt8(path.count)] + path) + payload }

    /// RESP_CODE_CHANNEL_MSG_RECV_V3.
    func channelFrame(_ ch: UInt8, hops: UInt8, at: Date, text: String, snr: Double = 6) -> MeshCore.Frame {
        let ts = UInt32(at.timeIntervalSince1970)
        return (try? MeshCore.decode(Data([0x11, UInt8(bitPattern: Int8(snr * 4)), 0, 0, ch, hops, 0] + le32(ts) + Array(text.utf8)))) ?? .ok
    }

    func session(channel: Int = 1) -> MeshCoreSession {
        var s = MeshCoreSession()
        _ = s.handle(.selfInfo(MeshCore.SelfInfo(advertType: 1, txPower: 22, maxTxPower: 22, publicKey: myKey, position: nil,
                                                 frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5, name: "BASE")))
        _ = s.handle(.channelInfo(index: channel, name: "WGBRIDGE", secret: secret))
        return s
    }

    // MARK: Channel crypto

    func testPublicChannelHashIsTheWellKnownOne() {
        // The Public channel's key; its packets all start with hash 0x11.
        XCTAssertEqual(MeshCoreChannelCrypto.hash(secret: hex("8b3387e9c5cdea6ac9e5edbaa115cd72")), 0x11)
    }

    func testChannelCryptoRoundTrip() throws {
        let plain = MeshCoreChannelCrypto.Plain(timestamp: 1_790_000_000, flags: 0, text: "MAYA: Morning mesh!")
        let payload = try XCTUnwrap(MeshCoreChannelCrypto.encrypt(plain, secret: secret))
        XCTAssertEqual((payload.count - 3) % 16, 0)
        XCTAssertEqual(MeshCoreChannelCrypto.decrypt(payload: payload, secret: secret), plain)
        XCTAssertNil(MeshCoreChannelCrypto.decrypt(payload: payload, secret: Data(repeating: 0x33, count: 16)), "another channel")
        var bad = payload
        bad[bad.count - 1] ^= 1
        XCTAssertNil(MeshCoreChannelCrypto.decrypt(payload: bad, secret: secret), "MAC catches corruption")
    }

    // MARK: Received messages get their packet

    func testChannelMessageGetsTheFirstCopyOfItsPacket() throws {
        var s = session()
        let text = "MAYA: Anyone up by the lake?"
        let payload = try XCTUnwrap(MeshCoreChannelCrypto.encrypt(.init(timestamp: UInt32(t0.timeIntervalSince1970), flags: 0, text: text), secret: secret))
        let other = try XCTUnwrap(MeshCoreChannelCrypto.encrypt(.init(timestamp: UInt32(t0.timeIntervalSince1970), flags: 0, text: "DEX: other"), secret: secret))
        let first = groupText(path: [0xA4, 0xC4], payload: payload)
        _ = s.handle(rxLog(snr: 4.5, rssi: -108, groupText(path: [0x7A], payload: other)), now: t0)
        _ = s.handle(rxLog(snr: 4.5, rssi: -108, first), now: t0.addingTimeInterval(1))
        _ = s.handle(rxLog(snr: 9, rssi: -80, groupText(path: [0x7A, 0x19, 0xE2], payload: payload)), now: t0.addingTimeInterval(1.3))
        let (events, _) = s.handle(channelFrame(1, hops: 2, at: t0, text: text, snr: 4.5), now: t0.addingTimeInterval(1.5))
        guard case .message(let c)? = events.first else { return XCTFail("no message") }
        XCTAssertEqual(c.rssi, -108)
        XCTAssertEqual(c.snr, 4.5)
        XCTAssertEqual(c.path, [Data([0xA4]), Data([0xC4])])
        XCTAssertEqual(c.flood, true)
        XCTAssertEqual(c.size, first.count)
        XCTAssertEqual(c.packetHash, MeshCorePacket(first)?.hash)
        XCTAssertEqual(c.packetHash?.count, 16)
        XCTAssertNotNil(c.airtimeMs)
        XCTAssertEqual(c.receivedAt, t0.addingTimeInterval(1.5))
        XCTAssertEqual(c.radio, myKey.map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(c.raw, "raw only with the debug setting")
        XCTAssertEqual(s.chats.last, c)
    }

    func testRawKeptOnlyWhenAsked() throws {
        var s = session()
        s.keepsRaw = true
        let text = "MAYA: hi"
        let raw = groupText(path: [0x1C], payload: try XCTUnwrap(MeshCoreChannelCrypto.encrypt(
            .init(timestamp: UInt32(t0.timeIntervalSince1970), flags: 0, text: text), secret: secret)))
        _ = s.handle(rxLog(snr: 6, rssi: -90, raw), now: t0)
        _ = s.handle(channelFrame(1, hops: 1, at: t0, text: text), now: t0.addingTimeInterval(0.2))
        XCTAssertEqual(s.chats.last?.raw, raw)
    }

    func testMessageSyncedLaterGetsNoPacket() throws {
        var s = session()
        let payload = try XCTUnwrap(MeshCoreChannelCrypto.encrypt(.init(timestamp: UInt32(t0.timeIntervalSince1970), flags: 0, text: "MAYA: new"), secret: secret))
        _ = s.handle(rxLog(snr: 6, rssi: -90, groupText(path: [], payload: payload)), now: t0)
        // An old message from the node's queue (after a reconnect) arrives at the same moment.
        _ = s.handle(channelFrame(1, hops: 0, at: t0.addingTimeInterval(-3600), text: "MAYA: old"), now: t0.addingTimeInterval(0.2))
        XCTAssertNil(s.chats.last?.rssi)
        XCTAssertNil(s.chats.last?.path)
        XCTAssertEqual(s.chats.last?.snr, 6, "the frame's own SNR stays")
        XCTAssertEqual(s.chats.last?.receivedAt, t0.addingTimeInterval(0.2))
    }

    func testDirectMessageMatchesSourceAndDestinationWithinTwoSeconds() throws {
        var s = session()
        // flood (1) | TXT_MSG (2 << 2) = 0x09; payload: dest hash, src hash, MAC (2), 16 bytes ciphertext.
        func dm(path: [UInt8], src: UInt8 = 0x51, dest: UInt8 = 0xB0, fill: UInt8) -> Data {
            Data([0x09, UInt8(path.count)] + path + [dest, src, 0xAA, 0xBB] + Array(repeating: fill, count: 16))
        }
        func frame(_ text: String) -> MeshCore.Frame {
            (try? MeshCore.decode(Data([0x10, 24, 0, 0] + Array(mayaKey.prefix(6)) + [1, 0] + le32(1_790_000_000) + Array(text.utf8)))) ?? .ok
        }
        _ = s.handle(rxLog(snr: 3, rssi: -99, dm(path: [0x2A], src: 0x66, fill: 1)), now: t0)            // someone else's
        _ = s.handle(rxLog(snr: 3, rssi: -99, dm(path: [0x2A], dest: 0x77, fill: 2)), now: t0)            // not for us
        _ = s.handle(rxLog(snr: 5, rssi: -95, dm(path: [0x2A], fill: 3)), now: t0.addingTimeInterval(0.1))
        _ = s.handle(frame("Leaving a gift"), now: t0.addingTimeInterval(0.4))
        XCTAssertEqual(s.chats.last?.rssi, -95)
        XCTAssertEqual(s.chats.last?.path, [Data([0x2A])])
        XCTAssertEqual(s.chats.last?.snr, 6, "the frame's SNR wins")

        // The same packet never pairs twice, and a stale one doesn't count.
        _ = s.handle(rxLog(snr: 5, rssi: -70, dm(path: [], fill: 4)), now: t0.addingTimeInterval(1))
        _ = s.handle(frame("second"), now: t0.addingTimeInterval(3.5))
        XCTAssertNil(s.chats.last?.rssi)
    }

    // MARK: Our channel messages heard again

    func testRepeatsOfOurChannelMessageCountDistinctRepeaters() throws {
        var s = session()
        let id = s.sent("Solar is up", to: .channel(1), at: t0)
        let ours = try XCTUnwrap(MeshCoreChannelCrypto.encrypt(.init(timestamp: UInt32(t0.timeIntervalSince1970), flags: 0, text: "BASE: Solar is up"), secret: secret))
        let notOurs = try XCTUnwrap(MeshCoreChannelCrypto.encrypt(.init(timestamp: UInt32(t0.timeIntervalSince1970), flags: 0, text: "MAYA: Solar is up"), secret: Data(repeating: 1, count: 16)))
        _ = s.handle(rxLog(snr: 8, rssi: -70, groupText(path: [0x1C], payload: ours)), now: t0.addingTimeInterval(1))
        _ = s.handle(rxLog(snr: 2, rssi: -100, groupText(path: [0x1C, 0x2A], payload: ours)), now: t0.addingTimeInterval(2))
        _ = s.handle(rxLog(snr: 2, rssi: -100, groupText(path: [0x3E, 0x2A], payload: ours)), now: t0.addingTimeInterval(3))
        _ = s.handle(rxLog(snr: 2, rssi: -100, groupText(path: [0x44], payload: notOurs)), now: t0.addingTimeInterval(4))
        _ = s.handle(rxLog(snr: 2, rssi: -100, groupText(path: [0x55], payload: ours)), now: t0.addingTimeInterval(45))   // too late
        let c = try XCTUnwrap(s.chats.first { $0.id == id })
        XCTAssertEqual(c.heardBy, 2)
        XCTAssertEqual(c.heardFrom, [Data([0x1C]), Data([0x2A])])
        XCTAssertEqual(c.size, 2 + ours.count, "as we sent it: no relay hashes")
        XCTAssertEqual(c.packetHash, MeshCorePacket(groupText(path: [], payload: ours))?.hash)
        XCTAssertEqual(c.flood, true)
        XCTAssertEqual(c.radio, s.radioID)
        XCTAssertTrue(s.echoWatches.isEmpty, "the watch closes after 30 s")
    }

    func testNoRepeatsLeavesTheCountEmpty() {
        var s = session()
        let id = s.sent("anyone?", to: .channel(1), at: t0)
        XCTAssertNil(s.chats.first { $0.id == id }?.heardBy)
    }

    // MARK: Round trip

    func testConfirmationStoresRoundTrip() {
        var s = session()
        let id = s.sent("hi", to: .contact(mayaKey.prefix(6)), at: t0)
        s.attachAck(0xDEADBEEF, to: id)
        _ = s.handle((try? MeshCore.decode(Data([0x82] + le32(0xDEADBEEF) + le32(1834)))) ?? .ok, now: t0)
        XCTAssertEqual(s.chats.last?.confirmed, true)
        XCTAssertEqual(s.chats.last?.roundTripMs, 1834)
    }

    // MARK: Bridged lines

    func testBridgeTagsParse() throws {
        let a = try XCTUnwrap(BridgeOrigin.parse("[MT] STAY: copy that", via: "!a3f9c21e"))
        XCTAssertEqual(a.origin, BridgeOrigin(network: .meshtastic, senderName: "STAY", via: "!a3f9c21e"))
        XCTAssertEqual(a.text, "copy that")
        let b = try XCTUnwrap(BridgeOrigin.parse("Bag: [MC] MAYA Field Unit: Howdy: all"))
        XCTAssertEqual(b.origin.network, .meshcore)
        XCTAssertEqual(b.origin.senderName, "MAYA Field Unit")
        XCTAssertEqual(b.origin.via, "Bag")
        XCTAssertEqual(b.text, "Howdy: all")
        XCTAssertNil(BridgeOrigin.parse("MAYA: hello there"))
        XCTAssertNil(BridgeOrigin.parse("hello [MT] there"))
        XCTAssertEqual(BridgeOrigin.parse("[MC] no sender")?.origin.senderName, "")
    }

    func testReceivedBridgedLineGetsItsOrigin() {
        var s = session()
        _ = s.handle(channelFrame(1, hops: 1, at: t0, text: "Bag: [MT] STAY: quiet on my side"), now: t0)
        XCTAssertEqual(s.chats.last?.bridged, BridgeOrigin(network: .meshtastic, senderName: "STAY", via: "Bag"))
        _ = s.handle(channelFrame(1, hops: 1, at: t0, text: "MAYA: just me"), now: t0)
        XCTAssertNil(s.chats.last?.bridged)
    }

    func testBridgedOriginToleratesBadValues() throws {
        let json = #"{"network":"meshcore","senderName":"X","hops":"many","future":1}"#
        let o = try JSONDecoder().decode(BridgeOrigin.self, from: Data(json.utf8))
        XCTAssertEqual(o.senderName, "X")
        XCTAssertNil(o.hops)
        // A network this version doesn't know: the chat loads, without an origin.
        let chat = #"{"direction":{"received":{}},"origin":{"channel":{"_0":0}},"text":"x","at":1,"bridged":{"network":"lorawan","senderName":"X"}}"#
        XCTAssertNil(try JSONDecoder().decode(MeshCoreSession.Chat.self, from: Data(chat.utf8)).bridged)
    }

    // MARK: Airtime and Meshtastic sizes

    func testAirtimeMatchesTheDatasheet() {
        // SF7 / 125 kHz / 4/5, 8-symbol preamble, 10 bytes: 41.2 ms (Semtech calculator).
        XCTAssertEqual(LoRaAirtime.milliseconds(bytes: 10, spreadingFactor: 7, bandwidthKHz: 125, codingRate: 5, preamble: 8), 41)
        XCTAssertNil(LoRaAirtime.milliseconds(bytes: 10, spreadingFactor: 4, bandwidthKHz: 125, codingRate: 5))
        // Long, slow settings take much longer (low data rate optimisation kicks in).
        XCTAssertGreaterThan(LoRaAirtime.milliseconds(bytes: 40, spreadingFactor: 12, bandwidthKHz: 62.5, codingRate: 8) ?? 0, 2000)
    }

    func testMeshtasticPacketKnowsItsSize() throws {
        let toRadio = MeshCodec.textPacket("hello mesh", to: .broadcast, channel: 0, id: 42, replyID: 7)
        let packetBytes = try XCTUnwrap(try Proto.Message(toRadio).bytes(1))
        let p = try MeshCodec.decodePacket(packetBytes)
        XCTAssertEqual(p.raw, packetBytes)
        XCTAssertEqual(p.dataSize, MeshCodec.textDataSize("hello mesh", replyID: 7))
        XCTAssertEqual(p.airSize, 16 + MeshCodec.textDataSize("hello mesh", replyID: 7))
    }

    // MARK: Saved data

    func testChatWithEveryDetailRoundTrips() throws {
        var c = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .channel(1), text: "MAYA: hi", at: t0)
        c.radio = "b0010203"
        c.receivedAt = t0.addingTimeInterval(2)
        c.rssi = -97
        c.path = [Data([0x7A]), Data([0xC4])]
        c.flood = true
        c.size = 42
        c.airtimeMs = 61
        c.packetHash = "3f9a07c1e24d118b"
        c.heardBy = 3
        c.heardFrom = [Data([1]), Data([2]), Data([3])]
        c.roundTripMs = 1200
        c.bridged = BridgeOrigin(network: .meshtastic, senderID: "!a3f9c21e", senderName: "STAY", channel: "LongFast", hops: 3)
        c.raw = Data([0x15, 0x00, 1, 2, 3])
        let back = try JSONDecoder().decode(MeshCoreSession.Chat.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testOldChatLoadsWithNoDetails() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","direction":{"sent":{}},"origin":{"contact":{"_0":"AQIDBAUG"}},"text":"yo","at":700000000,"ack":5,"confirmed":true}"#
        let c = try JSONDecoder().decode(MeshCoreSession.Chat.self, from: Data(old.utf8))
        XCTAssertEqual(c.ack, 5)
        XCTAssertTrue(c.confirmed)
        XCTAssertNil(c.radio)
        XCTAssertNil(c.receivedAt)
        XCTAssertNil(c.rssi)
        XCTAssertNil(c.heardBy)
        XCTAssertNil(c.bridged)
        XCTAssertNil(c.raw)
    }

    func testBadDetailLosesOnlyThatDetail() throws {
        let json = #"{"direction":{"received":{}},"origin":{"channel":{"_0":0}},"text":"x","at":1,"rssi":"loud","bridged":[1],"size":12}"#
        let c = try JSONDecoder().decode(MeshCoreSession.Chat.self, from: Data(json.utf8))
        XCTAssertNil(c.rssi)
        XCTAssertNil(c.bridged)
        XCTAssertEqual(c.size, 12)
    }
}
