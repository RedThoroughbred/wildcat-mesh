import Foundation

/// A Meshtastic node number and its "!9e766b18" form.
public struct NodeNum: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt32

    public static let broadcast = NodeNum(0xFFFF_FFFF)

    public init(_ raw: UInt32) { self.raw = raw }

    /// "!9e766b18" (case-insensitive, the leading "!" optional).
    public init?(id: String) {
        var s = Substring(id)
        if s.hasPrefix("!") { s = s.dropFirst() }
        guard s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        raw = v
    }

    public var id: String { "!" + String(format: "%08x", raw) }
    /// The last four hex digits, the Den's short form for a fox ("6b18").
    public var short: String { String(id.suffix(4)) }
    /// What `MeshPacket.relay_node` carries: the low byte of the relaying node.
    public var relayByte: UInt32 { raw & 0xFF }
    public var description: String { id }

    public static func < (a: NodeNum, b: NodeNum) -> Bool { a.raw < b.raw }
}

/// Saved as the bare number (`2742270231`), so saves stay small and readable.
extension NodeNum: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(UInt32.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

public enum PortNum: UInt32, Sendable {
    case unknown = 0
    case text = 1
    case position = 3
    case routing = 5
    case waypoint = 8
    case nodeInfo = 4
    case telemetry = 67
    case traceroute = 70
    /// PRIVATE_APP: app-defined payloads (Wildcat games, gifts).
    case privateApp = 256
}

/// The fields of a received MeshPacket that the games use.
public struct MeshPacket: Equatable, Sendable {
    public var from: NodeNum
    public var to: NodeNum
    public var channel: Int
    public var id: UInt32
    public var rxTime: Date?
    public var rxSNR: Float?
    /// nil when the radio did not measure it (0 on the wire).
    public var rxRSSI: Int?
    public var hopLimit: Int?
    public var hopStart: Int?
    public var viaMQTT: Bool
    /// Low byte of the node that last relayed the packet (0 = unknown).
    public var relayNode: UInt32?
    public var portnum: PortNum?
    public var rawPortnum: UInt32?
    public var text: String?
    public var position: Coordinate?
    /// True when this node could not decrypt it (no key for the channel).
    public var isEncrypted: Bool
    /// Data.request_id: the packet this one answers (acks, naks, replies to requests).
    public var requestID: UInt32?
    /// Data.reply_id: the message this one replies or reacts to.
    public var replyID: UInt32?
    /// Data.emoji: the text is a reaction (tapback) to `replyID`.
    public var isReaction: Bool = false
    /// For ROUTING_APP packets: the outcome of the packet `requestID`.
    public var routingError: RoutingError?
    public var wantAck: Bool = false
    /// Payload bytes of ports the app decodes itself (admin responses).
    public var payload: Data?
    /// TELEMETRY_APP device metrics.
    public var metrics: DeviceMetrics?
    /// NODEINFO_APP: the sender's User record (raw) and names.
    public var user: UserUpdate?
    /// TRACEROUTE_APP answer.
    public var route: Route?
    /// The MeshPacket as the radio handed it over (protobuf).
    public var raw: Data?
    /// Bytes of the encoded Data message: what's encrypted on air, after the 16-byte header.
    public var dataSize: Int?

    /// Estimated bytes on air: the 16-byte LoRa header plus the (encrypted) Data message.
    public var airSize: Int? { dataSize.map { MeshCodec.headerSize + $0 } }

    public init(from: NodeNum, to: NodeNum, channel: Int = 0, id: UInt32, rxTime: Date? = nil, rxSNR: Float? = nil,
                rxRSSI: Int? = nil, hopLimit: Int? = nil, hopStart: Int? = nil, viaMQTT: Bool = false,
                relayNode: UInt32? = nil, portnum: PortNum? = nil, rawPortnum: UInt32? = nil, text: String? = nil,
                position: Coordinate? = nil, isEncrypted: Bool = false) {
        self.from = from
        self.to = to
        self.channel = channel
        self.id = id
        self.rxTime = rxTime
        self.rxSNR = rxSNR
        self.rxRSSI = rxRSSI
        self.hopLimit = hopLimit
        self.hopStart = hopStart
        self.viaMQTT = viaMQTT
        self.relayNode = relayNode
        self.portnum = portnum
        self.rawPortnum = rawPortnum
        self.text = text
        self.position = position
        self.isEncrypted = isEncrypted
    }

    /// Hops travelled: hop_start − hop_limit, when both are known.
    public var hops: Int? {
        guard let s = hopStart, let l = hopLimit, s >= l else { return nil }
        return s - l
    }

    /// Heard straight off the air from the sender: 0 hops and not via MQTT.
    /// Only these samples measure the distance to the sender.
    public var isDirectRF: Bool { hops == 0 && !viaMQTT }

    public var isBroadcast: Bool { to == .broadcast }
}

/// Routing.Error: why a packet was (or wasn't) delivered.
public enum RoutingError: Int, Equatable, Sendable {
    case none = 0, noRoute = 1, gotNak = 2, timeout = 3, noInterface = 4, maxRetransmit = 5
    case noChannel = 6, tooLarge = 7, noResponse = 8, dutyCycleLimit = 9
    case badRequest = 32, notAuthorized = 33, pkiFailed = 34, pkiUnknownPublicKey = 35
    case adminBadSessionKey = 36, adminPublicKeyUnauthorized = 37, rateLimitExceeded = 38
    case other = -1

    public var isSuccess: Bool { self == .none }

    public var explanation: String {
        switch self {
        case .none: return "Delivered"
        case .noRoute: return "No route to that node"
        case .gotNak: return "Refused by the recipient"
        case .timeout: return "Timed out"
        case .noInterface: return "No radio to send on"
        case .maxRetransmit: return "Nobody acknowledged it"
        case .noChannel: return "The recipient doesn't have this channel"
        case .tooLarge: return "Too long for one packet"
        case .noResponse: return "No response"
        case .dutyCycleLimit: return "Held back by the radio's airtime limit"
        case .badRequest: return "Bad request"
        case .notAuthorized: return "Not authorized"
        case .pkiFailed: return "Direct-message encryption failed"
        case .pkiUnknownPublicKey: return "The recipient's key isn't known yet"
        case .adminBadSessionKey: return "Admin session expired"
        case .adminPublicKeyUnauthorized: return "This phone isn't an admin for that node"
        case .rateLimitExceeded: return "Sending too fast"
        case .other: return "Not delivered"
        }
    }
}

public struct Coordinate: Equatable, Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct NodeInfo: Equatable, Sendable {
    public var num: NodeNum
    public var userID: String?
    public var longName: String?
    public var shortName: String?
    public var snr: Float?
    /// The User record as sent (for editing our own owner fields).
    public var userRaw: Data?
    public var hwModel: Int?
    public var role: Int?
    public var position: Coordinate?
    public var altitude: Int?
    public var positionTime: Date?
    public var metrics: DeviceMetrics?
    public var lastHeard: Date?
    public var hopsAway: Int?
    public var viaMQTT: Bool = false
    public var isFavorite: Bool = false
    public var isIgnored: Bool = false
    /// Our channel index this node was last heard on (NodeInfo.channel, or live traffic).
    public var channel: Int?

    public var hardware: String? { HardwareNames.name(hwModel) }

    public init(num: NodeNum, userID: String? = nil, longName: String? = nil, shortName: String? = nil, snr: Float? = nil,
                userRaw: Data? = nil) {
        self.num = num
        self.userID = userID
        self.longName = longName
        self.shortName = shortName
        self.snr = snr
        self.userRaw = userRaw
    }
}

public struct ChannelInfo: Equatable, Sendable {
    public enum Role: UInt32, Sendable { case disabled = 0, primary = 1, secondary = 2 }
    public var index: Int
    public var name: String
    public var role: Role
    /// The full ChannelSettings bytes (key included), for editing and sharing.
    public var settings: Data?

    public init(index: Int, name: String, role: Role, settings: Data? = nil) {
        self.index = index
        self.name = name
        self.role = role
        self.settings = settings
    }
}

/// One FromRadio frame (a node sends one per BLE read).
public enum FromRadio: Equatable, Sendable {
    case packet(MeshPacket)
    case myInfo(NodeNum)
    case nodeInfo(NodeInfo)
    case channel(ChannelInfo)
    case configComplete(UInt32)
    /// A Config section (its oneof number and bytes).
    case config(ConfigSection, Data)
    case moduleConfig(ModuleSection, Data)
    case metadata(firmware: String?)
    /// Anything else (config, metadata, log records, …).
    case other
}

/// Encoding and decoding of the Meshtastic phone API (`FromRadio` /
/// `ToRadio`) for the fields the games need.
public enum MeshCodec {
    // FromRadio: id 1, packet 2, my_info 3, node_info 4, config_complete_id 7, channel 10.
    public static func decodeFromRadio(_ data: Data) throws -> FromRadio {
        let m = try Proto.Message(data)
        if let p = m.bytes(2) { return .packet(try decodePacket(p)) }
        if let info = m.message(3), let num = info.uint32(1) { return .myInfo(NodeNum(num)) }
        if let n = m.message(4), let num = n.uint32(1) {
            let user = n.message(2)
            var info = NodeInfo(num: NodeNum(num), userID: user?.string(1), longName: user?.string(2),
                                shortName: user?.string(3), snr: n.float(4), userRaw: n.bytes(2))
            info.hwModel = user?.uint32(5).map(Int.init)
            info.role = user?.uint32(7).map(Int.init)
            let pos = n.message(3)
            info.position = coordinate(pos)
            info.altitude = pos?.int32(3).map(Int.init)
            info.positionTime = pos?.uint32(4).flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0)) }
            info.metrics = DeviceMetrics(n.message(6))
            info.lastHeard = n.uint32(5).flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0)) }
            info.hopsAway = n.uint32(9).map(Int.init)
            info.viaMQTT = n.bool(8) ?? false
            info.isFavorite = n.bool(10) ?? false
            info.isIgnored = n.bool(11) ?? false
            info.channel = n.uint32(7).map(Int.init)
            return .nodeInfo(info)
        }
        if let c = m.message(10) {
            return .channel(ChannelInfo(index: Int(c.uint32(1) ?? 0),
                                        name: c.message(2)?.string(3) ?? "",
                                        role: ChannelInfo.Role(rawValue: c.uint32(3) ?? 0) ?? .disabled,
                                        settings: c.bytes(2)))
        }
        if let cfg = m.message(5), let (n, v) = cfg.fields.last, let section = ConfigSection(rawValue: n),
           case .bytes(let inner) = v {
            return .config(section, inner)
        }
        if let cfg = m.message(9), let (n, v) = cfg.fields.last, let section = ModuleSection(rawValue: n),
           case .bytes(let inner) = v {
            return .moduleConfig(section, inner)
        }
        if let md = m.message(13) { return .metadata(firmware: md.string(1)) }
        if let id = m.uint32(7) { return .configComplete(id) }
        return .other
    }

    // MeshPacket: from 1, to 2, channel 3, decoded 4, encrypted 5, id 6, rx_time 7,
    // rx_snr 8, hop_limit 9, want_ack 10, rx_rssi 12, via_mqtt 14, hop_start 15, relay_node 19.
    public static func decodePacket(_ data: Data) throws -> MeshPacket {
        let m = try Proto.Message(data)
        let rssi = m.int32(12).map(Int.init)
        let wantAck = m.bool(10) ?? false
        var packet = MeshPacket(
            from: NodeNum(m.uint32(1) ?? 0),
            to: NodeNum(m.uint32(2) ?? 0),
            channel: Int(m.uint32(3) ?? 0),
            id: m.uint32(6) ?? 0,
            rxTime: m.uint32(7).flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0)) },
            rxSNR: m.float(8),
            rxRSSI: rssi == 0 ? nil : rssi,
            hopLimit: m.uint32(9).map(Int.init) ?? 0,
            hopStart: m.uint32(15).map(Int.init),
            viaMQTT: m.bool(14) ?? false,
            relayNode: m.uint32(19),
            portnum: nil, rawPortnum: nil, text: nil, position: nil,
            isEncrypted: false)
        packet.raw = data
        packet.dataSize = m.bytes(4)?.count ?? m.bytes(5)?.count
        if let decoded = m.message(4) {
            // Data: portnum 1, payload 2.
            let port = decoded.uint32(1) ?? 0
            packet.wantAck = wantAck
            packet.requestID = decoded.uint32(6).flatMap { $0 == 0 ? nil : $0 }
            packet.replyID = decoded.uint32(7).flatMap { $0 == 0 ? nil : $0 }
            packet.isReaction = (decoded.uint32(8) ?? 0) != 0
            packet.rawPortnum = port
            packet.portnum = PortNum(rawValue: port)
            let payload = decoded.bytes(2) ?? Data()
            if port == Admin.portnum || port == PortNum.privateApp.rawValue { packet.payload = payload }
            switch packet.portnum {
            case .text:
                packet.text = String(decoding: payload, as: UTF8.self)
            case .routing:
                // Routing: route_request 1, route_reply 2, error_reason 3 (oneof).
                if let r = try? Proto.Message(payload) {
                    if let e = r.uint32(3) {
                        packet.routingError = RoutingError(rawValue: Int(e)) ?? .other
                    } else if r.last(1) == nil && r.last(2) == nil {
                        packet.routingError = RoutingError.none
                    }
                }
            case .position:
                // Position: latitude_i 1, longitude_i 2 (sfixed32, 1e-7 degrees).
                packet.position = coordinate(try? Proto.Message(payload))
            case .telemetry:
                packet.metrics = DeviceMetrics((try? Proto.Message(payload))?.message(2))
            case .nodeInfo:
                if let u = try? Proto.Message(payload) {
                    packet.user = UserUpdate(raw: payload, longName: u.string(2), shortName: u.string(3),
                                             hwModel: u.uint32(5).map(Int.init))
                }
            case .traceroute:
                if let r = try? Proto.Message(payload) { packet.route = route(r) }
            default:
                break
            }
        } else {
            packet.isEncrypted = m.bytes(5) != nil
        }
        return packet
    }

    // ToRadio: packet 1, want_config_id 3, heartbeat 7.
    public static func wantConfig(id: UInt32) -> Data {
        var w = Proto.Writer()
        w.uint(3, UInt64(id))
        return w.data
    }

    public static func heartbeat() -> Data {
        var w = Proto.Writer()
        w.message(7) { _ in }
        return w.data
    }

    /// A text message. With `wantAck` (the default, as the Meshtastic apps
    /// send) a direct message gets an ack from its recipient and a channel
    /// message an implicit ack when a neighbour rebroadcasts it. `replyID`
    /// makes it a reply; with `isReaction` the text is an emoji tapback.
    /// The over-the-air packet header (to, from, id, flags, channel hash, next hop, relay node).
    public static let headerSize = 16

    /// Bytes of the Data message `textPacket` makes for this text (for size and airtime).
    public static func textDataSize(_ text: String, replyID: UInt32? = nil, isReaction: Bool = false) -> Int {
        var d = Proto.Writer()
        d.uint(1, UInt64(PortNum.text.rawValue))
        d.bytes(2, Data(text.utf8))
        if let replyID { d.fixed32(7, replyID) }
        if isReaction { d.fixed32(8, 1) }
        return d.data.count
    }

    public static func textPacket(_ text: String, to: NodeNum = .broadcast, channel: Int = 0, id: UInt32,
                                  wantAck: Bool = true, replyID: UInt32? = nil, isReaction: Bool = false) -> Data {
        var w = Proto.Writer()
        w.message(1) { p in
            p.fixed32(2, to.raw)
            if channel != 0 { p.uint(3, UInt64(channel)) }
            p.message(4) { d in
                d.uint(1, UInt64(PortNum.text.rawValue))
                d.bytes(2, Data(text.utf8))
                if let replyID { d.fixed32(7, replyID) }
                if isReaction { d.fixed32(8, 1) }
            }
            p.fixed32(6, id)
            if wantAck { p.bool(10, true) }
        }
        return w.data
    }

    /// A position broadcast (POSITION_APP). With `coordinate` nil it carries
    /// only the time: the packet still goes over the air, so receivers can
    /// measure the link, without revealing where the sender is.
    public static func positionPacket(coordinate: Coordinate? = nil, altitude: Int? = nil, time: Date,
                                      to: NodeNum = .broadcast, channel: Int = 0, id: UInt32) -> Data {
        var w = Proto.Writer()
        w.message(1) { p in
            p.fixed32(2, to.raw)
            if channel != 0 { p.uint(3, UInt64(channel)) }
            p.message(4) { d in
                d.uint(1, UInt64(PortNum.position.rawValue))
                var pos = Proto.Writer()
                if let c = coordinate {
                    // Position: latitude_i 1, longitude_i 2 (sfixed32, 1e-7 degrees), altitude 3, time 4.
                    pos.fixed32(1, UInt32(bitPattern: Int32((c.latitude * 1e7).rounded())))
                    pos.fixed32(2, UInt32(bitPattern: Int32((c.longitude * 1e7).rounded())))
                }
                if let altitude { pos.int32(3, Int32(altitude)) }
                pos.fixed32(4, UInt32(max(0, time.timeIntervalSince1970)))
                d.bytes(2, pos.data)
            }
            p.fixed32(6, id)
        }
        return w.data
    }

    /// An app-defined packet (PRIVATE_APP) that other Meshtastic apps ignore.
    public static func privatePacket(_ payload: Data, to: NodeNum = .broadcast, channel: Int = 0, id: UInt32,
                                     wantAck: Bool = true) -> Data {
        var w = Proto.Writer()
        w.message(1) { p in
            p.fixed32(2, to.raw)
            if channel != 0 { p.uint(3, UInt64(channel)) }
            p.message(4) { d in
                d.uint(1, UInt64(PortNum.privateApp.rawValue))
                d.bytes(2, payload)
            }
            p.fixed32(6, id)
            if wantAck { p.bool(10, true) }
        }
        return w.data
    }

    /// A traceroute request to `to` (TRACEROUTE_APP, want_response). The
    /// node answers by itself; nothing is shown to its owner. Use sparingly:
    /// it costs airtime both ways.
    public static func traceroutePacket(to: NodeNum, channel: Int = 0, id: UInt32) -> Data {
        var w = Proto.Writer()
        w.message(1) { p in
            p.fixed32(2, to.raw)
            if channel != 0 { p.uint(3, UInt64(channel)) }
            p.message(4) { d in
                d.uint(1, UInt64(PortNum.traceroute.rawValue))
                d.bool(3, true)   // want_response
            }
            p.fixed32(6, id)
        }
        return w.data
    }

    /// Meshtastic's text limit (bytes of UTF-8).
    public static let maxTextBytes = 200

    /// A random, non-zero packet id.
    public static func newPacketID() -> UInt32 { UInt32.random(in: 1...0x7FFF_FFFF) }
}
