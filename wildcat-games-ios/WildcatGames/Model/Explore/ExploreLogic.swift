import Foundation

// MARK: - Territory

/// Every hexagon you've walked, coloured by the best link the Den reported there.
struct Territory: Equatable {
    struct Tile: Equatable {
        var best: CoveragePoint.Quality
        var visits: Int
    }

    var grid: HexGrid
    var tiles: [HexGrid.Key: Tile] = [:]

    init(grid: HexGrid, points: [CoveragePoint]) {
        self.grid = grid
        for p in points where p.kind != .downlink {
            let k = grid.key(for: LatLon(lat: p.latitude, lon: p.longitude))
            var t = tiles[k] ?? Tile(best: .none, visits: 0)
            t.visits += 1
            if Self.rank(p.quality) > Self.rank(t.best) { t.best = p.quality }
            tiles[k] = t
        }
    }

    static func rank(_ q: CoveragePoint.Quality) -> Int {
        switch q {
        case .none: return 0
        case .weak: return 1
        case .ok: return 2
        case .strong: return 3
        }
    }

    var explored: Int { tiles.count }
    var reached: Int { tiles.values.filter { $0.best != .none }.count }
    var dead: Int { tiles.values.filter { $0.best == .none }.count }

    /// Share of the tiles within `radius` metres of `center` that you've walked.
    func explored(within radius: Double, of center: LatLon) -> Double {
        let area = Double.pi * radius * radius
        let tileArea = 3 * sqrt(3) / 2 * grid.size * grid.size
        let total = max(1, area / tileArea)
        let inside = tiles.keys.filter { Geo.distance(grid.center($0), center) <= radius }.count
        return min(1, Double(inside) / total)
    }
}

// MARK: - Frontier

/// The farthest point in each of 16 directions from the Den where it heard you.
struct Frontier: Equatable {
    static let sectors = 16
    var den: LatLon
    /// Sector index -> (distance m, point).
    var reach: [Int: (Double, LatLon)] = [:]

    init(den: LatLon, points: [CoveragePoint]) {
        self.den = den
        for p in points where p.kind == .uplink {
            let at = LatLon(lat: p.latitude, lon: p.longitude)
            let d = Geo.distance(den, at)
            let s = Int(Geo.bearing(den, at) / (360.0 / Double(Self.sectors))) % Self.sectors
            if d > (reach[s]?.0 ?? -1) { reach[s] = (d, at) }
        }
    }

    static func == (a: Frontier, b: Frontier) -> Bool {
        a.den == b.den && a.reach.keys == b.reach.keys && a.reach.allSatisfy { b.reach[$0.key]?.0 == $0.value.0 }
    }

    var farthest: Double { reach.values.map(\.0).max() ?? 0 }

    /// The outline through each sector's farthest point, in bearing order.
    var outline: [LatLon] { reach.keys.sorted().compactMap { reach[$0]?.1 } }
}

// MARK: - Nodedex

struct DexEntry: Codable, Equatable, Identifiable {
    enum Rarity: String, Codable, CaseIterable, Comparable {
        case common, uncommon, rare, legendary

        static func < (a: Rarity, b: Rarity) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }

        /// By the longest distance you heard it from directly.
        init(distance: Double?) {
            switch distance ?? 0 {
            case 15_000...: self = .legendary
            case 5000...: self = .rare
            case 1000...: self = .uncommon
            default: self = .common
            }
        }
    }

    var id: String
    var shortName: String?
    var longName: String?
    var firstSeen: Date
    var firstPlace: LatLon?
    var lastSeen: Date
    var count: Int
    var bestSNR: Double?
    var bestRSSI: Int?
    /// Longest distance between you and the node when heard directly (needs its position).
    var longest: Double?

    var rarity: Rarity { Rarity(distance: longest) }
    var name: String { shortName?.isEmpty == false ? shortName! : String(id.suffix(4)) }
}

struct Nodedex: Codable, Equatable {
    var entries: [String: DexEntry] = [:]

