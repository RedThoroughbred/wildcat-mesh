import XCTest
@testable import WildcatRadioCore

final class FrequencySlotTests: XCTestCase {
    private func lora(region: Region = .us, preset: ModemPreset = .longFast, pinned: Int = 0) -> LoRaSettings {
        LoRaSettings(raw: Proto.patch(Data(), [1: Proto.varint(true), 2: Proto.varint(preset.rawValue),
                                               7: Proto.varint(region.rawValue), 11: Proto.varint(pinned)]))
    }

    func testDefaultUSLongFastIsSlot20() {
        XCTAssertEqual(FrequencySlot.effective(lora: lora(), primaryName: ""), 20)
        XCTAssertEqual(FrequencySlot.effective(lora: lora(), primaryName: "LongFast"), 20)
    }

    func testRenamedPrimaryMovesFrequencyUnlessPinned() {
        XCTAssertEqual(FrequencySlot.effective(lora: lora(), primaryName: "WGHUNT"), 43)
        XCTAssertEqual(FrequencySlot.effective(lora: lora(pinned: 20), primaryName: "WGHUNT"), 20)
        let pinned = LoRaSettings(raw: FrequencySlot.pinned(lora(), slot: 20))
        XCTAssertEqual(FrequencySlot.effective(lora: pinned, primaryName: "WGHUNT"), 20)
    }

    func testOtherPresetsAndRegions() {
        XCTAssertEqual(FrequencySlot.effective(lora: lora(preset: .mediumFast), primaryName: ""), 45)
        XCTAssertNil(FrequencySlot.effective(lora: lora(region: .unset), primaryName: ""))
        XCTAssertEqual(FrequencySlot.effective(lora: lora(region: .eu868), primaryName: ""), 1, "EU 868 has one 250 kHz slot")
    }
}
