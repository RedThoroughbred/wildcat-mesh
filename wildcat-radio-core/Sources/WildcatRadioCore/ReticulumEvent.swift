import Foundation

// The events Wildcat's bridge sends up from the Reticulum stack, decoded. The bridge is Wildcat's
// own Python glue (`Reticulum/python/wildcat_reticulum` in the app): this is its JSON, not a
// Reticulum wire format. Decoding never traps on a field that is missing or of another type.

extension Reticulum {
    public struct InterfaceState: Equatable, Identifiable, Sendable {
        public var name: String
        public var online: Bool
        public var rxBytes: Int
        public var txBytes: Int
        public var id: String { name }

        public init(name: String, online: Bool, rxBytes: Int = 0, txBytes: Int = 0) {
            self.name = name
            self.online = online
            self.rxBytes = rxBytes
            self.txBytes = txBytes
        }

        /// The RNode's interface (the bridge names it "RNode over Bluetooth").
        public var isRNode: Bool { name.contains("RNode") }
    }

    public struct Started: Equatable, Sendable {
        public var address: String
        public var identityHash: String
        public var rns: String
        public var lxmf: String
        public var crypto: String
        public var python: String
        public var reticulumMs: Int?
        public var lxmfMs: Int?
        /// The radio settings Reticulum was started with, when it has an RNode.
        public var radio: RadioSettings?

        public init(address: String, identityHash: String = "", rns: String = "?", lxmf: String = "?", crypto: String = "?",
                    python: String = "?", reticulumMs: Int? = nil, lxmfMs: Int? = nil, radio: RadioSettings? = nil) {
            self.address = address
            self.identityHash = identityHash
            self.rns = rns
            self.lxmf = lxmf
            self.crypto = crypto
            self.python = python
            self.reticulumMs = reticulumMs
            self.lxmfMs = lxmfMs
            self.radio = radio
        }

        /// "RNS 1.5.7 · LXMF 1.2.0 · Python 3.13.16 · openssl".
        public var versions: String { "RNS \(rns) · LXMF \(lxmf) · Python \(python) · \(crypto)" }
    }

    public struct Announce: Equatable, Sendable {
        public var hash: String
        public var name: String?
        public var hops: Int?
        public var stampCost: Int?
        public var at: Date

        public init(hash: String, name: String? = nil, hops: Int? = nil, stampCost: Int? = nil, at: Date) {
            self.hash = hash
            self.name = name
            self.hops = hops
            self.stampCost = stampCost
            self.at = at
        }
    }

    public enum Event: Equatable, Sendable {
        case ready(python: String)
        /// A new identity: the 64-byte private key, for the Keychain.
        case identity(privateKey: Data, identityHash: String)
        case started(Started)
        case interfaces([InterfaceState])
        case announce(Announce)
        /// This phone announced itself.
        case announced(Date)
        /// A message in either direction, as first reported (an outgoing one is `queued`).
        case message(Message)
        case messageState(id: String, delivery: Delivery, failure: Failure?, detail: String?)
        case log(String)
        case error(String)
        case stopped
        case heartbeat(Date)
        case pythonExited(Int)

