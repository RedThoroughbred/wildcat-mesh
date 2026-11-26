import XCTest
@testable import WildcatGames

/// The licences screen must never ship with a component missing its text.
final class OpenSourceLicensesTests: XCTestCase {
    func testEveryComponentShipsItsLicenceText() {
        let all = OpenSourceComponent.all()
        XCTAssertGreaterThanOrEqual(all.count, 13)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids are unique")
        for c in all {
            let text = c.text() ?? ""
            XCTAssertGreaterThan(text.count, 500, "\(c.id) has no licence text in the bundle")
            XCTAssertFalse(c.version.isEmpty)
        }
    }

    func testTheReticulumLicenceCarriesItsConditions() {
        let all = OpenSourceComponent.all()
        for id in ["rns", "lxmf"] {
            guard let c = all.first(where: { $0.id == id }), let text = c.text() else { return XCTFail("\(id) missing") }
            XCTAssertEqual(c.license, "Reticulum License")
            XCTAssertTrue(text.hasPrefix("Reticulum License"))
            XCTAssertTrue(text.contains("purposefully do harm to human beings"))
            XCTAssertTrue(text.contains("training"))
            XCTAssertTrue(text.contains("Mark Qvist"))
        }
    }
}
