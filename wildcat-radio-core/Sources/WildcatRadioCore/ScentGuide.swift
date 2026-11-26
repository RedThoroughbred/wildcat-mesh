import Foundation

/// The GPS guide for a hunter with no node ("scent mode" in the game docs): warmer or
/// colder from the distance between the phone and where the hider stood, never a map
/// pin. Three things keep it from giving the spot away:
///
/// - the spot it uses is the one shared in the hunt invite (`shared`): moved up to
///   `shareRadius` metres in a random direction and rounded to a ~11 m grid, so even the
///   invite's numbers are only "somewhere around here";
/// - the distance is noisy (`reading(noise:)`) and only its band is shown;
/// - the closest band is `bands[0]` metres wide: "hot" means look around, not dig here.
///
/// Pure maths: the caller supplies the random numbers, so every platform (and every
/// fixture) gets the same answer for the same inputs.
public enum ScentGuide {
    /// Band edges in metres, closest first. Inside the first is "hot".
    public static let bands: [Double] = [25, 50, 100, 200, 400]
    /// The meter value of each band (0–100), closest first, then beyond the last band.
    static let bandScores: [Double] = [96, 80, 62, 44, 26, 8]
    /// A phone fix less precise than this (metres) gives no reading.
    public static let maxAccuracy: Double = 50
    /// The invite's spot is moved up to this far (metres) from where the hider stood.
    public static let shareRadius: Double = 15
    /// The invite's spot is then rounded to this grid (degrees; about 11 m of latitude).
    public static let grid: Double = 0.0001
    /// At most this much stretch (fraction) and offset (metres) from `noise` = ±1.
    public static let noiseStretch: Double = 0.15
    public static let noiseOffset: Double = 10

    /// One reading of the guide.
    public struct Reading: Equatable, Sendable, Codable {
        /// 0 is the closest band ("hot"); `bands.count` is farther than the last band.
        public var band: Int

        public init(band: Int) { self.band = max(0, min(ScentGuide.bands.count, band)) }

        /// For a meter: 0–100, higher is closer.
        public var score: Double { ScentGuide.bandScores[max(0, min(ScentGuide.bandScores.count - 1, band))] }
        public var isHot: Bool { band <= 0 }
        /// "within about 25 m", "100–200 m", "more than 400 m".
        public var words: String { ScentGuide.words(band: band) }
    }

    /// Great-circle distance in metres.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        let d = 2 * 6_371_000 * asin(min(1, max(0, h).squareRoot()))
        return d.isFinite ? d : .infinity
    }

    /// The spot as shared in the invite: moved `distance` metres (at most `shareRadius`)
    /// along `bearing` (degrees clockwise from north), then rounded to the `grid`.
    public static func shared(_ spot: Coordinate, bearing: Double, distance: Double) -> Coordinate {
        let d = distance.isFinite ? max(0, min(shareRadius, distance)) : 0
        let b = (bearing.isFinite ? bearing : 0) * .pi / 180
        let lat = spot.latitude + d * cos(b) / 110_574
        let kx = 111_320 * cos(spot.latitude * .pi / 180)
        let lon = spot.longitude + (abs(kx) > 1e-6 ? d * sin(b) / kx : 0)
        func snap(_ v: Double) -> Double { ((v / grid).rounded() * grid * 1e7).rounded() / 1e7 }
        return Coordinate(latitude: max(-90, min(90, snap(lat))), longitude: snap(lon))
    }

    /// A random move for `shared`: uniform over the disc of `shareRadius`.
    public static func randomOffset<G: RandomNumberGenerator>(using g: inout G) -> (bearing: Double, distance: Double) {
        (Double.random(in: 0..<360, using: &g), shareRadius * Double.random(in: 0...1, using: &g).squareRoot())
    }

    /// The distance the guide works with: `noise` (-1...1, clamped; anything else is 0)
    /// stretches it by up to `noiseStretch` and moves it by up to `noiseOffset` metres.
    public static func noisyDistance(_ d: Double, noise: Double) -> Double {
        let n = noise.isFinite ? max(-1, min(1, noise)) : 0
        return max(0, d * (1 + noiseStretch * n) + noiseOffset * n)
    }

    /// The band a distance falls in.
    public static func band(for distance: Double) -> Int {
        bands.firstIndex { distance < $0 } ?? bands.count
    }

    /// The guide at `phone` for a piece shared at `spot`, with `noise` in -1...1; nil when
    /// the phone's fix (`accuracy`, metres) is missing, negative or worse than `maxAccuracy`.
    public static func reading(phone: Coordinate, accuracy: Double?, spot: Coordinate, noise: Double) -> Reading? {
        guard let accuracy, accuracy.isFinite, accuracy >= 0, accuracy <= maxAccuracy else { return nil }
        let d = distance(phone, spot)
        guard d.isFinite else { return nil }
        return Reading(band: band(for: noisyDistance(d, noise: noise)))
    }

    /// Warmer when the band got closer, colder when it got farther.
    public static func trend(_ previous: Reading?, _ current: Reading) -> FoxTracker.Trend {
        guard let previous else { return .none }
        return current.band < previous.band ? .warmer : current.band > previous.band ? .colder : .steady
    }

    /// The band in words.
    public static func words(band: Int) -> String {
        let b = max(0, min(bands.count, band))
        if b == 0 { return "within about \(Int(bands[0])) m" }
        if b == bands.count { return "more than \(Int(bands[bands.count - 1])) m" }
        return "\(Int(bands[b - 1]))–\(Int(bands[b])) m"
    }
}
