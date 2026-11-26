import Foundation
import WildcatRadioCore

/// What an owned node is, in plain English.
extension OwnedNode {
    var networkName: String { network == .meshcore ? "MeshCore" : "Meshtastic" }

    var meshtasticRole: DeviceRole? { network == .meshtastic ? roleCode.flatMap(DeviceRole.init(rawValue:)) : nil }
    var meshcoreKind: MeshCore.Contact.Kind? {
        network == .meshcore ? roleCode.flatMap { UInt8(exactly: $0) }.flatMap(MeshCore.Contact.Kind.init(rawValue:)) : nil
    }

    /// A MeshCore repeater or room server: reached over the air, managed by logging in.
    var isMeshCoreInfrastructure: Bool { meshcoreKind == .repeater || meshcoreKind == .room }

    /// Something the phone connects to over Bluetooth (a handheld or companion).
    var connectsToPhone: Bool {
        switch network {
        case .meshcore: return meshcoreKind == .chat || (roleCode == nil && origin == .connected)
        case .meshtastic: return bluetoothID != nil || origin == .connected
        }
    }

    /// "Repeater", "Companion", "Client".
    var roleTitle: String {
        switch network {
        case .meshcore:
            guard let k = meshcoreKind, k != .none else { return "MeshCore node" }
            return MeshCoreFormat.kind(k)
        case .meshtastic:
            return meshtasticRole?.title ?? "Meshtastic node"
        }
    }

    /// "Repeater · forwards everyone's messages", for cards.
    var roleSummary: String {
        let what: String?
        switch network {
        case .meshcore:
            switch meshcoreKind {
            case .chat?: what = "your radio, never repeats"
            case .repeater?: what = "forwards everyone's messages"
            case .room?: what = "keeps posts to catch up on"
            case .sensor?: what = "reports readings"
            default: what = nil
            }
        case .meshtastic:
            switch meshtasticRole {
            case .client?: what = "sends, receives, repeats"
            case .clientMute?: what = "never repeats"
            case .clientBase?: what = "home base for your radios"
            case .router?, .routerLate?, .repeater?: what = "always-on relay"
            case .tracker?: what = "sends its position"
            case .sensor?: what = "sends readings"
            default: what = nil
            }
        }
        return what.map { "\(roleTitle) · \($0)" } ?? roleTitle
    }

    /// One or two sentences on what this role does.
    var roleExplanation: String {
        switch network {
        case .meshcore:
            switch meshcoreKind {
            case .chat?:
                return "Companion: your personal radio. It talks to this phone over Bluetooth and never repeats other people's messages."
            case .repeater?:
                return "Repeater: forwards other people's messages across the mesh. It doesn't send messages of its own."
            case .room?:
                return "Room server: a shared message board on the mesh. It keeps recent posts so people can catch up when they check in."
            case .sensor?:
                return "Sensor: reports readings (like temperature or battery) to anyone allowed to ask. It doesn't chat."
            default:
                return "A MeshCore node. Connect to it or log in to learn what it does."
            }
        case .meshtastic:
            switch meshtasticRole {
            case .client?:
                return "Client: your everyday radio. It sends and receives messages, and repeats other people's when that helps the mesh."
            case .clientMute?:
                return "Client (mute): sends and receives, but never repeats anyone else's messages. Handy for a second radio next to another."
            case .clientHidden?:
                return "Client (hidden): only speaks when it has to and stays out of other people's node lists."
            case .clientBase?:
                return "Client base: a home base for your own radios. It repeats their messages first."
            case .router?:
                return "Router: an always-on relay on a high spot. It repeats everything it hears to stretch the mesh. Not for carrying around."
            case .routerLate?:
                return "Router (late): a relay that waits for others to go first, then repeats only what they missed."
            case .repeater?:
                return "Repeater: only relays other people's messages, and hides from node lists."
            case .tracker?:
                return "Tracker: sends its position often and sleeps the rest of the time."
            case .sensor?:
                return "Sensor: sends readings often and sleeps the rest of the time."
            case .tak?, .takTracker?:
                return "TAK: set up for people using ATAK."
            case .lostAndFound?:
                return "Lost & found: keeps broadcasting where it is, so you can find it."
            case nil:
                return "A Meshtastic node. Connect to it to read how it's set up."
            }
        }
    }

    /// "3.91 V · 82%", "Powered", or nil.
    var batteryText: String? {
        var parts: [String] = []
        if let p = batteryPercent { parts.append(p > 100 ? "Powered" : "\(p)%") }
        if let v = batteryVolts, v > 0 { parts.append(String(format: "%.2f V", v)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One battery figure for cards: the percent when known, else volts.
    var batteryShort: String? {
        if let p = batteryPercent { return p > 100 ? "powered" : "\(p)%" }
        return batteryVolts.flatMap { $0 > 0 ? String(format: "%.2f V", $0) : nil }
    }

    /// "3 min ago", "2 days ago", "just now", "never".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { let h = s / 3600; return "\(h) hour\(h == 1 ? "" : "s") ago" }
        let d = s / 86_400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
