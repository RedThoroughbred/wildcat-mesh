import Foundation

// Node settings over the phone API (AdminMessage, portnum ADMIN_APP = 6).
// Field numbers are from meshtastic/protobufs admin.proto / config.proto /
// channel.proto / apponly.proto; tests compare against the official encoder.

extension Proto {
    /// Rewrites a message, replacing (or removing, with nil) the given fields
    /// and keeping every other field byte for byte. Fields come out in field
    /// number order, as the official encoders write them. Proto3 defaults
    /// (0, false, empty) remove the field.
    public static func patch(_ original: Data, _ changes: [Int: Value?]) -> Data {
        var fields = (try? Proto.fields(original)) ?? []
        fields.removeAll { changes.keys.contains($0.0) }
        for (n, v) in changes {
            guard let v, !isDefault(v) else { continue }
            fields.append((n, v))
        }
        // Stable sort keeps repeated fields in their original order.
        let ordered = fields.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element)
        var w = Writer()
        for (n, v) in ordered { w.value(n, v) }
        return w.data
    }

    static func isDefault(_ v: Value) -> Bool {
        switch v {
        case .varint(let x): return x == 0
        case .fixed32(let x): return x == 0
        case .fixed64(let x): return x == 0
        case .bytes(let d): return d.isEmpty
        }
    }

    public static func varint(_ b: Bool) -> Value { .varint(b ? 1 : 0) }
    public static func varint(_ i: Int) -> Value { .varint(UInt64(bitPattern: Int64(i))) }
    public static func string(_ s: String) -> Value { .bytes(Data(s.utf8)) }
}

extension Proto.Writer {
    mutating func value(_ field: Int, _ v: Proto.Value) {
        switch v {
        case .varint(let x): uint(field, x)
        case .fixed32(let x): fixed32(field, x)
        case .fixed64(let x):
            key(field, 1)
            withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) }
        case .bytes(let d): bytes(field, d)
        }
    }
}

/// The node's configuration sections as received (Config oneof numbers).
public enum ConfigSection: Int, CaseIterable, Sendable {
    case device = 1, position = 2, power = 3, network = 4, display = 5, lora = 6, bluetooth = 7, security = 8
}

/// ModuleConfig oneof field numbers.
public enum ModuleSection: Int, CaseIterable, Sendable {
    case mqtt = 1, serial = 2, externalNotification = 3, storeForward = 4, rangeTest = 5, telemetry = 6
    case cannedMessage = 7, audio = 8, remoteHardware = 9, neighborInfo = 10, ambientLighting = 11
    case detectionSensor = 12, paxcounter = 13, statusMessage = 14, trafficManagement = 15, tak = 16
}

public enum Region: Int, CaseIterable, Identifiable, Sendable {
    case unset = 0, us = 1, eu433 = 2, eu868 = 3, cn = 4, jp = 5, anz = 6, kr = 7, tw = 8, ru = 9, india = 10
    case nz865 = 11, th = 12, lora24 = 13, ua433 = 14, ua868 = 15, my433 = 16, my919 = 17, sg923 = 18
    case ph433 = 19, ph868 = 20, ph915 = 21, anz433 = 22, kz433 = 23, kz863 = 24, np865 = 25, br902 = 26

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .unset: return "Not set"
        case .us: return "United States (915 MHz)"
        case .eu433: return "Europe 433 MHz"
        case .eu868: return "Europe 868 MHz"
        case .cn: return "China"
        case .jp: return "Japan"
        case .anz: return "Australia / New Zealand 915"
        case .kr: return "Korea"
        case .tw: return "Taiwan"
        case .ru: return "Russia"
        case .india: return "India"
        case .nz865: return "New Zealand 865"
        case .th: return "Thailand"
        case .lora24: return "2.4 GHz (worldwide)"
        case .ua433: return "Ukraine 433"
        case .ua868: return "Ukraine 868"
        case .my433: return "Malaysia 433"
        case .my919: return "Malaysia 919"
        case .sg923: return "Singapore"
        case .ph433: return "Philippines 433"
        case .ph868: return "Philippines 868"
        case .ph915: return "Philippines 915"
        case .anz433: return "Australia / New Zealand 433"
        case .kz433: return "Kazakhstan 433"
        case .kz863: return "Kazakhstan 863"
        case .np865: return "Nepal"
        case .br902: return "Brazil"
        }
    }

    /// A sensible default for the phone's region code.
    public static func guess(regionCode: String?) -> Region {
        switch regionCode?.uppercased() {
        case "US", "CA", "MX": return .us
        case "GB", "IE", "DE", "FR", "NL", "BE", "IT", "ES", "PT", "AT", "CH", "SE", "NO", "DK", "FI", "PL", "CZ": return .eu868
        case "AU", "NZ": return .anz
        case "JP": return .jp
        case "KR": return .kr
        case "TW": return .tw
        case "IN": return .india
        case "BR": return .br902
        default: return .unset
        }
    }
}

