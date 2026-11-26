import Foundation

/// Wildcat's side of Reticulum messaging. The Reticulum stack itself (RNS and LXMF) is the official
/// one, running unmodified in the app's embedded Python; nothing here is ported from it. This is what
/// Wildcat decides around it: whether it may start on an RNode, with which radio settings, and what
/// the app keeps of the people heard and the messages exchanged.
public enum Reticulum {
    /// An LXMF address is 16 bytes, written as 32 hex digits.
    public static let addressDigits = 32

    /// "<53802fdd…>" or "53802FDD…" as the 32 lowercase hex digits the bridge takes, or nil.
    public static func address(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        guard t.utf8.count == addressDigits, t.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return t
    }

    /// "53802fdd…a41c": an address short enough for a row.
    public static func shortAddress(_ hash: String) -> String {
        guard hash.count > 12 else { return hash }
        return "\(hash.prefix(8))…\(hash.suffix(4))"
    }

    // MARK: Radio settings

    /// The five LoRa settings Reticulum sets on the RNode when it starts. Both ends must match.
    public struct RadioSettings: Codable, Equatable, Sendable {
        public var frequencyHz: UInt32
        public var bandwidthHz: UInt32
        public var spreadingFactor: Int
        /// 5...8, for 4/5...4/8.
        public var codingRate: Int
        public var txPower: Int

        public init(frequencyHz: UInt32, bandwidthHz: UInt32, spreadingFactor: Int, codingRate: Int, txPower: Int) {
            self.frequencyHz = frequencyHz
            self.bandwidthHz = bandwidthHz
            self.spreadingFactor = spreadingFactor
            self.codingRate = codingRate
            self.txPower = txPower
        }

        /// What the RNode reports, once all five are set (the coding rate too: Reticulum writes all five).
        public init?(_ p: RNode.RadioParameters) {
            guard let f = p.frequencyHz, let b = p.bandwidthHz, let sf = p.spreadingFactor, let cr = p.codingRate,
                  let tx = p.txPower else { return nil }
            self.init(frequencyHz: f, bandwidthHz: b, spreadingFactor: sf, codingRate: cr, txPower: tx)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frequencyHz = try c.decode(UInt32.self, forKey: .frequencyHz)
            bandwidthHz = try c.decode(UInt32.self, forKey: .bandwidthHz)
            spreadingFactor = try c.decode(Int.self, forKey: .spreadingFactor)
            codingRate = try c.decodeIfPresent(Int.self, forKey: .codingRate) ?? 5
            txPower = try c.decode(Int.self, forKey: .txPower)
        }

        /// The bridge's `rnode` object in a start command.
        public var command: [String: Int] {
            ["frequency": Int(frequencyHz), "bandwidth": Int(bandwidthHz), "txpower": txPower,
             "spreadingfactor": spreadingFactor, "codingrate": codingRate]
        }

        /// "914.875 MHz".
        public var frequencyText: String { RNode.mHzText(frequencyHz) + " MHz" }
        /// "914.875 MHz · 125 kHz · SF8 · CR 4/5 · 7 dBm".
        public var line: String {
            "\(frequencyText) · \(RNode.kHzText(bandwidthHz)) kHz · SF\(spreadingFactor) · CR 4/\(codingRate) · \(txPower) dBm"
        }

        public func problems(model: RNode.Model? = nil) -> [RNode.RadioParameters.Problem] {
            RNode.RadioParameters.problems(frequencyHz: frequencyHz, bandwidthHz: bandwidthHz, spreadingFactor: spreadingFactor,
                                           codingRate: codingRate, txPower: txPower, model: model)
        }
    }

    /// Where the settings for a start come from.
    public enum SettingsSource: Equatable, Sendable {
        /// What the RNode reports now: set in the RNode console (or by its last host).
        case rnode
        /// The RNode has none (it rebooted): the ones Reticulum last started with on this phone.
        case lastUsed

        public var note: String {
            switch self {
            case .rnode: return "As set on the RNode."
            case .lastUsed: return "The RNode has none set since it booted: these are from the last start."
            }
        }
    }

    /// The radio settings a start would use. The person's own, never a built-in default: what the
    /// RNode has now when all five are set, else what the last start used, else nothing (and the
    /// start is refused until they set the radio in the console).
    public static func settingsForStart(rnode: RNode.RadioParameters, lastUsed: RadioSettings?) -> (settings: RadioSettings, source: SettingsSource)? {
        if let now = RadioSettings(rnode) { return (now, .rnode) }
        if let lastUsed { return (lastUsed, .lastUsed) }
        return nil
    }