    /// Records one direct hearing. Returns true when the node is new.
    @discardableResult
    mutating func heard(id: String, shortName: String?, longName: String?, at: Date, me: LatLon?,
                        nodePosition: LatLon?, snr: Double?, rssi: Int?) -> Bool {
        let d = (me != nil && nodePosition != nil) ? Geo.distance(me!, nodePosition!) : nil
        if var e = entries[id] {
            e.lastSeen = at
            e.count += 1
            e.shortName = shortName ?? e.shortName
            e.longName = longName ?? e.longName
            if let snr, snr > (e.bestSNR ?? -99) { e.bestSNR = snr }
            if let rssi, rssi > (e.bestRSSI ?? -999) { e.bestRSSI = rssi }
            if let d, d > (e.longest ?? 0) { e.longest = d }
            entries[id] = e
            return false
        }
        entries[id] = DexEntry(id: id, shortName: shortName, longName: longName, firstSeen: at, firstPlace: me,
                               lastSeen: at, count: 1, bestSNR: snr, bestRSSI: rssi, longest: d)
        return true
    }

    var sorted: [DexEntry] { entries.values.sorted { ($0.rarity, $0.longest ?? 0) > ($1.rarity, $1.longest ?? 0) } }
}

// MARK: - Daily Fox

struct DailyFoxRun: Codable, Equatable, Identifiable {
    var id: String { day }
    /// "2026-09-27"
    var day: String
    var foxID: String
    var foxName: String
    var foxPosition: LatLon
    var started: Date
    var found: Date?
    var gaveUp: Bool = false
    var hints: Int = 0
    var pings: Int = 0
    var walked: Double = 0
    var startDistance: Double?

    var isOver: Bool { found != nil || gaveUp }

    /// 1000, minus 4 a minute, 150 a hint, 20 a ping after the first five; at least 100.
    var score: Int {
        guard let found else { return 0 }
        let minutes = found.timeIntervalSince(started) / 60
        let s = 1000 - Int(minutes * 4) - hints * 150 - max(0, pings - 5) * 20
        return max(100, s)
    }
}

enum DailyFox {
    /// Found when you stand within this many metres of it.
    static let foundRadius = 100.0
    static let minDistance = 300.0

    static func day(_ d: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// FNV-1a: stable across launches (Swift's hashValue is not).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    struct Candidate: Equatable {
        var id: String
        var name: String
        var position: LatLon
        var lastHeard: Date?
    }

    /// Today's fox: among radio-heard nodes with a position between
    /// `minDistance` and `maxDistance` of you and heard in the last 3 days,
    /// the one whose hash with the day (and reroll count) is lowest.
    static func pick(from candidates: [Candidate], me: LatLon, day: String, reroll: Int = 0,
                     maxDistance: Double, now: Date = Date()) -> Candidate? {
        candidates
            .filter { c in
                let d = Geo.distance(me, c.position)
                return d >= minDistance && d <= maxDistance
                    && (c.lastHeard.map { now.timeIntervalSince($0) < 3 * 86_400 } ?? false)
            }
            .min { stableHash("\(day)#\(reroll)#\($0.id)") < stableHash("\(day)#\(reroll)#\($1.id)") }
    }

    /// "Between 1 and 2 km away."
    static func distanceHint(_ d: Double) -> String {
        let bands: [(Double, String)] = [(500, "under 500 m"), (1000, "500 m to 1 km"), (2000, "1 to 2 km"),
                                          (5000, "2 to 5 km"), (.infinity, "over 5 km")]
        return "It's " + (bands.first { d < $0.0 }?.1 ?? "far") + " away."
    }

