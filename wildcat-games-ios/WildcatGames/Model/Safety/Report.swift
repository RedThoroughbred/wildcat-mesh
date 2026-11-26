import Foundation

/// A received message the player can block or report: who to block, and what a report says.
struct Flagged: Identifiable {
    let id = UUID()
    /// What Block adds.
    var sender: BlockedSender
    /// "Meshtastic" or "MeshCore": where the message arrived.
    var network: String
    /// "#Primary", "direct message", …
    var place: String
    var text: String
    var time: Date
    /// Set when a bridge relayed it from the other network.
    var bridgedFrom: String? = nil
}

/// The email a report opens: to `Support.email`, filled in, sent by the player's own mail app.
enum Report {
    static let subject = "Wildcat Mesh report"

    static func body(_ f: Flagged, app: String = Report.appVersion) -> String {
        let s = f.sender
        let id = s.key.isEmpty ? "no id (name only)" : s.key
        var lines = [
            "What happened (optional):",
            "",
            "",
            "----",
            "Network: \(f.network), \(f.place)",
            "Sender: \(s.name) (\(s.network.name) \(id))",
        ]
        if let b = f.bridgedFrom { lines.append("Relayed by a bridge from \(b)") }
        lines += [
            "Time: \(f.time.formatted(date: .abbreviated, time: .standard)) (\(f.time.formatted(.iso8601)))",
            "Message: \(f.text)",
            "",
            "Sent from \(app)",
        ]
        return lines.joined(separator: "\n")
    }

    /// For phones without Mail set up.
    static func mailto(_ f: Flagged) -> URL? {
        URL(string: "mailto:\(Support.email)?subject=\(encode(subject))&body=\(encode(body(f)))")
    }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "Wildcat \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
