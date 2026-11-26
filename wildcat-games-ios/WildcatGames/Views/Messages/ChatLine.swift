import Foundation
import WildcatRadioCore

/// Everything a chat shows about one message, whichever network it travelled
/// on. Meshtastic, MeshCore and Den chats each turn their own message type into
/// this, so all three draw with the same `MessageBubble`.
struct ChatLine: Identifiable {
    enum Status: Equatable {
        case received
        case sending
        /// Out on the air. Meshtastic: a neighbour repeated it. MeshCore: nothing heard back yet.
        case sent
        /// MeshCore channel: this many repeaters were heard passing it on.
        case heardBy(Int)
        /// MeshCore channel: the listening window closed and no repeater was heard.
        case unheard
        /// The recipient confirmed it.
        case delivered
        case failed(String)
        /// MeshCore direct: handed to the node again (try 2 and up).
        case retrying(try: Int)
        /// MeshCore direct: on air (by flood, or along the known route), waiting for the recipient.
        case awaiting(try: Int, flood: Bool)
        /// MeshCore direct: given up, and why (it may have gone out but never been confirmed).
        case undelivered(String)

        /// Didn't make it: shown in red, with a Retry.
        var isFailed: Bool {
            switch self {
            case .failed, .undelivered: return true
            default: return false
            }
        }
    }

    struct Quote: Equatable {
        let sender: String
        let text: String
    }

    let id: UUID
    let network: MeshNetwork
    /// Typed on this phone (bridged lines the phone posted are not "mine": they read as arrivals).
    var mine = false
    var sender: String?
    /// "!a3f9c21e" or a MeshCore key prefix in hex.
    var senderID: String?
    /// Grey note after the sender ("#LongFast", "→ MAYA"), for mixed feeds like the Den's.
    var context: String?
    var time: Date
    var text: String
    var quote: Quote?
    var reactions: [(emoji: String, count: Int)] = []
    /// Where a bridged line was really said.
    var bridged: BridgeOrigin?
    /// The node that re-posted a bridged line here, as a name.
    var bridgeVia: String?
    var status: Status = .received
    /// Direct message (not a channel).
    var direct = false
    var snr: Double?
    var rssi: Int?
    var hops: Int?
    var hopStart: Int?
    var hopLimit: Int?
    /// MeshCore relay hashes, oldest first.
    var path: [Data]?
    /// Sent by flood (MeshCore), or along a known route.
    var flood: Bool?
    var size: Int?
    var airtimeMs: Int?
    var roundTripMs: Int?
    var viaMQTT = false
    /// Meshtastic: low byte of the last relay.
    var relayNode: UInt32?
    var packetHash: String?
    /// Packet kind for the raw view ("GRP_TXT", "TEXT").
    var kind: String?
    /// Name of this phone's radio it came through or went out on.
    var radioName: String?
    var raw: Data?

    /// Received text goes through the word filter; your own never does.
    var filtered: Bool { !mine }
}

// MARK: - Words and raw lines (pure)

