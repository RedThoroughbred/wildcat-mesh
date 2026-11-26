import XCTest
@testable import WildcatRadioCore

/// Frames laid out byte for byte as MeshCore companion firmware v1.17.1 writes them
/// (examples/companion_radio/MyMesh.cpp), plus the protocol doc's hex examples.
final class MeshCoreTests: XCTestCase {
    func hex(_ s: String) -> Data {
        let c = s.replacingOccurrences(of: " ", with: "")
        return Data(stride(from: 0, to: c.count, by: 2).map {
            UInt8(c[c.index(c.startIndex, offsetBy: $0)..<c.index(c.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }
    func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func les32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    // MARK: Commands (doc examples)

    func testCommandsMatchTheDocExamples() {
        XCTAssertEqual(MeshCore.Command.appStart(name: "mccli").data, hex("01 00 00 00 00 00 00 00 6d 63 63 6c 69"))
        XCTAssertEqual(MeshCore.Command.deviceQuery.data, hex("16 03"))
        XCTAssertEqual(MeshCore.Command.getChannel(index: 1).data, hex("1F 01"))
        XCTAssertEqual(MeshCore.Command.sendChannelText(channel: 1, text: "Hello", at: Date(timeIntervalSince1970: 1_234_567_890)).data,
                       hex("03 00 01 D2 02 96 49 48 65 6C 6C 6F"))
    }

    func testSetChannelIsFiftyBytes() {
        let secret = Data(1...16)
        let d = MeshCore.Command.setChannel(index: 1, name: "WGHUNT", secret: secret).data
        XCTAssertEqual(d.count, 50)
        XCTAssertEqual(Array(d.prefix(8)), [0x20, 1] + Array("WGHUNT".utf8))
        XCTAssertEqual(d[8], 0, "name null-padded to 32")
        XCTAssertEqual(d.suffix(16), secret)
    }

    func testSendTextAndAdvertCommands() {
        let key = Data(0xA0...0xA7)
        let d = MeshCore.Command.sendText(to: key, text: "hi", at: Date(timeIntervalSince1970: 1_790_000_000)).data
        XCTAssertEqual(Array(d), [2, 0, 0] + le32(UInt32(1_790_000_000)) + [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5] + Array("hi".utf8))
        XCTAssertEqual(MeshCore.Command.sendSelfAdvert(flood: true).data, Data([7, 1]))
        XCTAssertEqual(MeshCore.Command.setDeviceTime(Date(timeIntervalSince1970: 1_790_000_000)).data, Data([6] + le32(UInt32(1_790_000_000))))
    }

    // MARK: Frames

    func testSelfInfo() throws {
        var f: [UInt8] = [5, 1, 22, 30] + Array(repeating: 0xAB, count: 32)
        f += les32(Int32(39_103_100)) + les32(Int32(-84_512_000))
        f += [0, 0, 0, 0]
        f += le32(UInt32(910_525)) + le32(UInt32(62_500)) + [7, 5]
        f += Array("Bag".utf8)
        guard case .selfInfo(let s) = try MeshCore.decode(Data(f)) else { return XCTFail() }
        XCTAssertEqual(s.name, "Bag")
        XCTAssertEqual(s.txPower, 22)
        XCTAssertEqual(s.frequency, 910.525, accuracy: 1e-9)
        XCTAssertEqual(s.bandwidth, 62.5, accuracy: 1e-9)
        XCTAssertEqual([s.spreadingFactor, s.codingRate], [7, 5])
        XCTAssertEqual(s.position?.latitude ?? 0, 39.1031, accuracy: 1e-9)
        XCTAssertEqual(s.publicKey.count, 32)
    }

    func contactFrame(code: UInt8, name: String, path: UInt8) -> [UInt8] {
        var f: [UInt8] = [code] + Array(0x10...0x2F) + [2, 0, path] + Array(repeating: 0, count: 64)
        var n = Array(name.utf8); n += Array(repeating: 0, count: 32 - n.count)
        f += n + le32(UInt32(1_790_000_000)) + les32(Int32(38_900_000)) + les32(Int32(-84_600_000)) + le32(UInt32(1_790_000_100))
        return f
    }

    func testContactAndNewAdvert() throws {
        XCTAssertEqual(contactFrame(code: 3, name: "x", path: 0).count, 148)
        guard case .contact(let c) = try MeshCore.decode(Data(contactFrame(code: 3, name: "Hilltop RPT", path: 2))) else { return XCTFail() }
        XCTAssertEqual(c.name, "Hilltop RPT")
        XCTAssertEqual(c.kind, .repeater)
        XCTAssertEqual(c.pathLength, 2)
        XCTAssertEqual(c.prefix, Data(0x10...0x15))
        XCTAssertEqual(c.shortID, "10111213")
        XCTAssertEqual(c.position?.longitude ?? 0, -84.6, accuracy: 1e-9)
        guard case .newAdvert(let n) = try MeshCore.decode(Data(contactFrame(code: 0x8A, name: "Fox", path: 0xFF))) else { return XCTFail() }
        XCTAssertNil(n.pathLength, "0xFF = no known path")
    }

    func testMessagesV3WithSNR() throws {
        let ts = le32(UInt32(1_790_000_000))
        let ch: [UInt8] = [0x11, UInt8(bitPattern: Int8(-26)), 0, 0, 1, 3, 0] + ts + Array("WG JOIN FOX7".utf8)
        guard case .message(let m) = try MeshCore.decode(Data(ch)) else { return XCTFail() }
        XCTAssertEqual(m.origin, .channel(1))
        XCTAssertEqual(m.snr, -6.5)
        XCTAssertEqual(m.hops, 3)
        XCTAssertEqual(m.text, "WG JOIN FOX7")
        let dm: [UInt8] = [0x10, 24, 0, 0, 1, 2, 3, 4, 5, 6, 0xFF, 0] + ts + Array("hi".utf8)
        guard case .message(let d) = try MeshCore.decode(Data(dm)) else { return XCTFail() }
        XCTAssertEqual(d.origin, .contact(Data([1, 2, 3, 4, 5, 6])))
        XCTAssertNil(d.hops, "direct route")
        XCTAssertEqual(d.snr, 6)
        let signed: [UInt8] = [0x10, 0, 0, 0, 1, 2, 3, 4, 5, 6, 1, 2] + ts + [9, 9, 9, 9] + Array("ok".utf8)
        guard case .message(let s) = try MeshCore.decode(Data(signed)) else { return XCTFail() }
        XCTAssertEqual(s.text, "ok", "signed messages skip the 4-byte sender prefix")
    }

    func testMessageHopsDecodePathLenByte() throws {
        let ts = le32(UInt32(1_790_000_000))
        for (pathLen, hops) in [(UInt8(0x45), 5 as Int?), (0x03, 3), (0xFF, nil), (0x80, 0)] {
            let ch: [UInt8] = [0x11, 0, 0, 0, 1, pathLen, 0] + ts + Array("hi".utf8)
            guard case .message(let m) = try MeshCore.decode(Data(ch)) else { return XCTFail() }
            XCTAssertEqual(m.hops, hops, "channel, path_len \(pathLen)")
            let dm: [UInt8] = [0x10, 0, 0, 0, 1, 2, 3, 4, 5, 6, pathLen, 0] + ts + Array("hi".utf8)
            guard case .message(let d) = try MeshCore.decode(Data(dm)) else { return XCTFail() }
            XCTAssertEqual(d.hops, hops, "direct, path_len \(pathLen)")
        }
    }

    func testSmallFrames() throws {
        XCTAssertEqual(try MeshCore.decode(Data([0])), .ok)
        XCTAssertEqual(try MeshCore.decode(Data([1, 2])), .error(code: 2))
        XCTAssertEqual(try MeshCore.decode(Data([0x83])), .messagesWaiting)
        XCTAssertEqual(try MeshCore.decode(Data([10])), .noMoreMessages)
        XCTAssertEqual(try MeshCore.decode(Data([6, 1] + le32(UInt32(0xDEADBEEF)) + le32(UInt32(5000)))),
                       .sent(flood: true, ack: 0xDEADBEEF, timeout: 5000))
        XCTAssertEqual(try MeshCore.decode(Data([0x82] + le32(UInt32(0xDEADBEEF)) + le32(UInt32(840)))),
                       .sendConfirmed(ack: 0xDEADBEEF, roundTripMs: 840))
        XCTAssertEqual(try MeshCore.decode(Data([12, 0x10, 0x0E] + le32(UInt32(12)) + le32(UInt32(1000)))),
                       .battery(millivolts: 3600, usedKB: 12, totalKB: 1000))
        XCTAssertEqual(try MeshCore.decode(Data([0x88, UInt8(bitPattern: Int8(-10)), UInt8(bitPattern: Int8(-97)), 0x11, 0x22])),
                       .rxLog(snr: -2.5, rssi: -97, raw: Data([0x11, 0x22])))
        XCTAssertThrowsError(try MeshCore.decode(Data([6, 1])))
    }

    func testDeviceInfoAndChannelInfo() throws {
        var f: [UInt8] = [13, 9, 175, 8, 0x40, 0xE2, 0x01, 0x00]
        func field(_ s: String, _ n: Int) -> [UInt8] { var b = Array(s.utf8); b += Array(repeating: 0, count: n - b.count); return b }
        f += field("14-Aug-2026", 12) + field("Seeed Xiao nRF52", 40) + field("v1.17.1", 20) + [0, 0]
        guard case .deviceInfo(let i) = try MeshCore.decode(Data(f)) else { return XCTFail() }
        XCTAssertEqual(i.maxContacts, 350)
        XCTAssertEqual(i.maxChannels, 8)
        XCTAssertEqual(i.version, "v1.17.1")
        XCTAssertEqual(i.manufacturer, "Seeed Xiao nRF52")
        let c: [UInt8] = [18, 0] + field("Public", 32) + Array(repeating: 0x8B, count: 16)
        XCTAssertEqual(try MeshCore.decode(Data(c)), .channelInfo(index: 0, name: "Public", secret: Data(repeating: 0x8B, count: 16)))
    }

    func testSettingsCommands() {
        XCTAssertEqual(MeshCore.Command.setName("Wildcat Bag").data, Data([8] + Array("Wildcat Bag".utf8)))
        XCTAssertEqual(MeshCore.Command.setRadio(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5).data,
                       Data([11] + le32(UInt32(910_525)) + le32(UInt32(62_500)) + [7, 5]))
        XCTAssertEqual(MeshCore.Command.setTxPower(-9).data, Data([12, 0xF7]))
        XCTAssertEqual(MeshCore.Command.setPosition(Coordinate(latitude: 39.1031, longitude: -84.512)).data,
                       Data([14] + les32(Int32(39_103_100)) + les32(Int32(-84_512_000))))
        XCTAssertEqual(MeshCore.Command.setOtherParams(manualAddContacts: 0, telemetryModes: 0, advertLocationPolicy: 1, multiAcks: 0).data,
                       Data([38, 0, 0, 1, 0]))
        XCTAssertEqual(MeshCore.Command.reboot.data, Data([19] + Array("reboot".utf8)))
        XCTAssertEqual(MeshCore.Command.removeContact(publicKey: Data(0..<32)).data.count, 33)
    }

    func testSelfInfoCarriesOtherParams() throws {
        var f: [UInt8] = [5, 1, 22, 30] + Array(repeating: 0xAB, count: 32) + les32(Int32(0)) + les32(Int32(0))
        f += [2, 1, 0x05, 1] + le32(UInt32(910_525)) + le32(UInt32(62_500)) + [7, 5] + Array("Bag".utf8)
        guard case .selfInfo(let s) = try MeshCore.decode(Data(f)) else { return XCTFail() }
        XCTAssertEqual([s.multiAcks, s.advertLocationPolicy, s.telemetryModes, s.manualAddContacts], [2, 1, 5, 1])
        XCTAssertNil(s.position)
    }

    func testAnswersOnlyCompleteTheirOwnQuestion() {
        typealias S = MeshCoreSession
        XCTAssertFalse(S.completes(.setDeviceTime(Date()), with: .battery(millivolts: 3700, usedKB: nil, totalKB: nil)),
                       "another app's battery answer must not complete our set-time")
        XCTAssertTrue(S.completes(.setDeviceTime(Date()), with: .ok))
        XCTAssertFalse(S.completes(.getContacts, with: .contact(MeshCore.Contact(publicKey: Data(count: 32), kind: .chat, flags: 0,
                                                                                  pathLength: 0, name: "x", lastAdvert: nil,
                                                                                  position: nil, lastModified: nil))))
        XCTAssertTrue(S.completes(.getContacts, with: .endOfContacts))
        XCTAssertFalse(S.completes(.getChannel(index: 2), with: .channelInfo(index: 1, name: "a", secret: Data(count: 16))))
        XCTAssertTrue(S.completes(.getChannel(index: 1), with: .channelInfo(index: 1, name: "a", secret: Data(count: 16))))
        XCTAssertFalse(S.completes(.getBatteryAndStorage, with: .other(code: 0x16, Data())))
        XCTAssertTrue(S.completes(.sendChannelText(channel: 1, text: "x", at: Date()), with: .error(code: 2)))
        XCTAssertFalse(S.completes(.syncNextMessage, with: .messagesWaiting))
    }

    func testRestoreKeepsHistoryWithoutDuplicates() throws {
        var s = MeshCoreSession()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        _ = s.handle(.message(MeshCore.Message(origin: .channel(0), hops: 1, textType: 0, sent: at, snr: 5, text: "N0CALL: Howdy")))
        let old = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .channel(0), text: "older", at: at.addingTimeInterval(-60))
        let dup = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .channel(0), text: "N0CALL: Howdy", at: at)
        let gone = MeshCore.Contact(publicKey: Data(repeating: 7, count: 32), kind: .repeater, flags: 0, pathLength: nil,
                                    name: "Old RPT", lastAdvert: nil, position: nil, lastModified: nil)
        s.restore(chats: [old, dup], contacts: [gone])
        XCTAssertEqual(s.chats.map(\.text), ["older", "N0CALL: Howdy"])
        XCTAssertEqual(s.contacts[gone.publicKey]?.name, "Old RPT")
        let data = try JSONEncoder().encode(s.chats)
        XCTAssertEqual(try JSONDecoder().decode([MeshCoreSession.Chat].self, from: data).count, 2)
    }

    func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func les16(_ v: Int16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    func testRepeaterLoginStatusAndCommands() throws {
        let key = Data(0x20..<0x40)
        XCTAssertEqual(MeshCore.Command.login(publicKey: key, password: "hunter2").data, Data([26] + Array(key) + Array("hunter2".utf8)))
        XCTAssertEqual(MeshCore.Command.statusRequest(publicKey: key).data, Data([27] + Array(key)))
        XCTAssertEqual(MeshCore.Command.remoteCommand(to: key, command: "get radio", at: Date(timeIntervalSince1970: 1_790_000_000)).data,
                       Data([2, 1, 0] + le32(UInt32(1_790_000_000)) + Array(key.prefix(6)) + Array("get radio".utf8)),
                       "CLI commands are direct messages with text type 1")
        XCTAssertEqual(MeshCore.Command.login(publicKey: key, password: String(repeating: "x", count: 20)).data.count, 1 + 32 + 15)

        XCTAssertEqual(try MeshCore.decode(Data([0x85, 1] + Array(key.prefix(6)) + [0, 0, 0, 0, 1, 2])),
                       .loginResult(prefix: key.prefix(6), ok: true, isAdmin: true))
        XCTAssertEqual(try MeshCore.decode(Data([0x86, 0] + Array(key.prefix(6)))),
                       .loginResult(prefix: key.prefix(6), ok: false, isAdmin: false))

        var st: [UInt8] = [0x87, 0] + Array(key.prefix(6))
        st += le16(4110) + le16(0) + les16(-112) + les16(-87)
        st += le32(UInt32(5000)) + le32(UInt32(1200)) + le32(UInt32(300)) + le32(UInt32(86_400))
        st += le32(UInt32(900)) + le32(UInt32(300)) + le32(UInt32(4000)) + le32(UInt32(1000))
        st += le16(2) + les16(-26) + le16(7) + le16(40) + le32(UInt32(250)) + le32(UInt32(3))
        guard case .status(let p, let s) = try MeshCore.decode(Data(st)) else { return XCTFail() }
        XCTAssertEqual(p, key.prefix(6))
        XCTAssertEqual(s.batteryMillivolts, 4110)
        XCTAssertEqual(s.noiseFloor, -112)
        XCTAssertEqual(s.lastRSSI, -87)
        XCTAssertEqual(s.uptimeSeconds, 86_400)
        XCTAssertEqual(s.lastSNR, -6.5)
        XCTAssertEqual(s.floodDuplicates, 40)
        XCTAssertEqual(s.receiveErrors, 3)
    }

    func testOldHistoryWithoutTextTypeStillLoads() throws {
        let json = #"[{"id":"5B3C8E0F-3C7B-4E57-9D8A-1B2C3D4E5F60","direction":{"received":{}},"origin":{"channel":{"_0":0}},"text":"hi","at":800000000,"confirmed":false}]"#
        let chats = try JSONDecoder().decode([MeshCoreSession.Chat].self, from: Data(json.utf8))
        XCTAssertNil(chats.first?.textType)
    }

    func testTraceRouteAndResult() throws {
        var rpt = MeshCore.Contact(publicKey: Data([0x1C] + Array(repeating: 0, count: 31)), kind: .repeater, flags: 0, pathLength: 2,
                                   name: "Wildcat Solar", lastAdvert: nil, position: nil, lastModified: nil)
        rpt.path = Data([0xAA, 0x24])
        XCTAssertEqual(MeshCore.tracePath(to: rpt), [0xAA, 0x24, 0x1C, 0x24, 0xAA], "out, the repeater, and back")
        rpt.path = Data()
        XCTAssertEqual(MeshCore.tracePath(to: rpt), [0x1C], "in range: just the repeater")
        var chat = rpt; chat.kind = .chat
        XCTAssertNil(MeshCore.tracePath(to: chat), "companions don't relay")
        XCTAssertEqual(MeshCore.Command.trace(tag: 7, hashes: [0x1C]).data, Data([36] + le32(UInt32(7)) + le32(UInt32(0)) + [0, 0x1C]))

        let push: [UInt8] = [0x89, 0, 1, 0] + le32(UInt32(7)) + le32(UInt32(0)) + [0x1C] + [UInt8(bitPattern: 38)] + [UInt8(bitPattern: -10)]
        XCTAssertEqual(try MeshCore.decode(Data(push)),
                       .trace(MeshCore.TraceResult(tag: 7, hops: [.init(hash: Data([0x1C]), snr: 9.5)], finalSNR: -2.5)))
    }

    func testContactPathIsKept() throws {
        var f: [UInt8] = [3] + Array(0x10...0x2F) + [2, 0, 2] + [0xAA, 0x24] + Array(repeating: 0, count: 62)
        var n = Array("R".utf8); n += Array(repeating: 0, count: 32 - n.count)
        f += n + le32(UInt32(1)) + les32(Int32(0)) + les32(Int32(0)) + le32(UInt32(0))
        guard case .contact(let c) = try MeshCore.decode(Data(f)) else { return XCTFail() }
        XCTAssertEqual(c.pathLength, 2)
        XCTAssertEqual(c.path, Data([0xAA, 0x24]))
    }

    func testContactsSavedBeforePathsStillLoad() throws {
        let json = #"{"publicKey":"AAEC","kind":2,"flags":0,"pathLength":1,"name":"Old","lastAdvert":800000000}"#
        let c = try JSONDecoder().decode(MeshCore.Contact.self, from: Data(json.utf8))
        XCTAssertEqual(c.name, "Old")
        XCTAssertEqual(c.path, Data())
        XCTAssertEqual(c.pathHashSize, 1)
    }

    func testChannelDatagrams() throws {
        // the doc's example: flood, DATA_TYPE_DEV, payload A1 B2 C3, channel 1
        XCTAssertEqual(MeshCore.Command.sendChannelData(channel: 1, dataType: 0xFFFF, payload: Data([0xA1, 0xB2, 0xC3])).data,
                       hex("3E 01 FF FF FF A1 B2 C3"))
        let f: [UInt8] = [0x1B, UInt8(bitPattern: Int8(22)), 0, 0, 1, 2, 0x57, 0xFF, 3, 0x57, 0x47, 0x47]
        XCTAssertEqual(try MeshCore.decode(Data(f)),
                       .channelData(channel: 1, dataType: 0xFF57, payload: Data("WGG".utf8), snr: 5.5, hops: 2))
        XCTAssertTrue(MeshCoreSession.completes(.syncNextMessage,
                                                with: .channelData(channel: 1, dataType: 1, payload: Data(), snr: 0, hops: nil)))
        var s = MeshCoreSession()
        let (events, follow) = s.handle(.channelData(channel: 1, dataType: 0xFF57, payload: Data([1]), snr: 0, hops: nil))
        XCTAssertEqual(events, [.datagram(channel: 1, dataType: 0xFF57, payload: Data([1]), snr: 0)])
        XCTAssertEqual(follow, [.syncNextMessage], "keep pulling queued datagrams")
    }

    func testPracticeNode() {
        let s = MeshCoreSession.demo()
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(s.me?.name, "Practice Node")
        XCTAssertEqual(s.contacts.count, 9, "7 on the node, the hidden fox, and NOVA (heard only)")
        XCTAssertEqual(s.channels.count, 2)
        XCTAssertEqual(s.conversationChats.count, 12)
        XCTAssertEqual(s.contacts.values.filter { $0.position != nil }.count, 4)
        XCTAssertNotNil(MeshCore.tracePath(to: s.contacts.values.first { $0.name == "Riverside RPT" }!))
    }
}
