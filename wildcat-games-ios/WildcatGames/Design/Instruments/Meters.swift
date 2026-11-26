import SwiftUI

// MARK: - Signal grading (pure logic)

/// Turns a LoRa reading into bars and a plain word. SNR is the better guide
/// on LoRa (it can go below zero and still decode), so it wins when both are
/// known; RSSI is the fallback.
enum SignalGrade: Int, Comparable, CaseIterable {
    case none = 0, weak, ok, strong

    static func < (a: SignalGrade, b: SignalGrade) -> Bool { a.rawValue < b.rawValue }

    /// "strong" / "ok" / "weak", or "no signal".
    var word: String {
        switch self {
        case .none: return "no signal"
        case .weak: return "weak"
        case .ok: return "ok"
        case .strong: return "strong"
        }
    }

    /// 0 (nothing heard) to 5 bars.
    static func bars(snr: Double?, rssi: Int?) -> Int {
        if let snr, snr.isFinite {
            switch snr {
            case 10...: return 5
            case 8..<10: return 4
            case 5..<8: return 3
            case 0..<5: return 2
            default: return 1
            }
        }
        if let rssi {
            switch rssi {
            case (-90)...: return 5
            case (-100)..<(-90): return 4
            case (-108)..<(-100): return 3
            case (-115)..<(-108): return 2
            default: return 1
            }
        }
        return 0
    }

    /// The word for a bar count: 4–5 strong, 2–3 ok, 1 weak.
    static func grade(bars: Int) -> SignalGrade {
        switch bars {
        case ...0: return .none
        case 1: return .weak
        case 2...3: return .ok
        default: return .strong
        }
    }

    static func grade(snr: Double?, rssi: Int?) -> SignalGrade {
        grade(bars: bars(snr: snr, rssi: rssi))
    }
}

// MARK: - Segment meter

/// A row of little rectangles, some lit (AB `.seg`). Inline and tiny in rows
/// and message meta; large and 20-step with a scale under it for Fox Hunt.
struct SegmentMeter: View {
    enum Size {
        /// 3 × 8 pt: cells, marks.
        case xs
        /// 4 × 10 pt: rows, message meta.
        case small
        /// 6 × 11 pt: panels.
        case regular
        /// Fills the width, 18 pt tall: the Fox Hunt meter.
        case large
    }

    /// 0...1.
    let value: Double
    var segments: Int = 5
    var tint: Color = Theme.textPrimary
    var size: Size = .small
    /// Labels spread evenly under a large meter ("−20" … "+20 dB").
    var scale: [String] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(value: Double, segments: Int = 5, tint: Color = Theme.textPrimary, size: Size = .small, scale: [String] = []) {
        self.value = value
        self.segments = segments
        self.tint = tint
        self.size = size
        self.scale = scale
    }

    /// Tinted in a network's colour.
    init(value: Double, segments: Int = 5, network: MeshNetwork, size: Size = .small, scale: [String] = []) {
        self.init(value: value, segments: segments, tint: network.color, size: size, scale: scale)
    }

    /// `lit` of `segments` lit.
    init(lit: Int, of segments: Int, tint: Color = Theme.textPrimary, size: Size = .small) {
        let n = max(1, segments)
        self.init(value: Double(max(0, min(n, lit))) / Double(n), segments: n, tint: tint, size: size)
    }

    /// How many segments light for a 0...1 value: rounded, at least one for
    /// anything above zero, clamped.
    static func litCount(value: Double, segments: Int) -> Int {
        guard segments > 0, value.isFinite, value > 0 else { return 0 }
        let v = min(1, value)
        return max(1, min(segments, Int((v * Double(segments)).rounded())))
    }

    /// The Fox Hunt SNR scale: −20…+20 dB mapped to 0...1.
    static func snrFraction(_ snr: Double) -> Double {
        guard snr.isFinite else { return 0 }
        return max(0, min(1, (snr + 20) / 40))
    }

    static let snrScale = ["−20", "−10", "0", "+10", "+20 dB"]

    private var lit: Int { Self.litCount(value: value, segments: segments) }

