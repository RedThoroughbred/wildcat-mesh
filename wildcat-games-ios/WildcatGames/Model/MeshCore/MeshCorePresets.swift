import Foundation
import WildcatRadioCore

/// One of MeshCore's community radio presets: every node on a mesh must share
/// these four numbers, or they can't hear each other.
struct MeshCorePreset: Identifiable, Equatable, Sendable {
    /// The preset's title, exactly as MeshCore publishes it (also its id).
    let title: String
    let frequency: Double
    let bandwidth: Double
    let spreadingFactor: Int
    let codingRate: Int
    /// Route-hash size (bytes) the mesh uses, when the preset names one. Wildcat can't set it yet.
    var pathHashSize: Int? = nil
    /// Still listed so nodes on it are recognised, but MeshCore steers new meshes elsewhere.
    var deprecated = false
    /// ISO 3166 region codes where this preset is used.
    var regions: Set<String> = []

    var id: String { title }

    /// "910.525 MHz · BW 62.5 · SF7 · CR5"
    var summary: String {
        String(format: "%.3f MHz · BW %@ · SF%d · CR%d", frequency, OwnedNode.trim(bandwidth), spreadingFactor, codingRate)
    }

    func matches(frequency f: Double, bandwidth b: Double, spreadingFactor sf: Int, codingRate cr: Int) -> Bool {
        abs(f - frequency) < 0.0005 && abs(b - bandwidth) < 0.05 && sf == spreadingFactor && cr == codingRate
    }
}

enum MeshCorePresets {
    // Source: MeshCore's preset list, served by the MeshCore App API and documented in
    // the MeshCore repo:
    //   https://github.com/meshcore-dev/MeshCore/blob/main/docs/radio_presets.md
    //     ("The presets can be fetched from https://api.meshcore.nz/api/v1/config")
    //   https://api.meshcore.nz/api/v1/config  (config.suggested_radio_settings.entries, fetched 2026-10-02)
    // Every row below is copied from that response (title, frequency, bandwidth, SF, CR,
    // network_settings.path_hash_size). The source gives no TX power, so setup leaves
    // the node's power alone. Known-good on the owner's own node: USA 910.525 / 62.5 / SF7 / CR5.
    // Don't add a preset that isn't in that list: a wrong one takes the node off the air.
    // Rows are in the API's order, except USA first: it shares Canada's settings, and a
    // lookup by settings alone should name it ("USA / Canada").
    static let all: [MeshCorePreset] = [
        .init(title: "USA", frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5, regions: ["US"]),
        .init(title: "Australia",frequency: 915.800, bandwidth: 250, spreadingFactor: 10, codingRate: 5, regions: ["AU"]),
        .init(title: "Australia (Narrow)", frequency: 916.575, bandwidth: 62.5, spreadingFactor: 7, codingRate: 7, regions: ["AU"]),
        .init(title: "Australia (Mid)", frequency: 915.075, bandwidth: 125, spreadingFactor: 9, codingRate: 5, regions: ["AU"]),
        .init(title: "Australia: SA, WA", frequency: 923.125, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8, regions: ["AU"]),
        .init(title: "Australia: QLD", frequency: 923.125, bandwidth: 62.5, spreadingFactor: 8, codingRate: 5, regions: ["AU"]),
        .init(title: "Brazil", frequency: 923.125, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8, regions: ["BR"]),
        .init(title: "Canada", frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 3, regions: ["CA"]),
        .init(title: "Costa Rica", frequency: 910.525, bandwidth: 125, spreadingFactor: 11, codingRate: 5, regions: ["CR"]),
        .init(title: "EU/UK (Narrow)", frequency: 869.618, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8, regions: europe),
        .init(title: "EU/UK (Deprecated)", frequency: 869.525, bandwidth: 250, spreadingFactor: 11, codingRate: 5,
              deprecated: true, regions: europe),
        .init(title: "Czech Republic (Narrow)", frequency: 869.432, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5,
              pathHashSize: 2, regions: ["CZ"]),
        .init(title: "EU 433MHz (Long Range)", frequency: 433.650, bandwidth: 250, spreadingFactor: 11, codingRate: 5, regions: europe),
        .init(title: "EU 433MHz (Narrow)", frequency: 433.650, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8, regions: europe),
        .init(title: "Hungary", frequency: 869.618, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 2, regions: ["HU"]),
        .init(title: "Netherlands", frequency: 869.618, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5, regions: ["NL"]),
        .init(title: "Netherlands (Limburg)", frequency: 869.618, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8,
              pathHashSize: 2, regions: ["NL"]),
        .init(title: "New Zealand (Narrow)", frequency: 917.375, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5,
              pathHashSize: 2, regions: ["NZ"]),
        .init(title: "New Zealand (Gisborne)", frequency: 917.375, bandwidth: 250, spreadingFactor: 11, codingRate: 5,
              pathHashSize: 1, regions: ["NZ"]),
        .init(title: "Portugal 433", frequency: 433.375, bandwidth: 62.5, spreadingFactor: 9, codingRate: 6, regions: ["PT"]),
        .init(title: "Portugal 868", frequency: 869.618, bandwidth: 62.5, spreadingFactor: 7, codingRate: 6, regions: ["PT"]),
        .init(title: "Slovakia", frequency: 869.618, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 2, regions: ["SK"]),
        .init(title: "Switzerland", frequency: 869.618, bandwidth: 62.5, spreadingFactor: 8, codingRate: 8, regions: ["CH"]),
        .init(title: "USA - Southern California", frequency: 927.875, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5,
              pathHashSize: 3, regions: ["US"]),
        .init(title: "Vietnam (Narrow)", frequency: 920.250, bandwidth: 62.5, spreadingFactor: 8, codingRate: 5, regions: ["VN"]),
        .init(title: "Vietnam (Deprecated)", frequency: 920.250, bandwidth: 250, spreadingFactor: 11, codingRate: 5,
              deprecated: true, regions: ["VN"]),
    ]