        public static func decode(_ json: String, now: Date = Date()) -> Event? {
            guard let data = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = o["event"] as? String else { return nil }
            func s(_ k: String) -> String? { o[k] as? String }
            func i(_ k: String, in d: [String: Any]? = nil) -> Int? {
                guard let n = (d ?? o)[k] as? NSNumber, !(n === kCFBooleanTrue || n === kCFBooleanFalse) else { return nil }
                let v = n.doubleValue
                guard v.isFinite, abs(v) < 1e15 else { return nil }
                return Int(v)
            }
            func date(_ k: String) -> Date {
                guard let n = o[k] as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0, n.doubleValue < 1e11 else { return now }
                return Date(timeIntervalSince1970: n.doubleValue)
            }
            switch name {
            case "ready":
                return .ready(python: s("python") ?? "?")
            case "identity":
                guard let hex = s("private_key"), let key = Data(reticulumHex: hex), key.count == 64 else {
                    return .error("identity event without a 64-byte key")
                }
                return .identity(privateKey: key, identityHash: s("identity_hash") ?? "")
            case "started":
                let t = o["timings_ms"] as? [String: Any]
                var radio: RadioSettings?
                if let r = o["rnode"] as? [String: Any], let f = i("frequency", in: r), let b = i("bandwidth", in: r),
                   let sf = i("spreadingfactor", in: r), let cr = i("codingrate", in: r), let tx = i("txpower", in: r),
                   let fHz = UInt32(exactly: f), let bHz = UInt32(exactly: b) {
                    radio = RadioSettings(frequencyHz: fHz, bandwidthHz: bHz, spreadingFactor: sf, codingRate: cr, txPower: tx)
                }
                return .started(Started(address: s("address") ?? "", identityHash: s("identity_hash") ?? "", rns: s("rns") ?? "?",
                                        lxmf: s("lxmf") ?? "?", crypto: s("crypto") ?? "?", python: s("python") ?? "?",
                                        reticulumMs: t.flatMap { i("reticulum", in: $0) }, lxmfMs: t.flatMap { i("lxmf", in: $0) },
                                        radio: radio))
            case "interfaces":
                let list = (o["list"] as? [[String: Any]] ?? []).map {
                    InterfaceState(name: $0["name"] as? String ?? "?", online: $0["online"] as? Bool ?? false,
                                   rxBytes: i("rxb", in: $0) ?? 0, txBytes: i("txb", in: $0) ?? 0)
                }
                return .interfaces(list)
            case "announce":
                guard let hash = s("hash").flatMap(Reticulum.address) else { return nil }
                return .announce(Announce(hash: hash, name: s("name"), hops: i("hops"), stampCost: i("stamp_cost"), at: date("at")))
            case "announced":
                return .announced(date("at"))
            case "message":
                let incoming = s("direction") == "in"
                guard let peer = (incoming ? s("from") : s("to")).flatMap(Reticulum.address) else { return nil }
                if incoming {
                    guard let id = s("hash"), !id.isEmpty else { return nil }
                    let trust = Trust(validated: o["signature_validated"] as? Bool ?? false, reason: s("unverified"))
                    return .message(Message(id: id, incoming: true, peer: peer, text: s("text") ?? "", at: date("at"),
                                            delivery: .received, trust: trust, read: false))
                }
                guard let id = s("id"), !id.isEmpty else { return nil }
                return .message(Message(id: id, incoming: false, peer: peer, text: s("text") ?? "", at: date("at"),
                                        delivery: Delivery(bridge: s("state") ?? "queued")))
            case "message_state":
                guard let id = s("id"), let state = s("state") else { return nil }
                let delivery = Delivery(bridge: state)
                let failure = delivery == .failed ? (Failure(bridge: s("reason")) ?? Failure(bridge: state) ?? .noAnswer) : nil
                return .messageState(id: id, delivery: delivery, failure: failure, detail: s("detail"))
            case "log":
                return .log(s("line") ?? "")
            case "error":
                return .error(s("message") ?? "error")
            case "stopped":
                return .stopped
            case "heartbeat":
                return .heartbeat(date("at"))
            case "python_exited":
                return .pythonExited(i("code") ?? 0)
            default:
                return nil
            }
        }
    }
}

extension Data {
    /// Bytes from an even number of hex digits, or nil.
    init?(reticulumHex hex: String) {
        let u = Array(hex.utf8)
        guard u.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out = Data(capacity: u.count / 2)
        var k = 0
        while k < u.count {
            guard let hi = nibble(u[k]), let lo = nibble(u[k + 1]) else { return nil }
            out.append(hi << 4 | lo)
            k += 2
        }
        self = out
    }
}
