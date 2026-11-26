import Foundation
import WildcatRadioCore

/// The numbers and words on the Fox Hunt instrument, worked out from a
/// tracker's samples. Pure and clock-free: callers pass the samples.
enum FoxReadout {
    /// Which reading leads the instrument: SNR when the radio reports it
    /// (LoRa still decodes below zero, so it keeps moving far out), RSSI
    /// otherwise.
    enum Unit: Equatable {
        case snr, rssi

        /// The unit under the big number.
        var label: String { self == .snr ? "dB SNR" : "dBm" }
        /// The short unit after a small number.
        var short: String { self == .snr ? "dB" : "dBm" }
        /// A change this big is warmer or colder (the Den's steps).
        var step: Double { self == .snr ? 1.5 : 3 }
    }

    static func unit(for sample: FoxTracker.Sample?) -> Unit {
        if let snr = sample?.snr, snr.isFinite { return .snr }
        return .rssi
    }

    /// The sample's reading in `unit`, if it has one.
    static func value(_ sample: FoxTracker.Sample, _ unit: Unit) -> Double? {
        switch unit {
        case .snr: return sample.snr.flatMap { $0.isFinite ? $0 : nil }
        case .rssi: return sample.rssi.map(Double.init)
        }
    }

    // MARK: Warmer / colder

    enum Warmth: Equatable {
        case none, warmer, colder, steady

        var word: String {
            switch self {
            case .none: return "First reading"
            case .warmer: return "Warmer"
            case .colder: return "Colder"
            case .steady: return "Steady"
            }
        }

        var arrow: String {
            switch self {
            case .warmer: return "▲"
            case .colder: return "▼"
            case .steady: return "▶"
            case .none: return "•"
            }
        }
    }

    /// The change over the last `window` seconds: the latest reading minus
    /// the newest one at least `window` older (or the oldest there is).
    /// nil with fewer than two readings in `unit`.
    static func change(_ samples: [FoxTracker.Sample], unit: Unit, window: TimeInterval = 30) -> Double? {
        let usable = samples.compactMap { s in value(s, unit).map { (s.time, $0) } }
        guard usable.count >= 2, let last = usable.last else { return nil }
        let cutoff = last.0.addingTimeInterval(-window)
        let base = usable.dropLast().last { $0.0 <= cutoff } ?? usable[0]
        return last.1 - base.1
    }

    static func warmth(change: Double?, unit: Unit) -> Warmth {
        guard let change, change.isFinite else { return .none }
        if change >= unit.step { return .warmer }
        if change <= -unit.step { return .colder }
        return .steady
    }

    // MARK: Trend bars

    /// Bars for the trend strip: readings from the last `window` seconds
    /// (up to the latest), thinned to at most `maxBars` by keeping each
    /// run's peak. When fewer than two readings fall in the window (a fox
    /// that beacons once a minute), the last `maxBars` readings instead;
    /// `windowed` says which.
    static func trend(_ samples: [FoxTracker.Sample], unit: Unit, window: TimeInterval = 120,
                      maxBars: Int = 24) -> (values: [Double], windowed: Bool) {
        let usable = samples.compactMap { s in value(s, unit).map { (s.time, $0) } }
        guard let last = usable.last, maxBars > 0 else { return ([], false) }
        let recent = usable.filter { $0.0 >= last.0.addingTimeInterval(-window) }.map(\.1)
        let windowed = recent.count >= 2
        let values = windowed ? recent : Array(usable.suffix(maxBars).map(\.1))
        return (thin(values, to: maxBars), windowed)
    }

    /// At most `count` values, each the peak of its run.
    static func thin(_ values: [Double], to count: Int) -> [Double] {
        guard count > 0, values.count > count else { return values }
        return (0..<count).map { i in
            let lo = i * values.count / count
            let hi = max(lo + 1, (i + 1) * values.count / count)
            return values[lo..<min(hi, values.count)].max() ?? values[lo]
        }
    }

    // MARK: Meter

    /// 0...1 for the 20-step meter: SNR over −20…+20 dB, RSSI over −125…−45 dBm.
    static func meterFraction(_ value: Double?, unit: Unit) -> Double {
        guard let value, value.isFinite else { return 0 }
        switch unit {
        case .snr: return max(0, min(1, (value + 20) / 40))
        case .rssi: return max(0, min(1, (value + 125) / 80))
        }
    }

    static func meterScale(_ unit: Unit) -> [String] {
        unit == .snr ? ["−20", "−10", "0", "+10", "+20 dB"] : ["−125", "−105", "−85", "−65", "−45 dBm"]
    }

    // MARK: Text

    /// "−3.25" (SNR, true minus sign) or "−97" (RSSI); `signed` adds "+".
    static func format(_ value: Double, unit: Unit, signed: Bool = false) -> String {
        guard value.isFinite else { return "--" }
        let body: String
        switch unit {
        case .snr:
            // Meshtastic reports quarter dB: show them, but keep one place at least.
            let rounded = (abs(value) * 100).rounded() / 100
            body = rounded == (rounded * 10).rounded() / 10 ? String(format: "%.1f", rounded) : String(format: "%.2f", rounded)
        case .rssi:
            body = "\(Int(abs(value).rounded()))"
        }
        let zero = Double(body) == 0
        if value < 0, !zero { return "−" + body }
        return signed && !zero ? "+" + body : body
    }

    /// "12:41", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "4 s ago", "3 min ago", "2 h ago".
    static func ago(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "" }
        let s = max(0, Int(seconds))
        if s < 1 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    /// "north-east" for 47°.
    static func direction(_ bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        guard bearing.isFinite else { return "north" }
        let b = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((b + 22.5) / 45) % 8]
    }

    /// "047°".
    static func degrees(_ bearing: Double) -> String {
        guard bearing.isFinite else { return "--°" }
        let b = (Int(bearing.rounded()) % 360 + 360) % 360
        return String(format: "%03d°", b)
    }

    /// The one plain-English instruction under the instrument: a bold lead
    /// ("Getting warmer.") and what to do next.
    static func instruction(hasReading: Bool, warmth: Warmth, bearing: Double?, distance: Double? = nil,
                            veryClose: Bool = false, listening: String) -> (lead: String, rest: String) {
        if veryClose {
            return ("Very close.", "Look around you for the box, then tap Found it and enter its code.")
        }
        guard hasReading else { return ("Listening.", listening) }
        var way = ""
        if let bearing {
            way = "Head \(direction(bearing)) (\(degrees(bearing)))"
            if let distance, distance.isFinite, distance > 0 { way += ", about \(Geo.format(distance))" }
            way += ". "
        }
        switch warmth {
        case .warmer:
            return ("Getting warmer.", way + "Keep going the way you're walking.")
        case .colder:
            return ("Getting colder.", way.isEmpty ? "Turn back and try another direction." : way + "Turn back towards it.")
        case .steady:
            return ("Holding steady.", way + "Turn slowly in place: your body blocks signal, so the strongest direction is usually the way to go.")
        case .none:
            return ("First reading.", way + "Walk a little way and watch the number: bigger is closer.")
        }
    }
}