    /// Where the "EU/UK" presets apply (the EU 868 MHz band countries plus the UK and EFTA).
    static let europe: Set<String> = [
        "GB", "IE", "DE", "FR", "BE", "LU", "IT", "ES", "AT", "SE", "NO", "DK", "FI", "PL", "IS", "LI",
        "EE", "LV", "LT", "SI", "HR", "RO", "BG", "GR", "CY", "MT",
    ]

    /// The preset to pick first for a phone in this region; nil where there's no clear one
    /// (Australia has several state and range presets) or MeshCore lists none.
    static let defaults: [String: String] = {
        var d: [String: String] = [
            "US": "USA", "CA": "Canada", "CR": "Costa Rica", "BR": "Brazil", "CZ": "Czech Republic (Narrow)",
            "HU": "Hungary", "NL": "Netherlands", "NZ": "New Zealand (Narrow)", "PT": "Portugal 868",
            "SK": "Slovakia", "CH": "Switzerland", "VN": "Vietnam (Narrow)",
        ]
        for code in europe { d[code] = "EU/UK (Narrow)" }
        return d
    }()

    static func named(_ title: String) -> MeshCorePreset? { all.first { $0.title == title } }

    /// The first preset these radio settings match (several share settings: USA and Canada do).
    static func match(frequency: Double, bandwidth: Double, spreadingFactor: Int, codingRate: Int) -> MeshCorePreset? {
        all.first { $0.matches(frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate) }
    }

    /// The node's preset; where several share its settings, the one used in `regionCode`.
    static func match(_ me: MeshCore.SelfInfo, regionCode: String? = nil) -> MeshCorePreset? {
        let found = all.filter {
            $0.matches(frequency: me.frequency, bandwidth: me.bandwidth, spreadingFactor: me.spreadingFactor, codingRate: me.codingRate)
        }
        let code = regionCode?.uppercased()
        return found.first { code != nil && $0.regions.contains(code!) } ?? found.first
    }

    /// A short name for these settings: "USA / Canada", "Hungary +2", or nil when no preset matches.
    static func label(frequency: Double, bandwidth: Double, spreadingFactor: Int, codingRate: Int) -> String? {
        let titles = all.filter { $0.matches(frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate) }
            .map(\.title)
        switch titles.count {
        case 0: return nil
        case 1, 2: return titles.joined(separator: " / ")
        default: return "\(titles[0]) +\(titles.count - 1)"
        }
    }

    /// The phone's best guess, from its region setting (like Meshtastic's region guess).
    static func guess(regionCode: String?) -> MeshCorePreset? {
        guard let code = regionCode?.uppercased(), let title = defaults[code] else { return nil }
        return named(title)
    }

    /// Presets used in this region (not deprecated), the default first.
    static func suggested(regionCode: String?) -> [MeshCorePreset] {
        guard let code = regionCode?.uppercased() else { return [] }
        let local = all.filter { !$0.deprecated && $0.regions.contains(code) }
        let first = guess(regionCode: code)
        return local.sorted { a, b in (a == first ? 0 : 1) < (b == first ? 0 : 1) }
    }
}

// MARK: - Does this node need setting up?

/// Whether a MeshCore companion still looks fresh from the flasher: its name is
/// the firmware's default, or its radio isn't on any MeshCore preset.
enum MeshCoreSetupCheck {
    enum Reason: Equatable, Sendable {
        /// Still called what the firmware named it (its key's first 8 hex digits, or NONAME).
        case defaultName
        /// Frequency, bandwidth, SF or CR match no MeshCore preset.
        case offPreset
    }

