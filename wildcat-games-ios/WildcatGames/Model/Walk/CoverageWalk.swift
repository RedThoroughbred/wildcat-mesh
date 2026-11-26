import Foundation

/// One point on a coverage walk.
struct CoveragePoint: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// The Den heard my node here (hop 0).
        case uplink
        /// My node heard the Den here (hop 0).
        case downlink
        /// My node beaconed here and the Den heard nothing within the wait.
        case missed
    }

    var id = UUID()
    var time: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double?
    var kind: Kind
    var snr: Double?
    var rssi: Int?

    /// The Den's thresholds (signal_view.classify): strong ≥ 0 dB SNR and ≥ -100 dBm,
    /// weak ≤ -10 dB or ≤ -115 dBm.
    enum Quality: String { case strong, ok, weak, none }

    var quality: Quality {
        guard kind != .missed else { return .none }
        let s = snr ?? -99, r = rssi.map(Double.init) ?? -999
        if s <= -10 || (rssi != nil && r <= -115) { return .weak }
        if s >= 0 && (rssi == nil || r >= -100) { return .strong }
        return .ok
    }
}

struct CoverageWalk: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var started: Date
    var ended: Date?
    /// "!xxxxxxxx" of the node being carried.
    var node: String
    /// "!xxxxxxxx" of the Den's radio.
    var den: String
    var beaconInterval: TimeInterval
    /// Recorded in drive mode (background location).
    var drive: Bool?
    var points: [CoveragePoint] = []

    var heard: Int { points.filter { $0.kind == .uplink }.count }
    var missed: Int { points.filter { $0.kind == .missed }.count }
    var downlinks: Int { points.filter { $0.kind == .downlink }.count }
}

/// The pairing rules, pure: GPS fixes in, the Den's measurements in, beacons
/// out, points produced. The recorder feeds it; tests drive it directly.
struct WalkPairing: Equatable {
    struct Fix: Equatable {
        var time: Date
        var latitude: Double
        var longitude: Double
        var accuracy: Double?
    }

    struct Beacon: Equatable {
        var time: Date
        var fix: Fix
    }

    /// How long after a beacon the Den's hearing of it may arrive.
    var wait: TimeInterval = 45
    /// A fix further than this from a measurement's time is not "here".
    var maxFixAge: TimeInterval = 20
    /// Fixes worse than this (metres) are ignored.
    var maxAccuracy: Double = 50

    private(set) var fixes: [Fix] = []
    private(set) var pending: [Beacon] = []
    /// The newest Den sample already used (its timestamp).
    private(set) var lastDenSample: Date?

    mutating func add(_ fix: Fix) {
        if let acc = fix.accuracy, acc > maxAccuracy { return }
        fixes.append(fix)
        let cutoff = fix.time.addingTimeInterval(-600)
        fixes.removeAll { $0.time < cutoff }
    }

    /// The fix closest in time to `t`, if close enough.
    func fix(near t: Date) -> Fix? {
        guard let f = fixes.min(by: { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }),
              abs(f.time.timeIntervalSince(t)) <= maxFixAge else { return nil }
        return f
    }

    /// Records a beacon sent now; nil when there is no usable fix to pin it to.
    mutating func beaconSent(at t: Date) -> Bool {
        guard let f = fix(near: t) else { return false }
        pending.append(Beacon(time: t, fix: f))
        return true
    }

    /// A measurement the Den made of my node (from /api/signal/<id>): an
    /// uplink point, and the beacon it answers no longer pending.
    mutating func denHeard(at t: Date, snr: Double?, rssi: Int?, hops: Int?) -> CoveragePoint? {
        if let last = lastDenSample, t <= last { return nil }
        lastDenSample = t
        guard hops == 0 || hops == nil, let f = fix(near: t) else { return nil }
        // The beacon this answers: the latest one sent at or before it (with clock slack).
        if let i = pending.lastIndex(where: { $0.time <= t.addingTimeInterval(5) }) {
            pending.removeSubrange(...i)
        }
        return CoveragePoint(time: t, latitude: f.latitude, longitude: f.longitude, accuracy: f.accuracy,
                             kind: .uplink, snr: snr, rssi: rssi)
    }

    /// My node heard the Den directly.
    func nodeHeardDen(at t: Date, snr: Double?, rssi: Int?) -> CoveragePoint? {
        guard let f = fix(near: t) else { return nil }
        return CoveragePoint(time: t, latitude: f.latitude, longitude: f.longitude, accuracy: f.accuracy,
                             kind: .downlink, snr: snr, rssi: rssi)
    }

    /// Beacons the Den never heard, once their wait is over.
    mutating func expire(now: Date) -> [CoveragePoint] {
        let due = pending.filter { now.timeIntervalSince($0.time) > wait }
        pending.removeAll { now.timeIntervalSince($0.time) > wait }
        return due.map {
            CoveragePoint(time: $0.time, latitude: $0.fix.latitude, longitude: $0.fix.longitude,
                          accuracy: $0.fix.accuracy, kind: .missed, snr: nil, rssi: nil)
        }
    }
}

/// Walks saved as JSON in Documents/walks.
enum WalkStore {
    static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("walks")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ w: CoverageWalk, in dir: URL = directory) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try? e.encode(w).write(to: dir.appendingPathComponent("\(w.id.uuidString).json"), options: .atomic)
    }

    static func load(in dir: URL = directory) -> [CoverageWalk] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? d.decode(CoverageWalk.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    static func delete(_ w: CoverageWalk, in dir: URL = directory) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(w.id.uuidString).json"))
    }

    /// CSV for sharing: time, lat, lon, kind, snr, rssi.
    static func csv(_ w: CoverageWalk) -> String {
        var s = "time,lat,lon,accuracy_m,kind,snr_db,rssi_dbm\n"
        let f = ISO8601DateFormatter()
        for p in w.points {
            s += "\(f.string(from: p.time)),\(p.latitude),\(p.longitude),\(p.accuracy.map { String($0) } ?? ""),"
            s += "\(p.kind.rawValue),\(p.snr.map { String($0) } ?? ""),\(p.rssi.map(String.init) ?? "")\n"
        }
        return s
    }
}
