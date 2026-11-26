import Foundation
import WildcatRadioCore

/// The last Meshtastic node this phone was connected to, kept so the
/// Meshtastic tab can still show it (dimmed) after a disconnect: its name,
/// channel names and the nodes it heard most recently. Channel keys are never
/// stored, only names.
struct MeshtasticCache: Codable, Equatable {
    struct Node: Codable, Equatable, Identifiable {
        var num: UInt32
        var shortName: String?
        var longName: String?
        var hardware: String?
        var role: Int?
        var snr: Double?
        var hopsAway: Int?
        var viaMQTT: Bool
        var lastHeard: Date?

        var id: UInt32 { num }
    }

    struct Channel: Codable, Equatable, Identifiable {
        var index: Int
        var name: String
        var primary: Bool

        var id: Int { index }
    }

    var num: UInt32
    var longName: String?
    var shortName: String?
    var firmware: String?
    var hardware: String?
    var role: Int?
    var region: String?
    var preset: String?
    var batteryVolts: Double?
    var batteryLevel: Int?
    var channels: [Channel]
    var heard: [Node]
    var saved: Date

    /// How many recently heard nodes to keep.
    static let limit = 12
    static let key = "meshtastic.lastNode"

    /// A snapshot of a ready session (nil before the node has said who it is).
    init?(session s: MeshSession, now: Date = Date()) {
        guard let me = s.myNode else { return nil }
        let mine = s.nodes[me]
        num = me.raw
        longName = mine?.longName
        shortName = mine?.shortName
        firmware = s.firmware
        hardware = mine?.hardware
        role = s.device?.role.rawValue ?? mine?.role
        region = s.lora.map { $0.region.title }
        preset = s.lora.map { $0.preset.title }
        batteryVolts = mine?.metrics?.voltage
        batteryLevel = mine?.metrics?.batteryLevel
        channels = s.channels.values.sorted { $0.index < $1.index }
            .map { Channel(index: $0.index, name: $0.name, primary: $0.role == .primary) }
        heard = s.nodes.values
            .filter { $0.num != me && !$0.isIgnored }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
            .prefix(Self.limit)
            .map { n in
                Node(num: n.num.raw, shortName: n.shortName, longName: n.longName, hardware: n.hardware, role: n.role,
                     snr: n.snr.map(Double.init), hopsAway: n.hopsAway, viaMQTT: n.viaMQTT, lastHeard: n.lastHeard)
            }
        saved = now
    }

    var nodeNum: NodeNum { NodeNum(num) }

    static func load(_ defaults: UserDefaults = .standard) -> MeshtasticCache? {
        guard let d = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MeshtasticCache.self, from: d)
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let d = try? JSONEncoder().encode(self) else { return }
        defaults.set(d, forKey: Self.key)
    }
}

/// Plain-English readings for the Meshtastic node card.
enum MeshtasticSummary {
    /// "All good. **Hearing 5 nodes**, 3 of them direct." in three parts, the
    /// middle one emphasised.
    struct Sentence: Equatable {
        var lead: String
        var emphasis: String
        var tail: String

        var plain: String { lead + emphasis + tail }
    }

    static func sentence(heard: Int, direct: Int, channelUse: Double?, needsRegion: Bool, practice: Bool) -> Sentence {
        if needsRegion {
            return Sentence(lead: "Not on the air yet. ", emphasis: "No region set", tail: ", so this node won't transmit.")
        }
        let lead: String
        if practice {
            lead = "Practice mesh on this phone. "
        } else if let u = channelUse, u >= crowded {
            lead = "Crowded channel: your node will hold back. "
        } else if let u = channelUse, u >= busy {
            lead = "Busy channel. "
        } else {
            lead = heard == 0 ? "Connected. " : "All good. "
        }
        guard heard > 0 else { return Sentence(lead: lead, emphasis: "Nobody heard yet", tail: ".") }
        let nodes = "Hearing \(heard) node\(heard == 1 ? "" : "s")"
        let tail: String
        switch direct {
        case 0: tail = ", none of them direct."
        case heard where heard > 1: tail = ", all of them direct."
        case heard: tail = ", direct."
        default: tail = ", \(direct) of them direct."
        }
        return Sentence(lead: lead, emphasis: nodes, tail: tail)
    }

    /// Channel utilisation where Meshtastic starts to hold back (%).
    static let busy = 25.0
    static let crowded = 40.0

    /// "Quiet channel", "Busy channel", "Crowded channel".
    static func channelWord(_ utilisation: Double?) -> String {
        guard let u = utilisation, u.isFinite else { return "No report yet" }
        if u >= crowded { return "Crowded channel" }
        if u >= busy { return "Busy channel" }
        return "Quiet channel"
    }

