import Foundation

/// Which LoRa frequency slot a node transmits on, computed the way the
/// firmware does (RadioInterface.cpp applyModemConfig): the explicit
/// `channel_num` if set, else djb2(primary channel name) % number of slots,
/// where an empty primary name means the preset's display name ("LongFast").
///
/// Why it matters: renaming the primary channel moves a node to another
/// frequency unless the slot is pinned. A fox with a private primary must
/// pin the slot everyone else uses, or nobody hears it.
public enum FrequencySlot {
    struct Band { let start: Double; let end: Double; let spacing: Double; let wide: Bool }

    static let bands: [Region: Band] = [
        .us: Band(start: 902, end: 928, spacing: 0, wide: false),
        .eu433: Band(start: 433, end: 434, spacing: 0, wide: false),
        .eu868: Band(start: 869.4, end: 869.65, spacing: 0, wide: false),
        .cn: Band(start: 470, end: 510, spacing: 0, wide: false),
        .jp: Band(start: 920.5, end: 923.5, spacing: 0, wide: false),
        .anz: Band(start: 915, end: 928, spacing: 0, wide: false),
        .anz433: Band(start: 433.05, end: 434.79, spacing: 0, wide: false),
        .ru: Band(start: 868.7, end: 869.2, spacing: 0, wide: false),
        .kr: Band(start: 920, end: 923, spacing: 0, wide: false),
        .tw: Band(start: 920, end: 925, spacing: 0, wide: false),
        .india: Band(start: 865, end: 867, spacing: 0, wide: false),
        .nz865: Band(start: 864, end: 868, spacing: 0, wide: false),
        .th: Band(start: 920, end: 925, spacing: 0, wide: false),
        .ua433: Band(start: 433, end: 434.7, spacing: 0, wide: false),
        .ua868: Band(start: 868, end: 868.6, spacing: 0, wide: false),
        .my433: Band(start: 433, end: 435, spacing: 0, wide: false),
        .my919: Band(start: 919, end: 924, spacing: 0, wide: false),
        .sg923: Band(start: 917, end: 925, spacing: 0, wide: false),
        .ph433: Band(start: 433, end: 434.7, spacing: 0, wide: false),
        .ph868: Band(start: 868, end: 869.4, spacing: 0, wide: false),
        .ph915: Band(start: 915, end: 918, spacing: 0, wide: false),
        .kz433: Band(start: 433.075, end: 434.775, spacing: 0, wide: false),
        .kz863: Band(start: 863, end: 868, spacing: 0, wide: false),
        .np865: Band(start: 865, end: 868, spacing: 0, wide: false),
        .br902: Band(start: 902, end: 907.5, spacing: 0, wide: false),
        .lora24: Band(start: 2400, end: 2483.5, spacing: 0, wide: true),
    ]

    public static func djb2(_ s: String) -> UInt32 {
        var h: UInt32 = 5381
        for b in s.utf8 { h = (h &<< 5) &+ h &+ UInt32(b) }
        return h
    }

    static func bandwidthKHz(_ p: ModemPreset, wide: Bool) -> Double {
        switch p {
        case .shortTurbo, .longTurbo: return wide ? 1625 : 500
        case .longModerate, .longSlow: return wide ? 406.25 : 125
        default: return wide ? 812.5 : 250
        }
    }

    /// The firmware's display name, used when the primary channel has no name.
    public static func presetName(_ p: ModemPreset, usePreset: Bool) -> String {
        guard usePreset else { return "Custom" }
        switch p {
        case .shortTurbo: return "ShortTurbo"
        case .shortSlow: return "ShortSlow"
        case .shortFast: return "ShortFast"
        case .mediumSlow: return "MediumSlow"
        case .mediumFast: return "MediumFast"
        case .longSlow: return "LongSlow"
        case .longFast: return "LongFast"
        case .longTurbo: return "LongTurbo"
        case .longModerate: return "LongMod"
        case .veryLongSlow: return "Invalid"
        }
    }

    /// The 1-based slot the node uses; nil for an unset or unknown region.
    public static func effective(lora: LoRaSettings, primaryName: String) -> Int? {
        let pinned = Int((try? Proto.Message(lora.raw))?.uint32(11) ?? 0)
        if pinned > 0 { return pinned }
        guard let band = bands[lora.region] else { return nil }
        let bw = bandwidthKHz(lora.preset, wide: band.wide)
        let count = Int(floor((band.end - band.start) / (band.spacing + bw / 1000)))
        guard count > 0 else { return nil }
        let name = primaryName.isEmpty ? presetName(lora.preset, usePreset: lora.usePreset) : primaryName
        return Int(djb2(name) % UInt32(count)) + 1
    }

    /// `lora` with its slot pinned (LoRaConfig.channel_num, field 11).
    public static func pinned(_ lora: LoRaSettings, slot: Int) -> Data {
        Proto.patch(lora.patched, [11: Proto.varint(slot)])
    }
}