public enum ModemPreset: Int, CaseIterable, Identifiable, Sendable {
    case longFast = 0, longSlow = 1, veryLongSlow = 2, mediumSlow = 3, mediumFast = 4, shortSlow = 5, shortFast = 6
    case longModerate = 7, shortTurbo = 8, longTurbo = 9

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .longFast: return "Long Fast (default)"
        case .longSlow: return "Long Slow"
        case .veryLongSlow: return "Very Long Slow"
        case .mediumSlow: return "Medium Slow"
        case .mediumFast: return "Medium Fast"
        case .shortSlow: return "Short Slow"
        case .shortFast: return "Short Fast"
        case .longModerate: return "Long Moderate"
        case .shortTurbo: return "Short Turbo"
        case .longTurbo: return "Long Turbo"
        }
    }
}

public enum DeviceRole: Int, CaseIterable, Identifiable, Sendable {
    case client = 0, clientMute = 1, router = 2, repeater = 4, tracker = 5, sensor = 6, tak = 7
    case clientHidden = 8, lostAndFound = 9, takTracker = 10, routerLate = 11, clientBase = 12

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .client: return "Client"
        case .clientMute: return "Client (mute)"
        case .router: return "Router"
        case .repeater: return "Repeater"
        case .tracker: return "Tracker"
        case .sensor: return "Sensor"
        case .tak: return "TAK"
        case .clientHidden: return "Client (hidden)"
        case .lostAndFound: return "Lost & Found"
        case .takTracker: return "TAK Tracker"
        case .routerLate: return "Router (late)"
        case .clientBase: return "Client Base"
        }
    }
    public var detail: String {
        switch self {
        case .client: return "Normal node you carry and message from. Relays when useful."
        case .clientMute: return "Talks and listens but never relays. Good for a second node near another."
        case .router: return "Infrastructure on a high, fixed spot. Always relays. Not for handhelds."
        case .repeater: return "Relays only, invisible in node lists."
        case .tracker: return "Sends its position often; sleeps otherwise."
        case .sensor: return "Sends telemetry often; sleeps otherwise."
        case .tak: return "For ATAK users."
        case .clientHidden: return "Only speaks when needed; hides from node lists."
        case .lostAndFound: return "Broadcasts its location to help find it."
        case .takTracker: return "ATAK tracker."
        case .routerLate: return "Relays after everyone else, to fill gaps."
        case .clientBase: return "Home base for your own nodes; relays their traffic first."
        }
    }
}

/// Views over the raw sections, for the settings screens.
public struct LoRaSettings: Equatable, Sendable {
    public var raw: Data
    public var usePreset: Bool
    public var preset: ModemPreset
    public var region: Region
    public var hopLimit: Int
    public var txEnabled: Bool
    /// dBm; 0 means the board's default maximum.
    public var txPower: Int