    /// Days in a row ending today or yesterday with a found fox.
    static func streak(_ runs: [DailyFoxRun], today: String) -> Int {
        let found = Set(runs.filter { $0.found != nil }.map(\.day))
        var n = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = .gmt
        f.dateFormat = "yyyy-MM-dd"
        guard var d = f.date(from: today) else { return 0 }
        if !found.contains(today) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        while found.contains(f.string(from: d)) {
            n += 1
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return n
    }
}

// MARK: - Achievements

struct ExploreStats: Equatable {
    var uplinks = 0
    var downlinks = 0
    var deadZones = 0
    var farthest = 0.0
    var tiles = 0
    var walkedKm = 0.0
    var dex = 0
    var legendary = 0
    var foxes = 0
    var streak = 0
    var frontierSectors = 0
    var drives = 0
}

struct Achievement: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let isMet: (ExploreStats) -> Bool

    static func == (a: Achievement, b: Achievement) -> Bool { a.id == b.id }

    static let all: [Achievement] = [
        .init(id: "first-contact", symbol: "dot.radiowaves.left.and.right", title: "First Contact",
              detail: "The Den hears you on a walk.") { $0.uplinks >= 1 },
        .init(id: "range-1k", symbol: "ruler", title: "Out of the Yard", detail: "Reach the Den from 1 km.") { $0.farthest >= 1000 },
        .init(id: "range-3k", symbol: "ruler", title: "Across Town", detail: "Reach the Den from 3 km.") { $0.farthest >= 3000 },
        .init(id: "range-10k", symbol: "mountain.2", title: "Long Shot", detail: "Reach the Den from 10 km.") { $0.farthest >= 10_000 },
        .init(id: "dead-5", symbol: "circle.slash", title: "Dead Zone Hunter", detail: "Find 5 dead spots.") { $0.deadZones >= 5 },
        .init(id: "two-way", symbol: "arrow.left.arrow.right", title: "Two-Way Street",
              detail: "Your node hears the Den on a walk.") { $0.downlinks >= 1 },
        .init(id: "tiles-25", symbol: "hexagon", title: "Cartographer", detail: "Explore 25 tiles.") { $0.tiles >= 25 },
        .init(id: "tiles-200", symbol: "hexagon.fill", title: "Surveyor", detail: "Explore 200 tiles.") { $0.tiles >= 200 },
        .init(id: "walk-10", symbol: "figure.walk", title: "Ten Kilometres", detail: "Log 10 km of coverage.") { $0.walkedKm >= 10 },
        .init(id: "frontier-8", symbol: "scope", title: "Compass Rose", detail: "Reach the Den from 8 directions.") { $0.frontierSectors >= 8 },
        .init(id: "dex-10", symbol: "square.stack.3d.up", title: "Collector", detail: "Hear 10 nodes directly.") { $0.dex >= 10 },
        .init(id: "dex-50", symbol: "square.stack.3d.up.fill", title: "Nodedex Master", detail: "Hear 50 nodes directly.") { $0.dex >= 50 },
        .init(id: "legendary", symbol: "star.circle.fill", title: "Legendary", detail: "Hear a node directly from 15 km.") { $0.legendary >= 1 },
        .init(id: "fox-1", symbol: "pawprint", title: "Fox Finder", detail: "Find a Daily Fox.") { $0.foxes >= 1 },
        .init(id: "fox-streak-3", symbol: "flame", title: "On the Scent", detail: "Find the Daily Fox 3 days running.") { $0.streak >= 3 },
        .init(id: "fox-streak-7", symbol: "flame.fill", title: "Fox Week", detail: "Find the Daily Fox 7 days running.") { $0.streak >= 7 },
    ]
}

/// Stats derived from saved walks.
enum WalkStats {
    static func walkedKm(_ walks: [CoverageWalk]) -> Double {
        walks.reduce(0) { total, w in
            let pts = w.points.sorted { $0.time < $1.time }.map { LatLon(lat: $0.latitude, lon: $0.longitude) }
            var d = 0.0
            for (a, b) in zip(pts, pts.dropFirst()) {
                let step = Geo.distance(a, b)
                if step < 2000 { d += step }
            }
            return total + d / 1000
        }
    }
}