    // MARK: May it start?

    /// Why Reticulum can't start on this RNode. Each one is checked before the stack is asked,
    /// because Reticulum ends the whole process on some of them (an RNode firmware it refuses).
    public enum StartProblem: Error, Equatable, Sendable {
        case noRNode
        /// The RNode hasn't said which firmware it runs yet.
        case firmwareUnknown
        case firmwareTooOld(have: String)
        /// No radio settings: none set in the console, none kept from last time.
        case noSettings
        case settings([RNode.RadioParameters.Problem])

        public var line: String {
            let need = String(format: "%d.%02d", RNode.minimumFirmware.major, RNode.minimumFirmware.minor)
            switch self {
            case .noRNode:
                return "Connect an RNode first."
            case .firmwareUnknown:
                return "The RNode hasn't reported its firmware version yet. Wait a moment, or reconnect it."
            case .firmwareTooOld(let have):
                return "This RNode runs firmware \(have). Reticulum needs \(need) or newer: update it with rnodeconf on a computer."
            case .noSettings:
                return "Set the radio first: frequency, bandwidth, spreading factor, coding rate and TX power."
            case .settings(let problems):
                return problems.map(\.text).joined(separator: " ")
            }
        }
    }

    /// The first thing that stops Reticulum from starting on an RNode, or nil when it may.
    public static func startProblem(connected: Bool, device: RNode.DeviceInfo, settings: RadioSettings?) -> StartProblem? {
        guard connected else { return .noRNode }
        guard let current = device.firmwareIsCurrentEnough else { return .firmwareUnknown }
        guard current else { return .firmwareTooOld(have: device.firmwareVersion ?? "?") }
        guard let settings else { return .noSettings }
        let problems = settings.problems(model: device.model)
        return problems.isEmpty ? nil : .settings(problems)
    }
}

// MARK: - Internet link

extension Reticulum {
    /// A Reticulum node reached over the internet or the local network (RNS's TCP client
    /// interface): the address the person typed. Wildcat ships no addresses of its own.
    public struct InternetLink: Codable, Equatable, Sendable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        /// "example.org:4242"
        public var line: String { "\(host):\(port)" }
    }

    public enum InternetLinkProblem: Error, Equatable, Sendable {
        case noHost
        case badHost
        case badPort

        public var line: String {
            switch self {
            case .noHost: return "Type the address of a Reticulum node."
            case .badHost: return "That address doesn't look right. Use a name like node.example.org or numbers like 192.168.1.20."
            case .badPort: return "The port is a number from 1 to 65535. Reticulum nodes often use 4242."
            }
        }
    }

    /// Checks what was typed for an internet link. A "host:port" pasted into the host box is
    /// split, and its port wins. Only plain host names and IPv4 addresses: what goes into the
    /// Reticulum config must not be able to carry anything else.
    public static func internetLink(host typedHost: String, port typedPort: String) -> Result<InternetLink, InternetLinkProblem> {
        var host = typedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var port = typedPort.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["tcp://", "http://", "https://"] where host.hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        if host.hasSuffix("/") { host = String(host.dropLast()) }
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            host = String(parts[0])
            port = String(parts[1])
        } else if parts.count > 2 {
            return .failure(.badHost)
        }
        guard !host.isEmpty else { return .failure(.noHost) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, host.allSatisfy(allowed.contains),
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
            return .failure(.badHost)
        }
        guard port.count <= 5, !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(port), (1...65535).contains(number) else {
            return .failure(.badPort)
        }
        return .success(InternetLink(host: host, port: number))
    }

    /// What a start would use.
    public struct StartPlan: Equatable, Sendable {
        /// The RNode's radio settings, when the RNode takes part.
        public var radio: RadioSettings?
        public var internet: InternetLink?

        public init(radio: RadioSettings?, internet: InternetLink?) {
            self.radio = radio
            self.internet = internet
        }
    }

    /// What a start would use, or why it can't happen. A connected RNode always takes part, so a
    /// problem with it stops the start (never a silent start without the radio the person sees
    /// connected). With no RNode connected, the internet link alone is enough.
    public static func startPlan(rnodeConnected: Bool, device: RNode.DeviceInfo, settings: RadioSettings?,
                                 internet: InternetLink?) -> Result<StartPlan, StartProblem> {
        if rnodeConnected {
            if let problem = startProblem(connected: true, device: device, settings: settings) { return .failure(problem) }
            return .success(StartPlan(radio: settings, internet: internet))
        }
        guard let internet else { return .failure(.noRNode) }
        return .success(StartPlan(radio: nil, internet: internet))
    }
}