    public init(raw: Data) {
        self.raw = raw
        let m = try? Proto.Message(raw)
        usePreset = m?.bool(1) ?? false
        preset = ModemPreset(rawValue: Int(m?.uint32(2) ?? 0)) ?? .longFast
        region = Region(rawValue: Int(m?.uint32(7) ?? 0)) ?? .unset
        hopLimit = Int(m?.uint32(8) ?? 0)
        txEnabled = m?.bool(9) ?? false
        txPower = Int(m?.int32(10) ?? 0)
    }

    /// Spreading factor, bandwidth (kHz) and coding rate (5-8) in use, for airtime estimates.
    public var modem: (spreadingFactor: Int, bandwidthKHz: Double, codingRate: Int)? {
        if !usePreset {
            // Custom: bandwidth 3, spread_factor 4, coding_rate 5.
            let m = try? Proto.Message(raw)
            let bw = Int(m?.uint32(3) ?? 0), sf = Int(m?.uint32(4) ?? 0), cr = Int(m?.uint32(5) ?? 0)
            // The firmware's shorthand for the fractional bandwidths.
            let khz = [31: 31.25, 62: 62.5, 200: 203.125, 400: 406.25, 800: 812.5, 1600: 1625][bw] ?? Double(bw)
            guard sf > 0, khz > 0, cr > 0 else { return nil }
            return (sf, khz, cr)
        }
        switch preset {
        case .shortTurbo: return (7, 500, 5)
        case .shortFast: return (7, 250, 5)
        case .shortSlow: return (8, 250, 5)
        case .mediumFast: return (9, 250, 5)
        case .mediumSlow: return (10, 250, 5)
        case .longFast: return (11, 250, 5)
        case .longTurbo: return (11, 500, 5)
        case .longModerate: return (11, 125, 8)
        case .longSlow: return (12, 125, 8)
        case .veryLongSlow: return (12, 62.5, 8)
        }
    }

    /// Estimated time on air for a packet of `bytes` with these settings.
    public func airtime(bytes: Int) -> Int? {
        guard let m = modem else { return nil }
        return LoRaAirtime.milliseconds(bytes: bytes, spreadingFactor: m.spreadingFactor, bandwidthKHz: m.bandwidthKHz,
                                        codingRate: m.codingRate)
    }

    /// The raw section with this view's editable fields applied.
    public var patched: Data {
        Proto.patch(raw, [1: Proto.varint(usePreset), 2: Proto.varint(preset.rawValue), 7: Proto.varint(region.rawValue),
                          8: Proto.varint(hopLimit), 9: Proto.varint(txEnabled), 10: Proto.varint(txPower)])
    }
}

public struct DeviceSettings: Equatable, Sendable {
    public var raw: Data
    public var role: DeviceRole

    public init(raw: Data) {
        self.raw = raw
        role = DeviceRole(rawValue: Int((try? Proto.Message(raw))?.uint32(1) ?? 0)) ?? .client
    }

    public var patched: Data { Proto.patch(raw, [1: Proto.varint(role.rawValue)]) }
}

public struct PositionSettings: Equatable, Sendable {
    public var raw: Data
    /// Seconds between position broadcasts (0 = firmware default).
    public var broadcastSecs: Int
    public var smart: Bool
    public var fixed: Bool
    public var gpsMode: GPSMode

    public enum GPSMode: Int, Sendable { case disabled = 0, enabled = 1, notPresent = 2 }

    public init(raw: Data) {
        self.raw = raw
        let m = try? Proto.Message(raw)
        broadcastSecs = Int(m?.uint32(1) ?? 0)
        smart = m?.bool(2) ?? false
        fixed = m?.bool(3) ?? false
        gpsMode = GPSMode(rawValue: Int(m?.uint32(13) ?? 0)) ?? .disabled
    }

    public var patched: Data {
        Proto.patch(raw, [1: Proto.varint(broadcastSecs), 2: Proto.varint(smart), 3: Proto.varint(fixed),
                          13: Proto.varint(gpsMode.rawValue)])
    }
}

/// ModuleConfig.TelemetryConfig: the device-metrics broadcast.
public struct TelemetrySettings: Equatable, Sendable {
    public var raw: Data
    /// Seconds between device-metrics broadcasts (0 = firmware default).
    public var deviceUpdateSecs: Int
    /// Firmware 2.7+: send device metrics to the mesh at all.
    public var deviceTelemetryEnabled: Bool