    private var dims: (w: CGFloat, h: CGFloat, gap: CGFloat, r: CGFloat) {
        switch size {
        case .xs: return (3, 8, 1, 0.5)
        case .small: return (4, 10, 2, 1)
        case .regular: return (6, 11, 2, 1)
        case .large: return (0, 18, 3, 2)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: dims.gap) {
                ForEach(0..<max(1, segments), id: \.self) { i in
                    RoundedRectangle(cornerRadius: dims.r, style: .continuous)
                        .fill(i < lit ? tint : Theme.segmentOff)
                        .frame(width: size == .large ? nil : dims.w, height: dims.h)
                        .frame(maxWidth: size == .large ? .infinity : nil)
                }
            }
            .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy), value: lit)
            if size == .large, !scale.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(scale.enumerated()), id: \.offset) { i, s in
                        Text(s)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                        if i < scale.count - 1 { Spacer(minLength: 4) }
                    }
                }
            }
        }
        .fixedSize(horizontal: size != .large, vertical: true)
        .accessibilityElement()
        .accessibilityLabel("\(lit) of \(segments)")
    }
}

// MARK: - Signal meter

/// SNR / RSSI as 5 bars plus an optional quality word and value
/// ("▮▮▮▯▯ ok · 6.8 dB").
struct SignalMeter: View {
    var snr: Double?
    var rssi: Int?
    var tint: Color = Theme.textPrimary
    var size: SegmentMeter.Size = .small
    var showsWord: Bool = true
    var showsValue: Bool = false

    init(snr: Double?, rssi: Int? = nil, tint: Color = Theme.textPrimary, size: SegmentMeter.Size = .small,
         showsWord: Bool = true, showsValue: Bool = false) {
        self.snr = snr
        self.rssi = rssi
        self.tint = tint
        self.size = size
        self.showsWord = showsWord
        self.showsValue = showsValue
    }

    init(snr: Double?, rssi: Int? = nil, network: MeshNetwork, size: SegmentMeter.Size = .small,
         showsWord: Bool = true, showsValue: Bool = false) {
        self.init(snr: snr, rssi: rssi, tint: network.color, size: size, showsWord: showsWord, showsValue: showsValue)
    }

    private var bars: Int { SignalGrade.bars(snr: snr, rssi: rssi) }
    private var grade: SignalGrade { SignalGrade.grade(bars: bars) }

    private var valueText: String? {
        if let snr, snr.isFinite { return "\(snr.formatted(.number.precision(.fractionLength(0...2)))) dB" }
        if let rssi { return "\(rssi) dBm" }
        return nil
    }

    var body: some View {
        HStack(spacing: 7) {
            SegmentMeter(lit: bars, of: 5, tint: tint, size: size)
            if showsWord {
                Text(grade == .none ? grade.word : "\(grade.word) signal")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if showsValue, let valueText {
                Text(valueText)
                    .font(Theme.Fonts.raw)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(grade.word)\(valueText.map { ", \($0)" } ?? "")")
    }
}

// MARK: - LED

/// A small status light with a soft halo (AB `.led`).
struct StatusLED: View {
    var color: Color = Theme.ok
    var on: Bool = true
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(on ? color : Theme.textQuaternary)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(on ? 0.15 : 0)).padding(-3))
            .shadow(color: on ? color.opacity(0.5) : .clear, radius: on ? 4 : 0)
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Meters") {
    VStack(alignment: .leading, spacing: 16) {
        SegmentMeter(value: 0.8, segments: 10, tint: Theme.ok, size: .small)
        SegmentMeter(value: 0.6, network: .meshcore, size: .regular)
        SegmentMeter(value: 0.4, segments: 8, network: .meshtastic, size: .xs)
        SegmentMeter(value: SegmentMeter.snrFraction(-3.25), segments: 20, network: .meshcore, size: .large,
                     scale: SegmentMeter.snrScale)
        SignalMeter(snr: 12.2, network: .meshcore)
        SignalMeter(snr: -3.25, network: .meshtastic, showsValue: true)
        SignalMeter(snr: nil, rssi: -104)
        HStack { StatusLED(); StatusLED(color: Theme.meshcore); StatusLED(on: false) }
    }
    .padding()
    .screen()
}
