import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// Play and the shared notices read both networks the same way.
@MainActor
final class BothNetworksTests: XCTestCase {
    private func status(_ n: MeshNetwork, up: Bool, name: String = "N0CALL Node", heard: Int? = nil) -> RadioStatus {
        RadioStatus(network: n, connected: up, name: up ? name : n.name, state: up ? "Connected · Bluetooth" : "Not connected",
                    heard: up ? heard : nil)
    }

    func testMastheadWithNoRadio() {
        let s = PlayView.status(status(.meshtastic, up: false), status(.meshcore, up: false))
        XCTAssertTrue(s.hasPrefix("No radio connected"))
    }

    func testMastheadReadsMeshCoreAlone() {
        let s = PlayView.status(status(.meshtastic, up: false), status(.meshcore, up: true, name: "MAYA Bag", heard: 5))
        XCTAssertEqual(s, "MeshCore · MAYA Bag · 5 heard")
    }

    func testMastheadWithBothRadios() {
        let mt = status(.meshtastic, up: true, heard: 6)
        let mc = status(.meshcore, up: true, heard: 7)
        XCTAssertEqual(PlayView.status(mt, mc), "2 radios connected · 13 heard")
        XCTAssertEqual(PlayView.status(mt, mc, practice: true), "Practice · 2 pretend radios · 13 heard")
    }

    private func rnode(up: Bool, name: String = "RNode 4FDD", packets: Int? = nil) -> RadioStatus {
        RadioStatus(network: nil, connected: up, name: up ? name : "RNode", state: up ? "Connected · Bluetooth" : "Not connected",
                    heard: up ? packets : nil)
    }

    func testMastheadCountsTheRNodeButNotItsPackets() {
        let mt = status(.meshtastic, up: true, heard: 6)
        let mc = status(.meshcore, up: true, heard: 7)
        XCTAssertEqual(PlayView.status(mt, mc, rnode(up: true, packets: 40)), "3 radios connected · 13 heard")
        XCTAssertEqual(PlayView.status(mt, mc, rnode(up: false)), "2 radios connected · 13 heard")
        XCTAssertEqual(PlayView.status(mt, mc, rnode(up: true), practice: true), "Practice · 2 pretend radios · 13 heard")
    }

    func testMastheadReadsTheRNodeAlone() {
        let s = PlayView.status(status(.meshtastic, up: false), status(.meshcore, up: false), rnode(up: true, packets: 40))
        XCTAssertEqual(s, "RNode · RNode 4FDD")
    }

    func testPillNameDropsALeadingEmoji() {
        XCTAssertEqual(status(.meshtastic, up: true, name: "🕸️Wildcat Nag").pillName, "Wildcat Nag")
        XCTAssertEqual(status(.meshcore, up: true, name: "MAYA Bag").pillName, "MAYA Bag")
        XCTAssertEqual(status(.meshcore, up: false).pillName, "MeshCore")
        XCTAssertEqual(rnode(up: false).pillName, "RNode")
        XCTAssertEqual(rnode(up: true).pillName, "RNode 4FDD")
    }

    func testPillSharesItsWidthShortestFirst() {
        // "RNode" needs 37; the other two split what's left of 164 (63.5 each) and truncate.
        let w = RadioPill.nameWidths(["Wildcat Nag", "Wildcat Bag", "RNode"], budget: 164)
        XCTAssertEqual(w[2], 37, accuracy: 0.01)
        XCTAssertEqual(w[0], 63.5, accuracy: 0.01)
        XCTAssertEqual(w[1], 63.5, accuracy: 0.01)
        XCTAssertEqual(w.reduce(0, +), 164, accuracy: 0.01)
        // Short names take only what they need.
        let short = RadioPill.nameWidths(["Nag", "Bag", "RNode"], budget: 164)
        XCTAssertEqual(short, [23, 23, 37])
        // Three long names: equal thirds.
        let long = RadioPill.nameWidths(["Wildcat Nag", "Wildcat Bag", "RNode 4FDD"], budget: 164)
        XCTAssertEqual(long.max()! - long.min()!, 0, accuracy: 0.01)
    }

    func testPillLabelsStayDistinctWhenTight() {
        // 7 points a character, like the old estimate: the test doesn't depend on the system font.
        let seven: (String) -> CGFloat = { CGFloat($0.count) * 7 + 2 }
        let three = [status(.meshtastic, up: true, name: "🕸️Wildcat Nag"), status(.meshcore, up: true, name: "Wildcat Bag"), rnode(up: true)]
        XCTAssertEqual(RadioPill.pillLabels(for: three, budget: 164, measure: seven), ["Nag", "Bag", "4FDD"])
        // Room to spare: nothing is shortened.
        XCTAssertEqual(RadioPill.pillLabels(for: three, budget: 400, measure: seven), ["Wildcat Nag", "Wildcat Bag", "RNode 4FDD"])
        // Radios that aren't connected take the short kind and leave the room to the one that is.
        let one = [status(.meshtastic, up: true, name: "Wildcat Nag"), status(.meshcore, up: false), rnode(up: false)]
        XCTAssertEqual(RadioPill.pillLabels(for: one, budget: 164, measure: seven), ["Wildcat Nag", "MC", "RNode"])
        // Names with nothing in common are left alone, however tight.
        let apart = [status(.meshtastic, up: true, name: "MAYA base station"), status(.meshcore, up: true, name: "N0CALL portable"), rnode(up: false)]
        XCTAssertEqual(RadioPill.pillLabels(for: apart, budget: 60, measure: seven), ["MAYA base station", "N0CALL portable", "RN"])
        // A shared word stays when one of the names is only that word.
        let practice = [status(.meshtastic, up: true, name: "Practice"), status(.meshcore, up: true, name: "Practice Node"), rnode(up: true)]
        XCTAssertEqual(RadioPill.pillLabels(for: practice, budget: 100, measure: seven), ["Practice", "Practice Node", "4FDD"])
        // A name is never emptied: two radios with the same one-word name keep it.
        let same = [status(.meshtastic, up: true, name: "Wildcat"), status(.meshcore, up: true, name: "Wildcat"), rnode(up: false)]
        XCTAssertEqual(RadioPill.pillLabels(for: same, budget: 20, measure: seven), ["Wildcat", "Wildcat", "RN"])
    }

    func testNeedsRadioTitleNamesTheNetworks() {
        XCTAssertEqual(NeedsRadioNotice.title([.meshtastic]), "Needs a Meshtastic node")
        XCTAssertEqual(NeedsRadioNotice.title([.meshcore]), "Needs a MeshCore node")
        XCTAssertEqual(NeedsRadioNotice.title(MeshNetwork.allCases), "Needs a Meshtastic or MeshCore node")
    }
}