/// The plain-English and raw lines under a message, and the numbers in them.
enum ChatMeta {
    /// A true minus sign in displayed negatives ("−97 dBm").
    static func minus(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "−") }

    /// Up to `digits` decimals, no trailing zeros: 12.2, 6.75, −3.
    static func number(_ v: Double, digits: Int = 2) -> String {
        guard v.isFinite else { return "—" }
        let p = pow(10, Double(digits))
        var s = String(format: "%.\(digits)f", (v * p).rounded() / p)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return minus(s)
    }

    static func dBm(_ rssi: Int) -> String { minus("\(rssi) dBm") }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Relay hashes as "7a›c4›19".
    static func path(_ p: [Data], separator: String = "›") -> String { p.map(hex).joined(separator: separator) }

    /// "direct", "1 hop", "5 hops".
    static func hops(_ n: Int) -> String { n <= 0 ? "direct" : n == 1 ? "1 hop" : "\(n) hops" }

    /// "640 ms" under a second, else "1.8 s".
    static func duration(ms: Int) -> String {
        ms < 1000 ? "\(max(0, ms)) ms" : number(Double(ms) / 1000, digits: 1) + " s"
    }

    /// Plain English under a received message: "5 hops · strong signal",
    /// "3 hops on Meshtastic, relayed here by Wildcat Bag". Nil when nothing is known.
    static func plain(_ l: ChatLine) -> String? {
        if let b = l.bridged {
            var s = l.bridged?.hops.map { "\(hops($0)) on \(b.network.title)" } ?? "Said on \(b.network.title)"
            if let via = l.bridgeVia, !via.isEmpty { s += ", relayed here by \(via)" }
            return s
        }
        var parts: [String] = []
        if let h = l.hops { parts.append(hops(h)) }
        if l.viaMQTT {
            parts.append("through the internet")
        } else {
            let grade = SignalGrade.grade(snr: l.snr, rssi: l.rssi)
            if grade != .none { parts.append("\(grade.word) signal") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The raw line under a received message: "SNR 12.2 · −97 dBm · path 7a›c4".
    static func raw(_ l: ChatLine) -> String? {
        var parts: [String] = []
        if let s = l.snr { parts.append("SNR \(number(s))") }
        if let r = l.rssi { parts.append(dBm(r)) }
        if let p = l.path, !p.isEmpty { parts.append("path \(path(p))") }
        if let start = l.hopStart, let left = l.hopLimit, start > 0 { parts.append("hop limit \(left)/\(start)") }
        if let r = l.relayNode { parts.append("relay \(String(format: "%02x", r & 0xff))") }
        if l.viaMQTT { parts.append("MQTT") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The raw part of your own message's line: "flood · 44 B · 63 ms".
    static func sentRaw(_ l: ChatLine) -> String? {
        var parts: [String] = []
        // "sent by flood" already says it.
        let statusSaysFlood: Bool = { if case .awaiting(_, true) = l.status { return true } else { return false } }()
        if let f = l.flood, !statusSaysFlood { parts.append(f ? "flood" : "direct route") }
        if let s = l.size { parts.append("\(s) B") }
        if let a = l.airtimeMs { parts.append("\(a) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How your own message is doing, in words.
    static func status(_ l: ChatLine) -> String? {
        switch l.status {
        case .received: return nil
        case .sending: return "sending…"
        case .sent: return "sent"
        case .heardBy(let n): return "heard by \(n) repeater\(n == 1 ? "" : "s")"
        case .unheard: return "no repeater heard it"
        case .delivered: return "delivered" + (l.roundTripMs.map { " " + duration(ms: $0) } ?? "")
        case .failed(let why): return why.isEmpty ? "not sent" : "not sent · \(why)"
        case .retrying(let n): return "sending · try \(n)"
        case .awaiting(let n, let flood): return "sent" + (flood ? " by flood" : "") + (n > 1 ? " · try \(n)" : "")
        case .undelivered(let why): return why.isEmpty ? "not delivered" : lowerFirst(why)
        }
    }

    /// "No confirmation after 3 tries" -> "no confirmation after 3 tries" (status words are lower case).
    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    /// Where your MeshCore direct message stands: the core's delivery when it tracks one,
    /// else (chats saved before 1.1) the confirmation and ack it always kept.
    static func meshcoreDirectStatus(_ c: MeshCoreSession.Chat) -> ChatLine.Status {
        switch c.delivery {
        case .sending(let a)?: return a <= 0 ? .sending : .retrying(try: a + 1)
        case .sent(let a, let flood)?: return .awaiting(try: a + 1, flood: flood)
        case .delivered?: return .delivered
        case .failed(let f)?: return .undelivered(f.reason)
        case nil: return c.confirmed ? .delivered : c.ack != nil ? .sent : .sending
        }
    }

    /// Estimated bytes on air for a MeshCore text: a channel message (GRP_TXT, the
    /// sender's name goes in front) or a direct one (TXT). The payload is encrypted
    /// in 16-byte blocks, so this rounds up the way the radio does.
    static func meshcoreSize(text: String, senderName: String?, channel: Bool) -> Int {
        func blocks(_ n: Int) -> Int { (n + 15) / 16 * 16 }
        let body = text.utf8.count
        if channel {
            // header, path length, channel hash, 2-byte MAC; timestamp 4 + flags 1 + "NAME: text".
            let name = senderName.map { $0.utf8.count + 2 } ?? 0
            return 5 + blocks(5 + name + body)
        }
        // header, path length, destination and source hashes, 2-byte MAC; timestamp 4 + flags 1 + text.
        return 6 + blocks(5 + body)
    }
}
