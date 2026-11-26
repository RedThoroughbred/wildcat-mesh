import XCTest
import WildcatRadioCore
@testable import WildcatGames

final class WordFilterTests: XCTestCase {
    func testWholeWordsAnyCase() {
        XCTAssertTrue(WordFilter.matches("what the fuck"))
        XCTAssertTrue(WordFilter.matches("FUCK!"))
        XCTAssertTrue(WordFilter.matches("oh, Shit."))
        XCTAssertTrue(WordFilter.matches("fucks given: none"), "plain plural")
        XCTAssertFalse(WordFilter.matches("classic assembly in Scunthorpe"), "never inside other words")
        XCTAssertFalse(WordFilter.matches("shitake"), "whole words only")
        XCTAssertFalse(WordFilter.matches("spices and dickens"))
        XCTAssertFalse(WordFilter.matches(""))
    }

    func testMaskKeepsTheRest() {
        XCTAssertEqual(WordFilter.masked("well shit, it's 5 km"), "well ••••, it's 5 km")
        XCTAssertEqual(WordFilter.masked("Fuck fuck"), "•••• ••••")
        XCTAssertEqual(WordFilter.masked("all clear"), "all clear")
        XCTAssertEqual(WordFilter.masked("[MC] MAYA: shit"), "[MC] MAYA: ••••")
    }

    func testAccentsFolded() {
        XCTAssertTrue(WordFilter.isListed("Shít"))
    }
}

final class BlocklistTests: XCTestCase {
    func testBridgedSenderParsing() {
        XCTAssertEqual(Blocklist.bridgedSender("[MT] STAY: hi")?.name, "STAY")
        XCTAssertEqual(Blocklist.bridgedSender("[MT] STAY: hi")?.network, .meshtastic)
        XCTAssertEqual(Blocklist.bridgedSender("[MC] MAYA RIVER: hey")?.name, "MAYA RIVER")
        XCTAssertEqual(Blocklist.bridgedSender("[MC] MAYA RIVER: hey")?.network, .meshcore)
        // On MeshCore the bridging node's name comes first.
        XCTAssertEqual(Blocklist.bridgedSender("Bag: [MT] STAY: hi")?.name, "STAY")
        XCTAssertEqual(Blocklist.bridgedSender("Bag: [MT] STAY: hi")?.network, .meshtastic)
        XCTAssertNil(Blocklist.bridgedSender("[MC] no sender here"), "no name: nothing to block")
        XCTAssertNil(Blocklist.bridgedSender("MAYA: plain channel line"))
        XCTAssertNil(Blocklist.bridgedSender("plain text"))
    }

    func testChannelSender() {
        XCTAssertEqual(Blocklist.channelSender("MAYA: hi there"), "MAYA")
        XCTAssertEqual(Blocklist.channelSender("Wildcat Bag: time: 5pm"), "Wildcat Bag")
        XCTAssertNil(Blocklist.channelSender("no colon"))
        XCTAssertNil(Blocklist.channelSender(String(repeating: "x", count: 40) + ": too long to be a name"))
    }

    func testMeshtasticByNodeAndBridgedName() {
        let list = Blocklist([BlockedSender(network: .meshtastic, key: "!1A2B3C4D", names: ["STAY", "Stay Home"])])
        XCTAssertTrue(list.blocksMeshtastic(from: "!1a2b3c4d", text: "hello"), "node ids compare in any case")
        XCTAssertFalse(list.blocksMeshtastic(from: "!00000001", text: "hello"))
        XCTAssertFalse(list.blocksMeshtastic(from: "!00000001", text: "STAY: hello"), "a name is not a Meshtastic sender")
        // Its lines bridged onto MeshCore by our own or anyone's bridge.
        XCTAssertTrue(list.blocksMeshCore(contact: nil, channelLine: false, text: "[MT] STAY: hi"))
        XCTAssertTrue(list.blocksMeshCore(contact: nil, channelLine: true, text: "Bag: [MT] stay: hi"))
        XCTAssertFalse(list.blocksMeshCore(contact: nil, channelLine: true, text: "Bag: [MC] STAY: hi"), "same name, other network")
        XCTAssertFalse(list.blocksMeshCore(contact: nil, channelLine: true, text: "STAY: hi"), "a MeshCore STAY is someone else")
    }

    func testMeshCoreByKeyAndName() {
        let key = "a1b2c3d4e5f6"
        let list = Blocklist([BlockedSender(network: .meshcore, key: key, names: ["Maya"])])
        XCTAssertTrue(list.blocksMeshCore(contact: key, channelLine: false, text: "hi"))
        XCTAssertTrue(list.blocksMeshCore(contact: key + "0011", channelLine: false, text: "hi"), "a full key starts with the prefix")
        XCTAssertFalse(list.blocksMeshCore(contact: "ffffffffffff", channelLine: false, text: "hi"))
        XCTAssertTrue(list.blocksMeshCore(contact: nil, channelLine: true, text: "MAYA: hi"), "channel lines by name")
        XCTAssertFalse(list.blocksMeshCore(contact: nil, channelLine: false, text: "MAYA: hi"), "a DM's text isn't a name")
        XCTAssertTrue(list.blocksMeshtastic(from: "!00000001", text: "[MC] Maya: hi"), "bridged onto Meshtastic")
        XCTAssertFalse(list.blocksMeshtastic(from: "!00000001", text: "[MT] Maya: hi"))
    }