    /// The best SNR among nodes heard directly (not relayed, not internet).
    static func bestSNR(_ nodes: [NodeInfo], excluding me: NodeNum?) -> Double? {
        nodes.filter { $0.num != me && $0.hopsAway == 0 && !$0.viaMQTT }
            .compactMap { $0.snr.map(Double.init) }
            .filter(\.isFinite)
            .max()
    }

    /// Uptime as a readout: ("42", "min"), ("5", "h"), ("3d 04", "h").
    static func uptime(_ seconds: Int) -> (value: String, unit: String) {
        let s = max(0, seconds)
        if s < 3600 { return ("\(s / 60)", "min") }
        if s < 86_400 { return ("\(s / 3600)", "h") }
        return ("\(s / 86_400)d " + String(format: "%02d", (s % 86_400) / 3600), "h")
    }

    /// A number with a true minus sign: "−3.2".
    static func signed(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(max(0, digits))f", value).replacingOccurrences(of: "-", with: "−")
    }

    /// A number with up to `digits` decimals and a true minus sign ("9", "9.5", "−3.25"): the
    /// MeshCore rows' format, so both tabs read the same.
    static func number(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...max(0, digits)))).replacingOccurrences(of: "-", with: "−")
    }

    /// "9 dB", "−3.25 dB".
    static func db(_ snr: Double) -> String { number(snr, digits: 2) + " dB" }

    /// Routers and repeaters: the mesh's infrastructure, drawn in the network colour (as the
    /// MeshCore tab draws its repeaters and room servers); everyone else is grey.
    static func isInfrastructure(role: Int?) -> Bool {
        guard let role, let r = DeviceRole(rawValue: role) else { return false }
        return r == .router || r == .repeater || r == .routerLate
    }

    /// "Direct", "2 hops", "internet".
    static func path(hops: Int?, viaMQTT: Bool) -> String? {
        if viaMQTT { return "Internet" }
        guard let h = hops else { return nil }
        return h == 0 ? "Direct" : "\(h) hop\(h == 1 ? "" : "s")"
    }

    /// A short "how long ago" for rows: "just now", "42 s ago", "5 min ago", "3 h ago", "2 d ago".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never heard" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }

    /// Range-ring spacing (m) so three rings reach past the farthest node:
    /// a round step (100 m, 250 m, 500 m, 1 km, 2 km, 5 km …).
    static func ringStep(farthest metres: Double) -> Double {
        let steps: [Double] = [100, 250, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000]
        guard metres.isFinite, metres > 0 else { return 1000 }
        return steps.first { $0 * 3 >= metres * 1.05 } ?? steps[steps.count - 1]
    }

    /// Roles that pass traffic along (drawn with a tower, not a person).
    static func isInfrastructure(_ role: Int?) -> Bool {
        guard let role, let r = DeviceRole(rawValue: role) else { return false }
        return [.router, .repeater, .routerLate, .clientBase].contains(r)
    }

    /// The row glyph for a node's role.
    static func symbol(role: Int?, viaMQTT: Bool = false) -> String {
        if viaMQTT { return "globe" }
        guard let role, let r = DeviceRole(rawValue: role) else { return "person" }
        switch r {
        case .router, .repeater, .routerLate: return "antenna.radiowaves.left.and.right"
        case .clientBase: return "house"
        case .tracker, .takTracker, .lostAndFound: return "location"
        case .sensor: return "thermometer.medium"
        default: return "person"
        }
    }

    /// "What is a router?" and one or two plain sentences, for the node page.
    static func explainer(role: Int?) -> (title: String, text: String) {
        let r = role.flatMap(DeviceRole.init(rawValue:)) ?? .client
        switch r {
        case .router, .routerLate:
            return ("What is a router?",
                    "A node on a hill or roof that passes messages along so they travel farther. It is always on and relays for everyone.")
        case .repeater:
            return ("What is a repeater?", "A node that only relays. It doesn't chat and usually hides from node lists.")
        case .clientBase:
            return ("What is a base?", "A home node for someone's own radios. It relays their traffic first, then everyone else's.")
        case .clientMute:
            return ("What is a mute client?", "A node someone carries that talks and listens but never relays for others.")
        case .tracker, .takTracker:
            return ("What is a tracker?", "A node that sends its position often and sleeps in between. You can see it on the map.")
        case .sensor:
            return ("What is a sensor?", "A node that reports readings (temperature, battery) and sleeps in between.")
        default:
            return ("What is a client?",
                    "A node a person carries. You can message it, and it relays for others when that helps.")
        }
    }
}