    public init(raw: Data) {
        self.raw = raw
        let m = try? Proto.Message(raw)
        deviceUpdateSecs = Int(m?.uint32(1) ?? 0)
        deviceTelemetryEnabled = m?.bool(14) ?? false
    }

    public var patched: Data {
        Proto.patch(raw, [1: Proto.varint(deviceUpdateSecs), 14: Proto.varint(deviceTelemetryEnabled)])
    }
}

/// ModuleConfig.ExternalNotificationConfig: beep or blink on incoming messages.
public struct ExternalNotificationSettings: Equatable, Sendable {
    public var raw: Data
    public var enabled: Bool
    /// How long each alert lasts, in milliseconds.
    public var outputMs: Int
    public var alertMessage: Bool
    public var alertMessageBuzzer: Bool
    public var usePWM: Bool

    public init(raw: Data) {
        self.raw = raw
        let m = try? Proto.Message(raw)
        enabled = m?.bool(1) ?? false
        outputMs = Int(m?.uint32(2) ?? 0)
        alertMessage = m?.bool(5) ?? false
        alertMessageBuzzer = m?.bool(11) ?? false
        usePWM = m?.bool(7) ?? false
    }

    public var patched: Data {
        Proto.patch(raw, [1: Proto.varint(enabled), 2: Proto.varint(outputMs), 5: Proto.varint(alertMessage),
                          7: Proto.varint(usePWM), 11: Proto.varint(alertMessageBuzzer)])
    }
}

/// ModuleConfig.StoreForwardConfig: hold messages for nodes that were away.
public struct StoreForwardSettings: Equatable, Sendable {
    public var raw: Data
    public var enabled: Bool
    public var isServer: Bool

    public init(raw: Data) {
        self.raw = raw
        let m = try? Proto.Message(raw)
        enabled = m?.bool(1) ?? false
        isServer = m?.bool(6) ?? false
    }

    public var patched: Data {
        Proto.patch(raw, [1: Proto.varint(enabled), 6: Proto.varint(isServer)])
    }
}

public struct Owner: Equatable, Sendable {
    public var raw: Data
    public var longName: String
    public var shortName: String

    public init(raw: Data) {
        self.raw = raw
        let m = try? Proto.Message(raw)
        longName = m?.string(2) ?? ""
        shortName = m?.string(3) ?? ""
    }

    public var patched: Data { Proto.patch(raw, [2: Proto.string(longName), 3: Proto.string(shortName)]) }
}

/// One channel's full settings (ChannelSettings), for editing and sharing.
public struct ChannelSettings: Equatable, Sendable {
    public var raw: Data
    public var name: String
    public var psk: Data

    public init(raw: Data) {
        self.raw = raw
        let m = try? Proto.Message(raw)
        name = m?.string(3) ?? ""
        psk = m?.bytes(2) ?? Data()
    }

    public init(name: String, psk: Data) {
        self.init(raw: Proto.patch(Data(), [2: .bytes(psk), 3: Proto.string(name)]))
    }

    public var patched: Data { Proto.patch(raw, [2: .bytes(psk), 3: Proto.string(name)]) }

    /// A fresh random 256-bit key for a private channel.
    public static func randomKey() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    /// "default" (the well-known key), "none", or "private".
    public var keyKind: String {
        if psk.isEmpty { return "none" }
        if psk.count == 1 { return psk[0] == 0 ? "none" : "default" }
        return "private"
    }
}

/// Wildcat's own channel links: wildcat://channel#<base64url ChannelSet>
/// (with `?add=true` to add instead of replacing). Meshtastic's own link
/// format (meshtastic.org/e/) is theirs to use, not ours: Wildcat neither
/// makes nor reads it (Meshtastic LLC's request, 2026-11-25).
public struct ChannelLink: Equatable, Sendable {
    public static let prefix = "wildcat://channel"
    public var channels: [ChannelSettings]
    /// The LoRa settings the link carries (region, preset), raw.
    public var lora: Data?
    public var add: Bool