    /// The firmware's names for an unconfigured node: empty, "NONAME", or the
    /// first four bytes of its public key in hex (examples/companion_radio/MyMesh.cpp).
    static func isDefaultName(_ name: String, publicKey: Data) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n.uppercased() == "NONAME" { return true }
        let hex = publicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
        return publicKey.count >= 4 && n.lowercased() == hex
    }

    static func reasons(name: String, publicKey: Data, frequency: Double, bandwidth: Double,
                        spreadingFactor: Int, codingRate: Int) -> [Reason] {
        var out: [Reason] = []
        if isDefaultName(name, publicKey: publicKey) { out.append(.defaultName) }
        if MeshCorePresets.match(frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate) == nil {
            out.append(.offPreset)
        }
        return out
    }

    /// Empty when there's no node, or it looks set up.
    static func reasons(_ me: MeshCore.SelfInfo?) -> [Reason] {
        guard let me else { return [] }
        return reasons(name: me.name, publicKey: me.publicKey, frequency: me.frequency, bandwidth: me.bandwidth,
                       spreadingFactor: me.spreadingFactor, codingRate: me.codingRate)
    }

    /// For a "Set up" status key: true when the node should go through setup.
    static func needsSetup(_ me: MeshCore.SelfInfo?) -> Bool { !reasons(me).isEmpty }

    /// The status key's short word: "Name!", "Radio!", "Setup!" (both), or "Node" when all is well.
    static func keyWord(_ me: MeshCore.SelfInfo?) -> String {
        let r = reasons(me)
        if r.count > 1 { return "Setup!" }
        switch r.first {
        case .defaultName: return "Name!"
        case .offPreset: return "Radio!"
        case nil: return "Node"
        }
    }

    /// One plain line on why setup is suggested.
    static func line(_ me: MeshCore.SelfInfo?) -> String? {
        let r = reasons(me)
        if r.isEmpty { return nil }
        if r.count > 1 { return "Default name and a radio that matches no MeshCore preset" }
        return r[0] == .defaultName ? "Still has the firmware's default name" : "Radio matches no MeshCore preset"
    }
}

// MARK: - Node settings helpers

enum MeshCoreNodeLimits {
    /// The firmware keeps 32 bytes for the name, the last one a terminator.
    static let maxNameBytes = 31

    /// The text cut to whole characters that fit in `maxBytes` of UTF-8.
    static func clamp(_ text: String, maxBytes: Int = maxNameBytes) -> String {
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// LoRa bandwidths the radios support (kHz).
    static let bandwidths: [Double] = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500]

    /// Settings the firmware accepts (150-2500 MHz, SF 5-12, CR 5-8) with a bandwidth the radio supports.
    static func isValidRadio(frequency: Double, bandwidth: Double, spreadingFactor: Int, codingRate: Int) -> Bool {
        (150...2500).contains(frequency) && (5...12).contains(spreadingFactor) && (5...8).contains(codingRate)
            && bandwidths.contains { abs($0 - bandwidth) < 0.01 }
    }

    /// The first empty private-channel slot, using the node's real channel count
    /// (40 on v1.17; 8 when the node hasn't said). Slot 0 is the public channel.
    static func freeChannelSlot(used: Set<Int>, maxChannels: Int?) -> Int? {
        (1..<max(maxChannels ?? 8, 2)).first { !used.contains($0) }
    }
}

/// Who may ask this node for telemetry. The firmware packs three of these into one
/// byte: base (battery) in bits 0-1, location in bits 2-3, environment in bits 4-5
/// (examples/companion_radio/MyMesh.cpp CMD_SET_OTHER_PARAMS; NodePrefs.h TELEM_MODE_*).
enum MeshCoreTelemetryMode: UInt8, CaseIterable, Identifiable, Sendable {
    case nobody = 0
    case allowed = 1
    case anyone = 2

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .nobody: return "Nobody"
        case .allowed: return "Contacts I allow"
        case .anyone: return "Anyone"
        }
    }

    struct Modes: Equatable, Sendable {
        var base: MeshCoreTelemetryMode
        var location: MeshCoreTelemetryMode
        var environment: MeshCoreTelemetryMode

        init(base: MeshCoreTelemetryMode, location: MeshCoreTelemetryMode, environment: MeshCoreTelemetryMode) {
            self.base = base
            self.location = location
            self.environment = environment
        }

        /// From the node's byte; unknown values (3) read as Nobody.
        init(byte: UInt8) {
            base = MeshCoreTelemetryMode(rawValue: byte & 0x03) ?? .nobody
            location = MeshCoreTelemetryMode(rawValue: (byte >> 2) & 0x03) ?? .nobody
            environment = MeshCoreTelemetryMode(rawValue: (byte >> 4) & 0x03) ?? .nobody
        }

        var byte: UInt8 { (environment.rawValue << 4) | (location.rawValue << 2) | base.rawValue }
    }
}
