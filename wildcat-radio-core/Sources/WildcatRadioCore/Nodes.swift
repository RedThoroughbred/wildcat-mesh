import Foundation

/// DeviceMetrics (telemetry.proto): battery 1, voltage 2, channel util 3, air util tx 4, uptime 5.
public struct DeviceMetrics: Equatable, Sendable {
    /// Percent; 101 means powered (no battery or charging).
    public var batteryLevel: Int?
    public var voltage: Double?
    public var channelUtilization: Double?
    public var airUtilTx: Double?
    public var uptime: Int?

    public var isPowered: Bool { (batteryLevel ?? 0) > 100 }

    init?(_ m: Proto.Message?) {
        guard let m else { return nil }
        batteryLevel = m.uint32(1).map(Int.init)
        voltage = m.float(2).map(Double.init)
        channelUtilization = m.float(3).map(Double.init)
        airUtilTx = m.float(4).map(Double.init)
        uptime = m.uint32(5).map(Int.init)
    }

    public init(batteryLevel: Int? = nil, voltage: Double? = nil, channelUtilization: Double? = nil,
                airUtilTx: Double? = nil, uptime: Int? = nil) {
        self.batteryLevel = batteryLevel
        self.voltage = voltage
        self.channelUtilization = channelUtilization
        self.airUtilTx = airUtilTx
        self.uptime = uptime
    }
}

/// A traceroute answer: the path out and back, with the SNR of each hop.
public struct Route: Equatable, Sendable {
    public var towards: [NodeNum]
    /// dB per hop towards the destination (one more than `towards`).
    public var snrTowards: [Double]
    public var back: [NodeNum]
    public var snrBack: [Double]
}

extension Proto.Message {
    /// A packed (or repeated) fixed32 field.
    func repeatedFixed32(_ n: Int) -> [UInt32] {
        fields.filter { $0.0 == n }.flatMap { f -> [UInt32] in
            switch f.1 {
            case .fixed32(let v): return [v]
            case .bytes(let d):
                let b = [UInt8](d)
                return stride(from: 0, to: b.count - 3, by: 4).map {
                    UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24
                }
            default: return []
            }
        }
    }

    /// A packed (or repeated) int32 field.
    func repeatedInt32(_ n: Int) -> [Int32] {
        fields.filter { $0.0 == n }.flatMap { f -> [Int32] in
            switch f.1 {
            case .varint(let v): return [Int32(truncatingIfNeeded: v)]
            case .bytes(let d):
                let b = [UInt8](d)
                var i = 0
                var out: [Int32] = []
                while i < b.count, let v = try? Proto.readVarint(b, &i) { out.append(Int32(truncatingIfNeeded: v)) }
                return out
            default: return []
            }
        }
    }
}

extension MeshCodec {
    static func coordinate(_ pos: Proto.Message?) -> Coordinate? {
        guard let pos, let la = pos.int32(1), let lo = pos.int32(2), la != 0 || lo != 0 else { return nil }
        return Coordinate(latitude: Double(la) / 1e7, longitude: Double(lo) / 1e7)
    }

    static func route(_ m: Proto.Message) -> Route {
        Route(towards: m.repeatedFixed32(1).map(NodeNum.init), snrTowards: m.repeatedInt32(2).map { Double($0) / 4 },
              back: m.repeatedFixed32(3).map(NodeNum.init), snrBack: m.repeatedInt32(4).map { Double($0) / 4 })
    }
}

extension Admin {
    public static func setFavorite(_ node: NodeNum, _ on: Bool, me: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: me, id: id, wantResponse: false) { a in a.uint(on ? 39 : 40, UInt64(node.raw)); a.bytes(101, passkey) }
    }

    public static func setIgnored(_ node: NodeNum, _ on: Bool, me: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: me, id: id, wantResponse: false) { a in a.uint(on ? 47 : 48, UInt64(node.raw)); a.bytes(101, passkey) }
    }

    /// Sets the node's fixed position (and turns fixed position on).
    public static func setFixedPosition(_ c: Coordinate, altitude: Int?, time: Date, me: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: me, id: id, wantResponse: false) { a in
            a.message(41) { p in
                p.fixed32(1, UInt32(bitPattern: Int32((c.latitude * 1e7).rounded())))
                p.fixed32(2, UInt32(bitPattern: Int32((c.longitude * 1e7).rounded())))
                if let altitude { p.int32(3, Int32(altitude)) }
                p.fixed32(4, UInt32(max(0, time.timeIntervalSince1970)))
            }
            a.bytes(101, passkey)
        }
    }

    public static func removeFixedPosition(me: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: me, id: id, wantResponse: false) { a in a.bool(42, true); a.bytes(101, passkey) }
    }

    /// Forgets a node from the node's database.
    public static func removeNode(_ node: NodeNum, me: NodeNum, passkey: Data, id: UInt32) -> Data {
        packet(to: me, id: id, wantResponse: false) { a in a.uint(38, UInt64(node.raw)); a.bytes(101, passkey) }
    }
}

/// A User record announced over the mesh (NODEINFO_APP).
public struct UserUpdate: Equatable, Sendable {
    public var raw: Data
    public var longName: String?
    public var shortName: String?
    public var hwModel: Int?
}