    public init(channels: [ChannelSettings], lora: Data?, add: Bool) {
        self.channels = channels
        self.lora = lora
        self.add = add
    }

    public init?(url: String) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = url.range(of: "#") else { return nil }
        let prefix = url[..<hash.lowerBound].lowercased()
        guard prefix.hasPrefix(Self.prefix) else { return nil }
        var b64 = String(url[hash.upperBound...]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let m = try? Proto.Message(data) else { return nil }
        channels = m.fields.filter { $0.0 == 1 }.compactMap { if case .bytes(let d) = $0.1 { return ChannelSettings(raw: d) } else { return nil } }
        lora = m.bytes(2)
        add = prefix.contains("add=true")
        guard !channels.isEmpty else { return nil }
    }

    public var url: String {
        var w = Proto.Writer()
        for c in channels { w.bytes(1, c.raw) }
        if let lora { w.bytes(2, lora) }
        let b64 = w.data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Self.prefix + (add ? "?add=true" : "") + "#" + b64
    }
}

/// AdminMessage builders. Every set carries the session passkey the node
/// handed out in its last admin response (firmware 2.5+ requires it).
public enum Admin {
    public static let portnum: UInt32 = 6

    /// A ToRadio carrying `admin` to our own node.
    static func packet(to node: NodeNum, id: UInt32, wantResponse: Bool, _ admin: (inout Proto.Writer) -> Void) -> Data {
        var w = Proto.Writer()
        w.message(1) { p in
            p.fixed32(2, node.raw)
            p.message(4) { d in
                d.uint(1, UInt64(portnum))
                d.message(2, admin)
                if wantResponse { d.bool(3, true) }
            }
            p.fixed32(6, id)
        }
        return w.data
    }

    /// Asks for the owner; the answer carries a fresh session passkey.
    public static func getOwner(node: NodeNum, id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: true) { $0.bool(3, true) }
    }

    public static func beginEdit(node: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: false) { a in a.bool(64, true); a.bytes(101, passkey) }
    }

    public static func commitEdit(node: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: false) { a in a.bool(65, true); a.bytes(101, passkey) }
    }

    public static func reboot(node: NodeNum, seconds: Int = 5, passkey: Data, id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: false) { a in a.int32(97, Int32(seconds)); a.bytes(101, passkey) }
    }

    public static func setOwner(_ user: Data, node: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: false) { a in a.bytes(32, user); a.bytes(101, passkey) }
    }

    public static func setConfig(_ section: ConfigSection, _ inner: Data, node: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: false) { a in
            a.message(34) { $0.bytes(section.rawValue, inner) }
            a.bytes(101, passkey)
        }
    }

    public static func setModuleConfig(_ section: ModuleSection, _ inner: Data, node: NodeNum, passkey: Data,
                                       id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: false) { a in
            a.message(35) { $0.bytes(section.rawValue, inner) }
            a.bytes(101, passkey)
        }
    }

    /// Sets channel `index`; nil settings (with role disabled) removes it.
    public static func setChannel(index: Int, settings: Data?, role: ChannelInfo.Role, node: NodeNum,
                                  passkey: Data, id: UInt32) -> Data {
        packet(to: node, id: id, wantResponse: false) { a in
            a.message(33) { c in
                if index != 0 { c.uint(1, UInt64(index)) }
                if let settings { c.bytes(2, settings) }
                if role != .disabled { c.uint(3, UInt64(role.rawValue)) }
            }
            a.bytes(101, passkey)
        }
    }

    /// An admin response from the node: its passkey and what it answered.
    public struct Response: Equatable, Sendable {
        public var passkey: Data?
        public var owner: Data?
    }

    public static func response(_ packet: MeshPacket, payload: Data) -> Response? {
        guard let m = try? Proto.Message(payload) else { return nil }
        return Response(passkey: m.bytes(101), owner: m.bytes(4))
    }
}
