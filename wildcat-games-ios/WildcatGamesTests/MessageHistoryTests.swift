import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// Meshtastic chats per radio: channels keyed by name and key (not slot), one history
/// file per node, the old single file migrated, read marks carried over.
@MainActor
final class MessageHistoryTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: "hist-\(UUID())"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func channel(_ slot: Int, _ name: String, psk: Data, role: ChannelInfo.Role = .secondary) -> ChannelInfo {
        ChannelInfo(index: slot, name: name, role: role, settings: ChannelSettings(name: name, psk: psk).raw)
    }

    private func table(_ infos: [ChannelInfo]) -> [MeshtasticHistory.SavedChannel] {
        infos.map { .init(slot: $0.index, name: $0.name, key: ChannelKey(info: $0), primary: $0.role == .primary) }
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: MessageHistoryTests.self).url(forResource: "messages-two-radios", withExtension: "json"))
    }

    private func legacy() throws -> MessageMigration.Legacy {
        try MeshtasticHistory.decoder().decode(MessageMigration.Legacy.self, from: Data(contentsOf: try fixture()))
    }

    private func history(_ node: String) -> MeshtasticHistory? {
        SaveFile.load(MeshtasticHistory.self, from: dir.appendingPathComponent(MeshtasticHistory.fileName(node: node)), decoder: MeshtasticHistory.decoder())
    }

    /// The old node's cached channels: an unnamed primary in slot 0 and WGBRIDGE in slot 5.
    private func oldNodeCache() -> MeshtasticCache? {
        var s = MeshSession(configID: 1)
        _ = s.handle(.myInfo(NodeNum(0x716c_668c)))
        _ = s.handle(.nodeInfo(NodeInfo(num: NodeNum(0x716c_668c), userID: "!716c668c", longName: "Old Handheld", shortName: "OLD", snr: nil)))
        _ = s.handle(.channel(ChannelInfo(index: 0, name: "", role: .primary)))
        _ = s.handle(.channel(ChannelInfo(index: 5, name: "WGBRIDGE", role: .secondary)))
        return MeshtasticCache(session: s)
    }

    // MARK: Keys

    func testChannelIdentityIsNameAndKeyNotSlot() throws {
        let psk = Data(repeating: 7, count: 32), other = Data(repeating: 9, count: 32)
        XCTAssertEqual(ChannelKey(info: channel(5, "WGBRIDGE", psk: psk)), ChannelKey(info: channel(2, "WGBRIDGE", psk: psk)), "moved slot: same channel")
        XCTAssertNotEqual(ChannelKey(info: channel(5, "WGBRIDGE", psk: psk)), ChannelKey(info: channel(5, "WGBRIDGE", psk: other)), "same slot and name, different key: different channel")
        XCTAssertNotEqual(ChannelKey(info: channel(5, "Camp", psk: psk)), ChannelKey(info: channel(5, "Lake", psk: psk)), "same key, different name")
        let real = ChannelKey(info: channel(5, "WGBRIDGE", psk: psk))
        XCTAssertFalse(real.isFallback)
        XCTAssertEqual(real.name, "WGBRIDGE")
        XCTAssertNil(real.fallbackSlot)
        XCTAssertFalse(real.rawValue.contains(psk.map { String(format: "%02x", $0) }.joined()), "the key itself is never stored")

        let slotOnly = ChannelKey(info: ChannelInfo(index: 3, name: "WGHUNT", role: .secondary))
        XCTAssertTrue(slotOnly.isFallback, "no settings (practice): known by slot")
        XCTAssertEqual(slotOnly.fallbackSlot, 3)
        XCTAssertEqual(slotOnly.name, "WGHUNT")
        XCTAssertEqual(Conversation.channel(slot: 3, name: "WGHUNT"), .channel(slotOnly))

        // Both shapes on disk: the new string key, and the old slot number.
        let e = JSONEncoder(), d = JSONDecoder()
        XCTAssertEqual(try d.decode(Conversation.self, from: try e.encode(Conversation.channel(real))), .channel(real))
        XCTAssertEqual(try d.decode(Conversation.self, from: try e.encode(Conversation.direct("!0000abcd"))), .direct("!0000abcd"))
        XCTAssertEqual(try d.decode(Conversation.self, from: Data(#"{"channel":{"_0":5}}"#.utf8)), .channel(slot: 5))
        XCTAssertEqual(Conversation.channel(real).key, "ch:" + real.rawValue)
    }

    func testSlotKeysResolveBySlotOrByNameWhenMoved() {
        let psk = Data(repeating: 7, count: 32)
        let t = table([channel(0, "", psk: Data([1]), role: .primary), channel(2, "WGBRIDGE", psk: psk), channel(3, "Camp", psk: psk)])
        XCTAssertEqual(MessageStore.resolve(ChannelKey(name: "", slot: 2), in: t), t[1].key, "an unnamed slot key: whatever sits in that slot")
        XCTAssertEqual(MessageStore.resolve(ChannelKey(name: "WGBRIDGE", slot: 5), in: t), t[1].key, "named: follows the name to its new slot")
        XCTAssertEqual(MessageStore.resolve(ChannelKey(name: "Camp", slot: 3), in: t), t[2].key)
        XCTAssertNil(MessageStore.resolve(ChannelKey(name: "Lake", slot: 3), in: t), "a different channel in that slot now: never mixed")
        XCTAssertNil(MessageStore.resolve(ChannelKey(name: "", slot: 7), in: t))
        XCTAssertEqual(MessageStore.resolve(t[1].key, in: []), t[1].key, "a real key is itself")
    }

    func testHealingRewritesSlotKeysAndReadMarks() throws {
        let psk = Data(repeating: 7, count: 32)
        let live = table([channel(0, "", psk: Data([1]), role: .primary), channel(2, "WGBRIDGE", psk: psk)])
        var h = MeshtasticHistory(messages: [
            ChatMessage(packetID: 1, from: "!0000abcd", conversation: .channel(slot: 0), text: "a", time: Date(timeIntervalSince1970: 100), outgoing: false, status: .received),
            ChatMessage(packetID: 2, from: "!0000abcd", conversation: .channel(slot: 5, name: "WGBRIDGE"), text: "b", time: Date(timeIntervalSince1970: 200), outgoing: false, status: .received),
            ChatMessage(packetID: 3, from: "!0000abcd", conversation: .channel(slot: 6, name: "Gone"), text: "c", time: Date(timeIntervalSince1970: 300), outgoing: false, status: .received),
            ChatMessage(packetID: 4, from: "!0000abcd", conversation: .direct("!0000abcd"), text: "d", time: Date(timeIntervalSince1970: 400), outgoing: false, status: .received),
        ], lastRead: [Conversation.channel(slot: 5, name: "WGBRIDGE").key: Date(timeIntervalSince1970: 250),
                      Conversation.channel(live[1].key).key: Date(timeIntervalSince1970: 150),
                      Conversation.direct("!0000abcd").key: Date(timeIntervalSince1970: 1)])
        XCTAssertTrue(MessageStore.heal(&h, channels: live))
        XCTAssertEqual(h.messages[0].conversation, .channel(live[0].key))
        XCTAssertEqual(h.messages[1].conversation, .channel(live[1].key), "WGBRIDGE moved from slot 5 to 2: same chat")
        XCTAssertEqual(h.messages[2].conversation, .channel(slot: 6, name: "Gone"), "a channel the radio doesn't have stays a slot key, nothing lost")
        XCTAssertEqual(h.messages[3].conversation, .direct("!0000abcd"))
        XCTAssertEqual(h.lastRead[Conversation.channel(live[1].key).key], Date(timeIntervalSince1970: 250), "the later read mark wins")
        XCTAssertNil(h.lastRead[Conversation.channel(slot: 5, name: "WGBRIDGE").key])
        XCTAssertEqual(h.lastRead[Conversation.direct("!0000abcd").key], Date(timeIntervalSince1970: 1))
        XCTAssertFalse(MessageStore.heal(&h, channels: live), "nothing left to heal")
    }

    // MARK: Per radio

    func testEachRadioHasItsOwnHistoryFile() throws {
        // Two radios' saved chats, as earlier connections left them.
        let a = MeshtasticHistory(messages: [ChatMessage(packetID: 1, from: "!0000aaaa", conversation: .channel(slot: 0), text: "from A's mesh", time: Date(timeIntervalSince1970: 1000), outgoing: false, status: .received)],
                                  channels: [.init(slot: 0, name: "", key: ChannelKey(name: "", psk: Data([1])), primary: true)], node: "Radio A")
        let b = MeshtasticHistory(messages: [ChatMessage(packetID: 2, from: "!0000bbbb", conversation: .channel(slot: 0), text: "from B's mesh", time: Date(timeIntervalSince1970: 2000), outgoing: false, status: .received)], node: "Radio B")
        SaveFile.writeNow(a, to: dir.appendingPathComponent(MeshtasticHistory.fileName(node: "!0000000a")), encoder: MeshtasticHistory.encoder())
        SaveFile.writeNow(b, to: dir.appendingPathComponent(MeshtasticHistory.fileName(node: "!0000000b")), encoder: MeshtasticHistory.encoder())
        defaults.set("!0000000a", forKey: MeshtasticHistory.lastArchiveKey)

        // No radio connected: the last radio's chats, read-only, with the radio named.
        let offline = MessageStore(radio: Radio(), folder: dir, defaults: defaults)
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.historyNode, "!0000000a")
        XCTAssertEqual(offline.historyLabel, "Radio A")
        XCTAssertEqual(offline.messages.map(\.text), ["from A's mesh"])
        XCTAssertEqual(offline.channelEntries.map(\.slot), [0])
        XCTAssertEqual(offline.messages(in: .channel(slot: 0)).count, 1, "a slot key finds the saved channel in that slot")
        XCTAssertEqual(offline.otherHistories.map(\.node), ["!0000000b"])
        XCTAssertEqual(offline.otherHistories.first?.name, "Radio B")
        XCTAssertFalse(offline.send("x", in: .channel(slot: 0)), "nothing can be sent")
        offline.show(saved: "!0000000b")
        XCTAssertEqual(offline.historyLabel, "Radio B")
        XCTAssertEqual(offline.messages.map(\.text), ["from B's mesh"])
        XCTAssertEqual(offline.otherHistories.map(\.node), ["!0000000a"])

        // A radio connects (the practice node standing in): its own history, and what it
        // sends and hears is saved there and nowhere else.
        let radio = Radio()
        radio.startPractice()
        defer { radio.stopPractice() }
        let store = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
        XCTAssertTrue(store.isLive)
        XCTAssertEqual(store.historyNode, PracticeMesh.me.id)
        XCTAssertTrue(store.messages.isEmpty, "a new radio starts with no chats, not another radio's")
        XCTAssertEqual(Set(store.otherHistories.map(\.node)), ["!0000000a", "!0000000b"])
        XCTAssertTrue(store.send("hello from C", in: .channel(slot: 0)))
        store.handle(.packet(MeshPacket(from: PracticeMesh.fox, to: .broadcast, channel: 0, id: 77, portnum: .text, text: "heard on C")))
        XCTAssertEqual(store.messages.last?.radio, PracticeMesh.me.id)
        XCTAssertEqual(store.messages.first?.radio, PracticeMesh.me.id, "sent messages record the radio too")
        store.save()
        XCTAssertEqual(history(PracticeMesh.me.id)?.messages.map(\.text), ["hello from C", "heard on C"])
        XCTAssertEqual(history(PracticeMesh.me.id)?.channels.map(\.slot), [0, PracticeMesh.huntChannel], "the radio's channel table goes with it")
        XCTAssertEqual(history(PracticeMesh.me.id)?.node, "Practice Handheld")
        XCTAssertEqual(history("!0000000a")?.messages.map(\.text), ["from A's mesh"], "untouched")
        XCTAssertEqual(history("!0000000b")?.messages.map(\.text), ["from B's mesh"], "untouched")
        XCTAssertEqual(defaults.string(forKey: MeshtasticHistory.lastArchiveKey), PracticeMesh.me.id, "shown next time before a connection")
    }

    func testBridgedLineLandsInTheSendingRadiosHistory() throws {
        let radio = Radio()
        radio.startPractice()
        defer { radio.stopPractice() }
        let store = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
        // What MeshBridge does: a line from MeshCore posted on the bridged Meshtastic slot.
        let origin = BridgeOrigin(network: .meshcore, senderName: "MAYA", channel: "WGBRIDGE", hops: 1)
        XCTAssertTrue(store.send("[MC] MAYA: Howdy", in: .channel(slot: PracticeMesh.huntChannel), bridged: origin))
        let m = try XCTUnwrap(store.messages.last)
        XCTAssertEqual(m.radio, PracticeMesh.me.id)
        XCTAssertEqual(m.bridged, origin)
        XCTAssertEqual(m.conversation, .channel(slot: PracticeMesh.huntChannel, name: "WGHUNT"), "filed under the channel in that slot, not the bare slot")
        XCTAssertEqual(store.messages(in: .channel(slot: PracticeMesh.huntChannel)).count, 1)
        XCTAssertEqual(store.slot(of: m.conversation), PracticeMesh.huntChannel)
        XCTAssertFalse(store.send("x", in: .channel(slot: 7)), "a slot the radio doesn't have: not sent")
        store.save()
        XCTAssertEqual(history(PracticeMesh.me.id)?.messages.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("meshtastic-") }.count, 1, "no other radio's file")
    }

    // MARK: Migration

    func testMigrationSplitsTheOldFileByRadio() throws {
        try FileManager.default.copyItem(at: try fixture(), to: dir.appendingPathComponent("messages.json"))
        // One clock reading for both migrations below: "the same second" must not depend on
        // how fast the Mac runs this test (it took 45 s once, beside another build).
        let now = Date()
        let written = try XCTUnwrap(MessageMigration.run(folder: dir, cache: oldNodeCache(), defaults: defaults, now: now))
        XCTAssertEqual(Set(written), ["!716c668c", "!b213bcf6"])
        let old = try XCTUnwrap(history("!716c668c")), new = try XCTUnwrap(history("!b213bcf6"))
        // 38 messages: every one carries its radio (the owner's sends included) and goes to it.
        XCTAssertEqual(old.messages.count, 34)
        XCTAssertEqual(new.messages.count, 4)
        XCTAssertTrue(old.messages.allSatisfy { $0.radio == "!716c668c" })
        XCTAssertTrue(new.messages.allSatisfy { $0.radio == "!b213bcf6" })
        XCTAssertEqual(new.messages.filter(\.outgoing).count, 3, "the three lines sent through the new node")
        XCTAssertEqual(new.messages.filter { !$0.outgoing }.count, 1, "and the one it heard")
        // Slots become channel keys: the old node's from its cached channel list (named, healed
        // on connect), the new node's by slot alone.
        XCTAssertEqual(Set(old.messages.map(\.conversation)), [.channel(slot: 0), .channel(slot: 5, name: "WGBRIDGE")])
        XCTAssertEqual(Set(new.messages.map(\.conversation)), [.channel(slot: 0), .channel(slot: 5)])
        XCTAssertEqual(old.channels.map { ($0.slot, $0.name) }.map { "\($0.0):\($0.1)" }, ["0:", "5:WGBRIDGE"])
        XCTAssertEqual(old.node, "Old Handheld")
        XCTAssertTrue(new.channels.isEmpty, "nothing cached for the new node")
        // Read marks carried over, per history, under the new keys.
        XCTAssertEqual(old.lastRead[Conversation.channel(slot: 0).key], Date(timeIntervalSince1970: 1790962542.8446941))
        XCTAssertEqual(old.lastRead[Conversation.channel(slot: 5, name: "WGBRIDGE").key], Date(timeIntervalSince1970: 1790962734.508815))
        XCTAssertEqual(new.lastRead[Conversation.channel(slot: 5).key], Date(timeIntervalSince1970: 1790962734.508815))
        // The old file is kept, renamed.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(files.contains("messages.json"))
        XCTAssertEqual(files.filter { $0.hasPrefix("messages.json.migrated-") }.count, 1)
        XCTAssertEqual(defaults.string(forKey: MeshtasticHistory.lastArchiveKey), "!b213bcf6", "the radio with the newest message shows first")

        // Again: nothing to do. And the old file put back: merged, no duplicates.
        XCTAssertNil(MessageMigration.run(folder: dir, cache: oldNodeCache(), defaults: defaults))
        try FileManager.default.copyItem(at: try fixture(), to: dir.appendingPathComponent("messages.json"))
        XCTAssertNotNil(MessageMigration.run(folder: dir, cache: oldNodeCache(), defaults: defaults, now: now))
        XCTAssertEqual(history("!716c668c")?.messages.count, 34)
        XCTAssertEqual(history("!b213bcf6")?.messages.count, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("messages.json.migrated-") }.count, 1,
                       "a second run within the same second reuses the name")

        // What the app shows after migrating, before any radio connects: the new node's chats
        // with one unread (heard after the last read), then the old node's with none.
        let store = MessageStore(radio: Radio(), folder: dir, defaults: defaults)
        XCTAssertEqual(store.historyNode, "!b213bcf6")
        XCTAssertEqual(store.historyLabel, "!b213bcf6")
        XCTAssertEqual(store.messages.count, 4)
        XCTAssertEqual(store.unread(in: .channel(slot: 0)), 1)
        XCTAssertEqual(store.unread(in: .channel(slot: 5)), 0)
        XCTAssertEqual(store.totalUnread, 1)
        XCTAssertEqual(store.otherHistories.map(\.node), ["!716c668c"])
        store.show(saved: "!716c668c")
        XCTAssertEqual(store.historyLabel, "Old Handheld")
        XCTAssertEqual(store.messages.count, 34)
        XCTAssertEqual(store.totalUnread, 0, "everything there was read before the new node arrived")
        XCTAssertEqual(store.channelEntries.map(\.slot), [0, 5])
        XCTAssertEqual(store.channelEntries.map(\.name), ["", "WGBRIDGE"])
        XCTAssertEqual(store.messages(in: .channel(slot: 5)).count, 4, "WGBRIDGE by its slot: the old node's four lines, not the new node's three")
        XCTAssertEqual(store.messages(in: .channel(slot: 9, name: "WGBRIDGE")).count, 4, "or by its name")
    }

    func testMigrationInfersTheRadioOfSendsThatDidNotRecordIt() throws {
        // The same file, with the owner's sends not saying which radio they went through
        // (as older versions saved them): each joins the radio of the message nearest in time.
        var old = try legacy()
        for i in old.messages.indices where old.messages[i].outgoing { old.messages[i].radio = nil }
        let split = MessageMigration.split(old, cache: nil)
        XCTAssertEqual(split["!716c668c"]?.messages.count, 34)
        XCTAssertEqual(split["!b213bcf6"]?.messages.count, 4, "the three sends minutes before the new node's first message are its")
        XCTAssertTrue(split["!b213bcf6"]!.messages.allSatisfy { $0.radio == "!b213bcf6" }, "and record it from now on")

        func msg(_ id: UInt32, at t: TimeInterval, radio: String?, outgoing: Bool = true) -> ChatMessage {
            var m = ChatMessage(packetID: id, from: "!0000abcd", conversation: .channel(slot: 0), text: "\(id)", time: Date(timeIntervalSince1970: t), outgoing: outgoing, status: .sent)
            m.radio = radio
            return m
        }
        let two = MessageMigration.Legacy(messages: [msg(1, at: 0, radio: "!0000000a", outgoing: false), msg(2, at: 10, radio: nil),
                                                     msg(3, at: 990, radio: nil), msg(4, at: 1000, radio: "!0000000b", outgoing: false)], lastRead: [:])
        let s = MessageMigration.split(two, cache: nil)
        XCTAssertEqual(s["!0000000a"]?.messages.map(\.packetID), [1, 2])
        XCTAssertEqual(s["!0000000b"]?.messages.map(\.packetID), [3, 4])

        // No radio recorded anywhere: the last node the phone cached, else an "earlier radio".
        let none = MessageMigration.Legacy(messages: [msg(1, at: 0, radio: nil), msg(2, at: 5, radio: nil)], lastRead: ["ch0": Date(timeIntervalSince1970: 3)])
        XCTAssertEqual(MessageMigration.split(none, cache: oldNodeCache())["!716c668c"]?.messages.count, 2)
        let unknown = try XCTUnwrap(MessageMigration.split(none, cache: nil)[MeshtasticHistory.unknownNode])
        XCTAssertEqual(unknown.messages.count, 2)
        XCTAssertEqual(unknown.lastRead, [Conversation.channel(slot: 0).key: Date(timeIntervalSince1970: 3)])
    }

    func testEarlierRadiosChatsAreAdoptedByTheFirstRadioToConnect() throws {
        let old = #"{"messages":[{"packetID":7,"from":"!0000abcd","conversation":{"channel":{"_0":0}},"text":"old one","time":700000000,"outgoing":false,"status":{"received":{}}}]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("messages.json"))
        let radio = Radio()
        radio.startPractice()
        defer { radio.stopPractice() }
        let store = MessageStore(radio: radio, folder: dir, defaults: defaults, savesPractice: true)
        XCTAssertEqual(store.historyNode, PracticeMesh.me.id)
        XCTAssertEqual(store.messages.map(\.text), ["old one"], "chats from before radios were recorded belong to the radio that connects first")
        XCTAssertEqual(store.messages(in: .channel(slot: 0)).count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("meshtastic-") }
        XCTAssertEqual(files, [MeshtasticHistory.fileName(node: PracticeMesh.me.id)])
    }
}
