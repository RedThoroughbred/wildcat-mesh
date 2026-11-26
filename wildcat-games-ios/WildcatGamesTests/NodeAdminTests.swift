import XCTest
import WildcatRadioCore
@testable import WildcatGames

@MainActor
final class NodeAdminTests: XCTestCase {
    private let hunt = ChannelSettings(name: "WGHUNT", psk: Data(repeating: 7, count: 32))
    private let chat = ChannelSettings(name: "Chat", psk: Data([1]))

    private func slots(_ changes: [NodeAdmin.Change]) -> [(Int, String?, ChannelInfo.Role)] {
        changes.compactMap {
            if case .channel(let i, let s, let r) = $0 { return (i, s.map { ChannelSettings(raw: $0).name }, r) }
            return nil
        }
    }

    func testAddFillsFreeSlots() {
        let current: [Int: ChannelInfo] = [0: .init(index: 0, name: "", role: .primary), 1: .init(index: 1, name: "X", role: .secondary)]
        let out = slots(NodeAdmin.changes(for: ChannelLink(channels: [hunt, chat], lora: nil, add: true), current: current,
                                          applyRadio: false, lora: nil))
        XCTAssertEqual(out.map(\.0), [2, 3])
        XCTAssertEqual(out.map(\.1), ["WGHUNT", "Chat"])
        XCTAssertEqual(out.map(\.2), [.secondary, .secondary])
    }

    func testReplaceSetsPrimaryAndClearsTheRest() {
        let current: [Int: ChannelInfo] = [0: .init(index: 0, name: "", role: .primary), 4: .init(index: 4, name: "Old", role: .secondary)]
        let out = slots(NodeAdmin.changes(for: ChannelLink(channels: [chat, hunt], lora: nil, add: false), current: current,
                                          applyRadio: false, lora: nil))
        XCTAssertEqual(out.map(\.0), [0, 1, 4])
        XCTAssertEqual(out.map(\.2), [.primary, .secondary, .disabled])
    }

    func testRadioSettingsOnlyWhenAsked() {
        let theirs = Proto.patch(Data(), [1: Proto.varint(true), 2: Proto.varint(ModemPreset.mediumFast.rawValue), 7: Proto.varint(Region.us.rawValue)])
        let mine = LoRaSettings(raw: Proto.patch(Data(), [8: Proto.varint(3), 13: Proto.varint(true)]))
        let link = ChannelLink(channels: [chat], lora: theirs, add: true)
        XCTAssertFalse(NodeAdmin.changes(for: link, current: [:], applyRadio: false, lora: mine).contains { if case .config = $0 { return true }; return false })
        guard case .config(.lora, let raw)? = NodeAdmin.changes(for: link, current: [:], applyRadio: true, lora: mine).last else { return XCTFail() }
        let l = LoRaSettings(raw: raw)
        XCTAssertEqual(l.region, .us)
        XCTAssertEqual(l.preset, .mediumFast)
        XCTAssertEqual(l.hopLimit, 3, "our other settings stay")
        XCTAssertTrue((try? Proto.Message(raw))?.bool(13) ?? false, "and fields we don't show stay too")
    }

    func testReplacingLinkAlwaysTakesThePinnedSlot() {
        let theirs = Proto.patch(Data(), [1: Proto.varint(true), 7: Proto.varint(Region.us.rawValue), 11: Proto.varint(20)])
        let mine = LoRaSettings(raw: Proto.patch(Data(), [1: Proto.varint(true), 7: Proto.varint(Region.us.rawValue), 8: Proto.varint(3)]))
        let fox = ChannelLink(channels: [hunt], lora: theirs, add: false)
        guard case .config(.lora, let raw)? = NodeAdmin.changes(for: fox, current: [:], applyRadio: false, lora: mine).last else {
            return XCTFail("the pin must be applied even without 'also use its radio settings'")
        }
        XCTAssertEqual(FrequencySlot.effective(lora: LoRaSettings(raw: raw), primaryName: "WGHUNT"), 20)
        XCTAssertEqual(LoRaSettings(raw: raw).hopLimit, 3)
    }

    func testMakeOnlyChannelKeepsTheFrequency() {
        let current: [Int: ChannelInfo] = [0: .init(index: 0, name: "", role: .primary),
                                           1: .init(index: 1, name: "X", role: .secondary),
                                           2: .init(index: 2, name: "WGHUNT", role: .secondary, settings: hunt.raw)]
        let lora = LoRaSettings(raw: Proto.patch(Data(), [1: Proto.varint(true), 7: Proto.varint(Region.us.rawValue)]))
        let changes = NodeAdmin.makeOnlyChannel(hunt.raw, current: current, lora: lora)
        let s = slots(changes)
        XCTAssertEqual(s.map(\.0), [0, 1, 2])
        XCTAssertEqual(s.map(\.2), [.primary, .disabled, .disabled])
        XCTAssertEqual(s.first?.1, "WGHUNT")
        guard case .config(.lora, let raw)? = changes.last else { return XCTFail() }
        XCTAssertEqual(FrequencySlot.effective(lora: LoRaSettings(raw: raw), primaryName: "WGHUNT"), 20, "still LongFast's slot")
        XCTAssertTrue(changes.last!.restarts)
        XCTAssertFalse(changes.first!.restarts)
    }
}
