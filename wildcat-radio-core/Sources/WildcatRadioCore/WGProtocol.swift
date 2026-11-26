import Foundation

/// The Wildcat Games text protocol (WG v0), as refereed by the Den's
/// `foxhunt.py` / `wg.py`. Plain text, at most 180 bytes, sent on the
/// WGHUNT channel. Hunt codes look like "FOX7" (`FOX` + 1–4 word characters).
public enum WG {
    public static let maxBytes = 180

    /// The hint a referee puts after the "·" of its END line when the hunt's time limit ran out:
    /// "WG END FOX7 MAYA WINS 1/2 FOUND · TIME UP". The part before the "·" is unchanged, so
    /// every hunter (and older apps) still reads the END as before.
    public static let timeUpHint = "TIME UP"

    /// True when a referee's line carries `timeUpHint` after a "·".
    public static func isTimeUp(_ text: String) -> Bool {
        text.components(separatedBy: "·").dropFirst()
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == timeUpHint }
    }

    /// A signal reading as the protocol writes it: "-88" (RSSI dBm) or "S6.5" (SNR dB).
    public struct Signal: Equatable, Sendable {
        public var rssi: Int?
        public var snr: Double?

        public init(rssi: Int? = nil, snr: Double? = nil) {
            self.rssi = rssi
            self.snr = snr
        }

        /// "-88", "S6.5" or "?" (the Den's `fmt_sig`).
        public var wire: String {
            if let rssi { return String(rssi) }
            if let snr { return "S" + String(format: "%.1f", snr) }
            return "?"
        }

        init?(wire: String) {
            if wire == "?" { self.init(); return }
            if wire.uppercased().hasPrefix("S"), let v = Double(wire.dropFirst()) {
                // Radio text comes from strangers: "nan", "inf" or 1e300 must not get through.
                guard v.isFinite, (-100...100).contains(v) else { return nil }
                self.init(snr: v); return
            }
            if let v = Int(wire) { self.init(rssi: v); return }
            if let v = Double(wire) {
                guard v.isFinite, (-200...200).contains(v) else { return nil }
                self.init(rssi: Int(v.rounded())); return
            }
            return nil
        }
    }

    // MARK: Hunter -> Den

    public enum Command: Equatable, Sendable {
        case join(hunt: String?, name: String?)
        /// What the hunter's own node heard from the fox.
        case sig(hunt: String?, Signal)
        case found(hunt: String?, code: String?)
        case status
        case leave
        case ping(nonce: String?)

        public var text: String {
            func withHunt(_ verb: String, _ hunt: String?) -> [String] {
                ["WG", verb] + (hunt.map { [$0.uppercased()] } ?? [])
            }
            var parts: [String]
            switch self {
            case .join(let hunt, let name):
                parts = withHunt("JOIN", hunt) + (name.map { [WG.sanitizedName($0)] } ?? [])
            case .sig(let hunt, let s):
                parts = withHunt("SIG", hunt)
                if let rssi = s.rssi {
                    parts.append(String(rssi))
                    if let snr = s.snr { parts.append(String(format: "%.1f", snr)) }
                } else if let snr = s.snr {
                    parts += ["SNR", String(format: "%.1f", snr)]
                }
            case .found(let hunt, let code):
                parts = withHunt("FOUND", hunt) + (code.map { [$0] } ?? [])
            case .status:
                parts = ["WG", "HUNT"]
            case .leave:
                parts = ["WG", "LEAVE"]
            case .ping(let nonce):
                parts = ["WG", "PING"] + (nonce.map { [$0] } ?? [])
            }
            return parts.joined(separator: " ").utf8Prefix(WG.maxBytes)
        }
    }

    /// Names the Den accepts: a letter, then up to 9 letters, digits, "_" or "-".
    public static func sanitizedName(_ name: String) -> String {
        let allowed = name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        let trimmed = allowed.drop { !$0.isLetter }
        return String(trimmed.prefix(10)).uppercased()
    }

    // MARK: Den -> hunter

    public enum Trend: String, Equatable, Sendable {
        case first = "FIRST", warmer = "WARMER", colder = "COLDER", steady = "STEADY", hot = "HOT"
    }

    public enum Phase: String, Equatable, Sendable {
        case lobby = "LOBBY", live = "LIVE", ended = "ENDED"
    }

    public enum Proof: String, Equatable, Sendable {
        /// Tier A: the fox's own radio relayed the claim.
        case rfWitnessed = "RF-A"
        /// Tier B: the hunter's node heard the fox at or above threshold recently.
        case rfAttested = "RF-B"
        /// Tier D: the code on the box.
        case code = "CODE"
    }

    public enum Reply: Equatable, Sendable {
        case pong(nonce: String?, rssi: Int?, snr: Double?, hops: Int?, viaMQTT: Bool)
        case joined(hunt: String, name: String, hunters: Int, phase: Phase, fox: String)
        case go(hunt: String, fox: String)
        case warmth(hunt: String, trend: Trend, previous: Signal?, current: Signal, best: Signal,
                    bearing: Int?, askForCode: Bool)
        case youFound(hunt: String, place: Int, points: Int, proofs: [Proof], minutes: Int)
        case someoneFound(hunt: String, name: String, place: Int, minutes: Int)
        case status(hunt: String, phase: Phase, minutes: Int, hunters: Int, found: Int, fox: String)
        case noHunt
        case left(hunt: String)
        case ended(hunt: String, winner: String?, found: Int, total: Int)
        /// "WG NO <verb> [hunt] <reason…>": BADCODE 2/5, LOCKED, NOT STARTED, OVER, NEED CODE, NO HUNT, FORMAT.
        case rejected(verb: String, hunt: String?, reason: String)
        case other(String)

        /// Parses a WG line; nil when the text is not WG at all.
        public init?(_ text: String) {
            // "·" separates the machine part from human hints.
            let head = text.components(separatedBy: "·").first ?? text
            let t = head.split(whereSeparator: \.isWhitespace).map(String.init)
            guard t.count >= 2, t[0].uppercased() == "WG" else { return nil }
            let verb = t[1].uppercased()
            let rest = Array(t.dropFirst(2))
            if verb == "GO", let hunt = rest.first {
                // WG GO FOX7 HUNT IS LIVE · FOX ZEUZ · SIG <rssi> <snr> · FOUND <code>
                let all = text.split(whereSeparator: { $0.isWhitespace || $0 == "·" }).map(String.init)
                let fox = all.indices.dropFirst(3).first { all[$0].uppercased() == "FOX" && $0 + 1 < all.count }
                self = .go(hunt: hunt, fox: fox.map { all[$0 + 1] } ?? "")
            } else if let parsed = Self.parse(verb: verb, rest) {
                self = parsed
            } else {
                self = .other(text)
            }
        }

        private static func minutes(_ s: String) -> Int? {
            // "T+14M"
            guard s.uppercased().hasPrefix("T+"), s.uppercased().hasSuffix("M") else { return nil }
            return Int(s.dropFirst(2).dropLast())
        }

        private static func isHunt(_ s: String) -> Bool {
            s.uppercased().hasPrefix("FOX") && s.count >= 4 && s.count <= 7
        }

        private static func parse(verb: String, _ r: [String]) -> Reply? {
            switch verb {
            case "PONG":
                var nonce: String?, rssi: Int?, snr: Double?, hops: Int?, mqtt = false
                for tok in r {
                    let u = tok.uppercased()
                    if u.hasSuffix("DBM"), let v = Int(u.dropLast(3)) { rssi = v }
                    else if u.hasSuffix("DB"), let v = Double(u.dropLast(2)) { snr = v }
                    else if u.hasSuffix("H"), let v = Int(u.dropLast()) { hops = v }
                    else if u == "MQTT" { mqtt = true }
                    else if nonce == nil { nonce = tok }
                }
                return .pong(nonce: nonce, rssi: rssi, snr: snr, hops: hops, viaMQTT: mqtt)

            case "OK":
                guard let what = r.first?.uppercased() else { return nil }
                let a = Array(r.dropFirst())
                switch what {
                case "JOIN":
                    // FOX7 MAYA 3 HUNTING LIVE FOX 6b18
                    guard a.count >= 7, let n = Int(a[2]), a[3].uppercased() == "HUNTING",
                          let phase = Phase(rawValue: a[4].uppercased()), a[5].uppercased() == "FOX" else { return nil }
                    return .joined(hunt: a[0], name: a[1], hunters: n, phase: phase, fox: a[6])
                case "FOUND":
                    // FOX7 #1 +175 CODE+RF-B T+14M   (proofs may be absent)
                    guard a.count >= 4, a[1].hasPrefix("#"), let place = Int(a[1].dropFirst()),
                          a[2].hasPrefix("+"), let points = Int(a[2].dropFirst()),
                          let mins = minutes(a.last!) else { return nil }
                    let proofs = a.count >= 5 ? a[3].split(separator: "+").compactMap { Proof(rawValue: String($0).uppercased()) } : []
                    return .youFound(hunt: a[0], place: place, points: points, proofs: proofs, minutes: mins)
                case "LEAVE":
                    guard let hunt = a.first else { return nil }
                    return .left(hunt: hunt)
                default:
                    return nil
                }

            case "GO":
                // FOX7 HUNT IS LIVE · FOX ZEUZ … (the fox is after the "·", so read the raw hunt only)
                guard let hunt = r.first else { return nil }
                return .go(hunt: hunt, fox: "")

            case "W":
                // FOX7 WARMER -94>-88 BEST -85 [BRG 045]
                guard r.count >= 5, let trend = Trend(rawValue: r[1].uppercased()), r[3].uppercased() == "BEST",
                      let best = Signal(wire: r[4]) else { return nil }
                let pair = r[2].split(separator: ">").map(String.init)
                let current: Signal?
                let previous: Signal?
                if pair.count == 2 {
                    previous = Signal(wire: pair[0])
                    current = Signal(wire: pair[1])
                } else {
                    previous = nil
                    current = Signal(wire: r[2])
                }
                guard let current else { return nil }
                var bearing: Int?
                if let i = r.firstIndex(where: { $0.uppercased() == "BRG" }), i + 1 < r.count { bearing = Int(r[i + 1]) }
                return .warmth(hunt: r[0], trend: trend, previous: previous, current: current, best: best,
                               bearing: bearing, askForCode: trend == .hot)

            case "FOUND":
                // FOX7 MAYA #1 T+14M
                guard r.count >= 4, r[2].hasPrefix("#"), let place = Int(r[2].dropFirst()),
                      let mins = minutes(r[3]) else { return nil }
                return .someoneFound(hunt: r[0], name: r[1], place: place, minutes: mins)

            case "HUNT":
                if r.first?.uppercased() == "NONE" { return .noHunt }
                // FOX7 LIVE T+3M 2 HUNTERS 0 FOUND FOX 6b18
                guard r.count >= 9, let phase = Phase(rawValue: r[1].uppercased()), let mins = minutes(r[2]),
                      let hunters = Int(r[3]), let found = Int(r[5]) else { return nil }
                return .status(hunt: r[0], phase: phase, minutes: mins, hunters: hunters, found: found, fox: r[8])

            case "END":
                // FOX7 MAYA WINS 1/2 FOUND   |   FOX7 NO FINDS 0/2 FOUND
                guard r.count >= 5 else { return nil }
                let ratio = r[3].split(separator: "/").compactMap { Int($0) }
                guard ratio.count == 2 else { return nil }
                let winner = r[2].uppercased() == "WINS" ? r[1] : nil
                return .ended(hunt: r[0], winner: winner, found: ratio[0], total: ratio[1])

            case "NO":
                guard let what = r.first?.uppercased() else { return nil }
                var a = Array(r.dropFirst())
                var hunt: String?
                if let first = a.first, isHunt(first) {
                    hunt = first
                    a.removeFirst()
                }
                return .rejected(verb: what, hunt: hunt, reason: a.joined(separator: " "))

            default:
                return nil
            }
        }
    }
}