    func testNameOnlyEntries() {
        var list = Blocklist()
        list.add(BlockedSender(network: .meshcore, names: ["  Troll  "]))
        XCTAssertEqual(list.entries.first?.name, "Troll", "names are trimmed")
        XCTAssertTrue(list.blocksMeshCore(contact: nil, channelLine: true, text: "troll: boo"))
        XCTAssertFalse(list.contains(meshcore: ""), "an empty key matches nothing")
        list.add(BlockedSender(network: .meshcore, names: []))
        XCTAssertEqual(list.entries.count, 1, "nothing to match: not added")
    }

    func testAddMergesAndRemove() {
        var list = Blocklist()
        list.add(BlockedSender(network: .meshtastic, key: "!1a2b3c4d", names: ["STAY"]))
        list.add(BlockedSender(network: .meshtastic, key: "!1a2b3c4d", names: ["Stay Home", "stay"]))
        XCTAssertEqual(list.entries.count, 1)
        XCTAssertEqual(list.entries.first?.names, ["STAY", "Stay Home"])
        list.remove(BlockedSender(network: .meshtastic, key: "!1A2B3C4D", names: []))
        XCTAssertTrue(list.isEmpty)
    }

    func testDecodingIsTolerant() throws {
        let json = #"{"entries":[{"network":"meshcore","key":"A1B2C3D4E5F6"},{"names":["STAY"]},{"network":"somethingNew","key":"x"},{}]}"#
        let list = try JSONDecoder().decode(Blocklist.self, from: Data(json.utf8))
        XCTAssertTrue(list.contains(meshcore: "a1b2c3d4e5f6"))
        XCTAssertTrue(list.contains(name: "stay", on: .meshtastic), "missing network falls back")
        XCTAssertEqual(list.entries.count, 3, "an entry with nothing to match is dropped")
        let empty = try JSONDecoder().decode(Blocklist.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
        let round = try JSONDecoder().decode(Blocklist.self, from: JSONEncoder().encode(list))
        XCTAssertEqual(round, list)
    }
}

@MainActor
final class SafetyStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "safety-\(UUID())")
    }

    func testPersistsAndFiltersByDefault() {
        let s = Safety(defaults: defaults)
        XCTAssertTrue(s.filterWords, "on by default")
        s.block(BlockedSender(network: .meshtastic, key: "!1a2b3c4d", names: ["STAY"]))
        s.filterWords = false
        let again = Safety(defaults: defaults)
        XCTAssertTrue(again.hides(meshtasticNode: "!1a2b3c4d"))
        XCTAssertFalse(again.filterWords)
        again.unblock(BlockedSender(network: .meshtastic, key: "!1a2b3c4d", names: []))
        XCTAssertFalse(Safety(defaults: defaults).hides(meshtasticNode: "!1a2b3c4d"))
    }

    func testHidesMessagesAndChats() {
        let s = Safety(defaults: defaults)
        s.block(BlockedSender(network: .meshtastic, key: "!1a2b3c4d", names: ["STAY"]))
        let theirs = ChatMessage(packetID: 1, from: "!1a2b3c4d", conversation: .channel(slot: 0), text: "hi", time: Date(), outgoing: false, status: .received)
        XCTAssertTrue(s.hides(theirs))
        var bridged = theirs
        bridged.from = "!00000001"
        XCTAssertFalse(s.hides(bridged))
        bridged.text = "[MC] STAY: hi"
        XCTAssertFalse(s.hides(bridged), "a MeshCore STAY is someone else")
        bridged.text = "[MT] STAY: hi"
        XCTAssertTrue(s.hides(bridged), "a tagged line names its sender")
        // Chat has no public initializer: build one the way the store loads them.
        let json = #"{"id":"\#(UUID().uuidString)","direction":{"sent":{}},"origin":{"channel":{"_0":1}},"text":"","at":0}"#
        var chat = try! JSONDecoder().decode(MeshCoreSession.Chat.self, from: Data(json.utf8))
        chat.text = "[MT] STAY: hi"
        XCTAssertTrue(s.hides(chat), "the line our bridge posted to MeshCore")
        chat.text = "[MT] MAYA: hi"
        XCTAssertFalse(s.hides(chat))
        XCTAssertEqual(s.shown("oh shit"), "oh ••••")
        s.filterWords = false
        XCTAssertEqual(s.shown("oh shit"), "oh shit")
    }

    func testReportEmail() throws {
        let f = Flagged(sender: BlockedSender(network: .meshcore, key: "a1b2c3d4e5f6", names: ["MAYA"]), network: "MeshCore",
                        place: "#Public", text: "a & b = c?", time: Date(timeIntervalSince1970: 0))
        let body = Report.body(f, app: "Wildcat 1.0 (2)")
        XCTAssertTrue(body.contains("Sender: MAYA (MeshCore a1b2c3d4e5f6)"))
        XCTAssertTrue(body.contains("Message: a & b = c?"))
        XCTAssertTrue(body.contains("Network: MeshCore, #Public"))
        let url = try XCTUnwrap(Report.mailto(f))
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:\(Support.email)?subject=Wildcat%20Mesh%20report&body="))
        XCTAssertTrue(url.absoluteString.contains("a%20%26%20b%20%3D%20c%3F"), "& and = in the text are encoded")
    }
}
