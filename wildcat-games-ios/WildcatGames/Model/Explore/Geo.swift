import CoreLocation
import Foundation

struct LatLon: Codable, Equatable, Hashable {
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

enum Geo {
    static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres.
    static func distance(_ a: LatLon, _ b: LatLon) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from a to b, degrees clockwise from north (0..<360).
    static func bearing(_ a: LatLon, _ b: LatLon) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180, dl = (b.lon - a.lon) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point `d` metres from `a` along `bearing`.
    static func offset(_ a: LatLon, distance d: Double, bearing: Double) -> LatLon {
        let r = d / earthRadius, th = bearing * .pi / 180
        let p1 = a.lat * .pi / 180, l1 = a.lon * .pi / 180
        let p2 = asin(sin(p1) * cos(r) + cos(p1) * sin(r) * cos(th))
        let l2 = l1 + atan2(sin(th) * sin(r) * cos(p1), cos(r) - sin(p1) * sin(p2))
        return LatLon(lat: p2 * 180 / .pi, lon: l2 * 180 / .pi)
    }

    /// "N", "NE", … for a bearing.
    static func compass(_ b: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((b + 22.5).truncatingRemainder(dividingBy: 360) / 45) % 8]
    }

    static func format(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded())) m" : String(format: "%.1f km", metres / 1000)
    }

    /// Uphill direction of signal over located samples (least-squares plane
    /// score = a + b·east + c·north), the same fit the Den's referee uses.
    /// nil unless ≥ 4 samples spread over ≥ 15 m.
    static func signalBearing(_ samples: [(LatLon, Double)]) -> Double? {
        guard samples.count >= 4 else { return nil }
        let origin = samples[0].0
        let pts = samples.map { s -> (Double, Double, Double) in
            let d = distance(origin, s.0), b = bearing(origin, s.0) * .pi / 180
            return (d * sin(b), d * cos(b), s.1)
        }
        let spread = pts.map { hypot($0.0, $0.1) }.max() ?? 0
        guard spread >= 15 else { return nil }
        let n = Double(pts.count)
        let mx = pts.map(\.0).reduce(0, +) / n, my = pts.map(\.1).reduce(0, +) / n, mz = pts.map(\.2).reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0, sxz = 0.0, syz = 0.0
        for p in pts {
            let x = p.0 - mx, y = p.1 - my, z = p.2 - mz
            sxx += x * x; syy += y * y; sxy += x * y; sxz += x * z; syz += y * z
        }
        let det = sxx * syy - sxy * sxy
        guard abs(det) > 1e-9 else { return nil }
        let b = (sxz * syy - syz * sxy) / det, c = (syz * sxx - sxz * sxy) / det
        guard hypot(b, c) > 1e-6 else { return nil }
        return (atan2(b, c) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// A flat-topped hexagon grid in metres, anchored at a fixed reference
/// latitude so tiles stay put across sessions.
struct HexGrid: Codable, Equatable {
    struct Key: Codable, Hashable { var q: Int; var r: Int }

    /// Centre-to-corner size in metres.
    var size: Double = 90
    var refLat: Double

    private var mPerDegLat: Double { 110_574 }
    private var mPerDegLon: Double { 111_320 * cos(refLat * .pi / 180) }

    func key(for p: LatLon) -> Key {
        let x = p.lon * mPerDegLon, y = p.lat * mPerDegLat
        let q = (2.0 / 3.0 * x) / size
        let r = (-1.0 / 3.0 * x + sqrt(3) / 3 * y) / size
        return Self.round(q, r)
    }

    func center(_ k: Key) -> LatLon {
        let x = size * 1.5 * Double(k.q)
        let y = size * sqrt(3) * (Double(k.r) + Double(k.q) / 2)
        return LatLon(lat: y / mPerDegLat, lon: x / mPerDegLon)
    }

    func corners(_ k: Key) -> [LatLon] {
        let c = center(k)
        return (0..<6).map { i in
            let a = Double(i) * 60 * .pi / 180
            return LatLon(lat: c.lat + size * sin(a) / mPerDegLat, lon: c.lon + size * cos(a) / mPerDegLon)
        }
    }

    static func round(_ q: Double, _ r: Double) -> Key {
        let s = -q - r
        var rq = q.rounded(), rr = r.rounded()
        let rs = s.rounded()
        let dq = abs(rq - q), dr = abs(rr - r), ds = abs(rs - s)
        if dq > dr && dq > ds { rq = -rr - rs } else if dr > ds { rr = -rq - rs }
        return Key(q: Int(rq), r: Int(rr))
    }
}
