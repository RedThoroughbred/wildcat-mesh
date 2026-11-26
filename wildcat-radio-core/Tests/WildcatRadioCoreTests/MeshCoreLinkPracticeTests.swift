#if canImport(CoreBluetooth)
import XCTest
@testable import WildcatRadioCore

/// The link itself, driving the practice node with a test clock (no timers, no
/// Bluetooth): direct messages add heard-only contacts, retry, and report delivery.
@MainActor
final class MeshCoreLinkPracticeTests: XCTestCase {
    var now = Date(timeIntervalSince1970: 1_790_000_000)

    func link() -> MeshCoreLink {
        let l = MeshCoreLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!)
        l.clock = { [unowned self] in self.now }
        l.startDemo(timer: false)
        return l
    }

    func advance(_ l: MeshCoreLink, seconds: Int) {
        for _ in 0..<seconds {
            now = now.addingTimeInterval(1)
            l.tick()
        }
    }

    func testDirectMessageToAHeardOnlyContact() throws {
        let l = link()
        var deliveries: [MeshCoreSession.Chat.Delivery] = []
        let nova = try XCTUnwrap(l.session.heardOnly.first { $0.name == "NOVA Hiker" })
        l.addListener { if case .delivery(_, let d) = $0 { deliveries.append(d) } }
        let id = l.send(text: "hi NOVA", to: nova)
        XCTAssertTrue(l.session.isOnNode(nova), "added to the node before the send")
        XCTAssertEqual(l.session.chats.first { $0.id == id }?.delivery, .sent(attempt: 0, flood: true))
        advance(l, seconds: 5)
        XCTAssertEqual(deliveries, [.sent(attempt: 0, flood: true), .delivered])
        XCTAssertEqual(l.session.chats.first { $0.id == id }?.confirmed, true)
    }

    func testRetryThroughTheLink() throws {
        let l = link()
        var deliveries: [MeshCoreSession.Chat.Delivery] = []
        l.addListener { if case .delivery(_, let d) = $0 { deliveries.append(d) } }
        let dex = try XCTUnwrap(l.session.contacts.values.first { $0.name == "DEX Trail Node" })
        _ = l.send(text: "you there?", to: dex)
        advance(l, seconds: 20)
        XCTAssertEqual(deliveries.first, .sent(attempt: 0, flood: false))
        XCTAssertTrue(deliveries.contains(.sending(attempt: 1)))
        XCTAssertEqual(deliveries.last, .delivered)
    }

    func testSettingsAndCentreInPractice() throws {
        let l = MeshCoreLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!)
        l.clock = { [unowned self] in self.now }
        let centre = Coordinate(latitude: 37.8044, longitude: -122.4100)
        l.startDemo(center: centre, timer: false)
        XCTAssertNotNil(l.practiceFox)
        l.rename("Trail Kit")
        l.setTxPower(10)
        l.setRadio(frequency: 869.618, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8)
        XCTAssertEqual(l.session.me?.name, "Trail Kit")
        XCTAssertEqual(l.session.me?.txPower, 10)
        XCTAssertEqual(l.session.me?.spreadingFactor, 8)
        let i = try XCTUnwrap(l.addChannel(named: "WGHUNT"))
        XCTAssertEqual(l.session.channels[i]?.name, "WGHUNT", "set, then read back from the pretend node")
        l.deleteChannel(i)
        XCTAssertNil(l.session.channels[i])
    }
}
#endif
