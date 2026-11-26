import XCTest
@testable import WildcatRadioCore

/// Contacts the node holds vs ones only heard (CMD_ADD_UPDATE_CONTACT), and room
/// server posts keeping their author. Layouts per companion firmware v1.17.1
/// (examples/companion_radio/MyMesh.cpp).
final class MeshCoreContactsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func les32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    func contact(_ b: UInt8, _ name: String, kind: MeshCore.Contact.Kind = .chat, path: [UInt8]? = nil) -> MeshCore.Contact {
        var c = MeshCore.Contact(publicKey: Data([b] + (1..<32).map { UInt8($0) }), kind: kind, flags: 0, pathLength: path?.count,
                                 name: name, lastAdvert: t0, position: nil, lastModified: nil)
        c.path = Data(path ?? [])
        return c
    }

    // MARK: CMD_ADD_UPDATE_CONTACT

    func testAddContactLayout() {
        var c = contact(0x51, "MAYA Field Unit", path: [0x1C, 0x2A])
        c.position = Coordinate(latitude: 37.5, longitude: -122.25)
        c.flags = 1
        let d = Array(MeshCore.Command.addContact(c).data)
        XCTAssertEqual(d.count, 144, "code + 143-byte record, no lastmod (the node stamps its own)")
        XCTAssertEqual(d[0], 9)
        XCTAssertEqual(Array(d[1...32]), Array(c.publicKey))
        XCTAssertEqual(d[33], 1, "type: chat")
        XCTAssertEqual(d[34], 1, "flags")
        XCTAssertEqual(d[35], 2, "out_path_len: 2 one-byte hashes")
        XCTAssertEqual(Array(d[36...37]), [0x1C, 0x2A])
        XCTAssertEqual(Array(d[38...99]), Array(repeating: 0, count: 62), "out_path padded to 64")
        XCTAssertEqual(Array(d[100..<115]), Array("MAYA Field Unit".utf8))
        XCTAssertEqual(Array(d[115...131]), Array(repeating: 0, count: 17), "name null-padded to 32")
        XCTAssertEqual(Array(d[132...135]), le32(1_790_000_000))
        XCTAssertEqual(Array(d[136...139]), les32(37_500_000))
        XCTAssertEqual(Array(d[140...143]), les32(-122_250_000))
        XCTAssertEqual(MeshCore.Command.addContact(c).label, "add contact")
    }

    func testAddContactUnknownRouteIsFF() {
        let d = Array(MeshCore.Command.addContact(contact(0x95, "NOVA Hiker")).data)
        XCTAssertEqual(d[35], 0xFF, "no known route: flood")
        XCTAssertEqual(Array(d[136...143]), Array(repeating: 0, count: 8), "no position")
    }

    /// The record is the one RESP_CONTACT carries: decoding it back gives the same contact.
    func testAddContactRoundTripsThroughTheContactDecoder() throws {
        var two = contact(0x66, "DEX Trail Node", kind: .repeater)
        two.pathLength = 2
        two.path = Data([0x1C, 0x01, 0x2A, 0x02])
        two.pathHashSize = 2
        two.position = Coordinate(latitude: 37.77, longitude: -122.48)
        for c in [contact(0x51, "MAYA Field Unit", path: [0x1C]), contact(0x95, "NOVA Hiker"), two] {
            let record = MeshCore.Command.addContact(c).data.dropFirst()
            guard case .contact(let back) = try MeshCore.decode(Data([3]) + record) else { return XCTFail() }
            XCTAssertEqual(back, c, c.name)
        }
    }

    func testLongNameIsCutAndStillTerminated() {
        let d = Array(MeshCore.Command.addContact(contact(1, String(repeating: "N", count: 40))).data)
        XCTAssertEqual(d.count, 144)
        XCTAssertEqual(d[131], 0, "31 characters at most, then a null")

        // Nonsense path lengths never trap.
        var odd = contact(2, "x", path: [1])
        odd.pathLength = -3
        XCTAssertEqual(MeshCore.Command.addContact(odd).data[35], 0)
        odd.pathLength = 500
        odd.pathHashSize = 9
        XCTAssertEqual(MeshCore.Command.addContact(odd).data.count, 144)
    }

    // MARK: Held by the node, or only heard

    func testNewAdvertIsHeardOnlyAndDMAddsItFirst() throws {
        var s = MeshCoreSession()
        let nova = contact(0x95, "NOVA Hiker")
        XCTAssertEqual(s.handle(.newAdvert(nova)).events, [.contactsChanged])
        XCTAssertNotNil(s.contacts[nova.publicKey], "listed in the app")
        XCTAssertFalse(s.isOnNode(nova), "but the node didn't add it (auto-add off)")
        XCTAssertEqual(s.heardOnly, [nova])

        let (id, commands) = s.sendDirect("hi", to: nova, at: t0, now: t0)
        XCTAssertEqual(commands, [.addContact(nova), .sendText(to: nova.prefix, text: "hi", at: t0, attempt: 0)])
        XCTAssertEqual(s.chats.last?.id, id)
        XCTAssertEqual(s.chats.last?.delivery, .sending(attempt: 0))

        XCTAssertEqual(s.answered(.addContact(nova), with: .ok, now: t0).events, [.contactsChanged])
        XCTAssertTrue(s.isOnNode(nova))
        XCTAssertEqual(s.sendDirect("again", to: nova, at: t0, now: t0).commands.count, 1, "held now: just the send")
    }

    func testListedContactsAreOnTheNode() {
        var s = MeshCoreSession()
        let maya = contact(0x51, "MAYA Field Unit", path: [0x1C])
        _ = s.handle(.contactsStart(count: 1))
        _ = s.handle(.contact(maya))
        _ = s.handle(.endOfContacts)
        XCTAssertTrue(s.isOnNode(maya))
        XCTAssertEqual(s.sendDirect("hi", to: maya, at: t0).commands, [.sendText(to: maya.prefix, text: "hi", at: t0, attempt: 0)])

        // A fresh listing without her: she's remembered, but no longer held.
        _ = s.handle(.contactsStart(count: 0))
        _ = s.handle(.endOfContacts)
        XCTAssertFalse(s.isOnNode(maya))
        XCTAssertNotNil(s.contacts[maya.publicKey])
        // Her advert as a known contact (0x80) means the node has her again.
        _ = s.handle(.advert(publicKey: maya.publicKey))
        XCTAssertTrue(s.isOnNode(maya))
        // Overwritten to make room (0x8F).
        XCTAssertEqual(try MeshCore.decode(Data([0x8F]) + maya.publicKey), .contactDeleted(publicKey: maya.publicKey))
        _ = s.handle(.contactDeleted(publicKey: maya.publicKey))
        XCTAssertFalse(s.isOnNode(maya))
    }

    func testRestoredContactsAreNotOnTheNode() {
        var s = MeshCoreSession()
        let sage = contact(0x73, "SAGE Base Camp")
        s.restore(chats: [], contacts: [sage])
        XCTAssertFalse(s.isOnNode(sage))
        XCTAssertEqual(s.sendDirect("hi", to: sage, at: t0).commands.first, .addContact(sage))
    }

    func testForgetAndRemoveLeaveTheNode() {
        var s = MeshCoreSession()
        let maya = contact(0x51, "MAYA Field Unit")
        _ = s.handle(.contact(maya))
        _ = s.answered(.removeContact(publicKey: maya.publicKey), with: .ok)
        XCTAssertFalse(s.isOnNode(maya))
        _ = s.handle(.contact(maya))
        s.forget(contact: maya.publicKey)
        XCTAssertFalse(s.isOnNode(maya))
        XCTAssertNil(s.contacts[maya.publicKey])
    }

    func testAddContactCompletesOnOK() {
        let c = MeshCore.Command.addContact(contact(1, "x"))
        XCTAssertTrue(MeshCoreSession.completes(c, with: .ok))
        XCTAssertTrue(MeshCoreSession.completes(c, with: .error(code: 3)))
        XCTAssertFalse(MeshCoreSession.completes(c, with: .battery(millivolts: 1, usedKB: nil, totalKB: nil)))
    }

    // MARK: Room server posts

    /// A room post as the companion queues it (MyMesh::queueMessage): V3 header, the
    /// room's 6-byte prefix, path_len, txt_type 2 (signed), timestamp, the author's
    /// 4-byte key prefix, then the text.
    func roomPost(room: [UInt8], author: [UInt8], text: String) -> Data {
        Data([0x10, 20, 0, 0] + room + [1, 2] + le32(1_790_000_000) + author + Array(text.utf8))
    }

    func testRoomPostKeepsItsAuthor() throws {
        let room = contact(0x3E, "Park Room Server", kind: .room)
        let frame = roomPost(room: Array(room.prefix), author: [0x51, 1, 2, 3], text: "Meet at noon")
        guard case .message(let m) = try MeshCore.decode(frame) else { return XCTFail() }
        XCTAssertEqual(m.origin, .contact(room.prefix), "the room, as before")
        XCTAssertEqual(m.textType, 2)
        XCTAssertEqual(m.author, Data([0x51, 1, 2, 3]))
        XCTAssertEqual(m.text, "Meet at noon")
        XCTAssertEqual(m.snr, 5)

        // Plain direct messages have no author.
        guard case .message(let dm) = try MeshCore.decode(Data([7] + Array(room.prefix) + [0, 0] + le32(1) + Array("hi".utf8))) else { return XCTFail() }
        XCTAssertNil(dm.author)
        XCTAssertEqual(dm.text, "hi")

        // Too short for the prefix: an error, never a trap.
        XCTAssertThrowsError(try MeshCore.decode(Data([7] + Array(room.prefix) + [0, 2] + le32(1) + [0x51, 1])))
    }

    func testSessionNamesTheAuthor() throws {
        var s = MeshCoreSession()
        let room = contact(0x3E, "Park Room Server", kind: .room)
        let maya = contact(0x51, "MAYA Field Unit")
        _ = s.handle(.contact(room))
        _ = s.handle(.contact(maya))
        _ = s.handle(.selfInfo(MeshCore.SelfInfo(advertType: 1, txPower: 22, maxTxPower: 22, publicKey: Data([0xB0] + Array(repeating: 7, count: 31)),
                                                 position: nil, frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5,
                                                 name: "Practice Node")))

        func post(_ author: [UInt8]) throws -> MeshCoreSession.Chat {
            guard case .message(let m) = try MeshCore.decode(roomPost(room: Array(room.prefix), author: author, text: "x")),
                  case .message(let chat)? = s.handle(.message(m)).events.first else { throw MeshCore.DecodeError() }
            return chat
        }
        let fromMaya = try post(Array(maya.publicKey.prefix(4)))
        XCTAssertEqual(fromMaya.author, maya.publicKey.prefix(4))
        XCTAssertEqual(s.author(of: fromMaya), "MAYA Field Unit")
        XCTAssertEqual(s.label(fromMaya.origin), "Park Room Server", "the conversation is still the room")
        XCTAssertEqual(s.author(of: try post([0xB0, 7, 7, 7])), "Practice Node", "our own post, synced back")
        XCTAssertEqual(s.author(of: try post([0xDE, 0xAD, 0x00, 0x01])), "dead0001", "a member we don't know")

        var plain = fromMaya
        plain.author = nil
        XCTAssertNil(s.author(of: plain))
    }

    func testAuthorAndDeliveryAreSavedAndOldSavesStillLoad() throws {
        var c = MeshCoreSession.Chat(id: UUID(), direction: .received, origin: .contact(Data(repeating: 0x3E, count: 6)), text: "x", at: t0)
        c.author = Data([1, 2, 3, 4])
        c.delivery = .failed(.noConfirmation(attempts: 3))
        let back = try JSONDecoder().decode(MeshCoreSession.Chat.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)

        let old = #"{"direction":{"sent":{}},"origin":{"channel":{"_0":0}},"text":"hi","at":0}"#
        let loaded = try JSONDecoder().decode(MeshCoreSession.Chat.self, from: Data(old.utf8))
        XCTAssertNil(loaded.author)
        XCTAssertNil(loaded.delivery)
    }
}
