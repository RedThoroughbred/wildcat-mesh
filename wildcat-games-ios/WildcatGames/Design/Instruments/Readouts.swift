import SwiftUI

// MARK: - Readout cell

/// How big a readout's number is.
enum ReadoutSize {
    /// 21 pt: a cell in a row of three or four (AB `.cell .v`).
    case regular
    /// 32 pt: a cell in a row of two (AB `.ro`).
    case large
    /// 68 pt: the one number a screen is about (Fox Hunt SNR).
    case hero

    fileprivate var points: CGFloat {
        switch self {
        case .regular: return 21
        case .large: return 32
        case .hero: return 68
        }
    }

    fileprivate var weight: Font.Weight {
        self == .hero ? .thin : .light
    }

    fileprivate var textStyle: Font.TextStyle {
        switch self {
        case .regular: return .title3
        case .large: return .title
        case .hero: return .largeTitle
        }
    }
}

/// An instrument readout (AB `.cell`): a mono label, a big thin number with
/// a small mono unit, an optional sub-line, and an optional footer (a
/// `SegmentMeter` or `Sparkline`). Lay cells side by side with
/// `CellDivider()` between them inside an `InstrumentPanel`.
struct ReadoutCell<Footer: View>: View {
    let label: String
    let value: String
    var unit: String? = nil
    var sub: String? = nil
    var size: ReadoutSize = .regular
    var tint: Color = Theme.textPrimary
    let footer: Footer

    @ScaledMetric private var scale: CGFloat = 1

    init(_ label: String, value: String, unit: String? = nil, sub: String? = nil,
         size: ReadoutSize = .regular, tint: Color = Theme.textPrimary, @ViewBuilder footer: () -> Footer) {
        self.label = label
        self.value = value
        self.unit = unit
        self.sub = sub
        self.size = size
        self.tint = tint
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: size.points * scale, weight: size.weight))
                    .tracking(size == .hero ? -2.5 : size == .large ? -0.8 : -0.4)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit)
                        .font(.system(size: size == .hero ? 13 : size == .large ? 11 : 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, size == .regular ? 5 : 7)
            footer
                .padding(.top, 8)
            if let sub {
                Text(sub)
                    .font(.system(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(unit.map { " \($0)" } ?? "")\(sub.map { ", \($0)" } ?? "")")
    }
}

extension ReadoutCell where Footer == EmptyView {
    init(_ label: String, value: String, unit: String? = nil, sub: String? = nil,
         size: ReadoutSize = .regular, tint: Color = Theme.textPrimary) {
        self.init(label, value: value, unit: unit, sub: sub, size: size, tint: tint) { EmptyView() }
    }
}

/// Readout cells side by side, as tall as the tallest, so `CellDivider`s
/// run full height: `ReadoutRow { ReadoutCell(…); CellDivider(); ReadoutCell(…) }`.
struct ReadoutRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A vertical hairline between readout cells.
struct CellDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
    }
}

/// A horizontal hairline across a panel, between rows of cells.
struct PanelDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

// MARK: - Sparkline

/// A small history chart drawn with `Path`: a line, or bars like the AB
/// "scope" (grey bars with the highlighted one in colour).
struct Sparkline: View {
    enum Style {
        case line
        /// Bars; `highlight` is the index drawn in the tint (nil: the last).
        case bars(highlight: Int?)
    }

    let values: [Double]
    var tint: Color = Theme.textPrimary
    var style: Style = .bars(highlight: nil)
    /// A dashed reference line at this value (e.g. the best reading).
    var reference: Double? = nil
    var referenceTint: Color = Theme.ok

    var body: some View {
        Canvas { context, size in
            let clean = values.filter(\.isFinite)
            guard !clean.isEmpty, size.width > 0, size.height > 0 else { return }
            let lo = min(clean.min() ?? 0, reference ?? .infinity)
            let hi = max(clean.max() ?? 1, reference ?? -.infinity)
            let span = max(hi - lo, 0.0001)
            func y(_ v: Double) -> CGFloat {
                // Leave a sliver at the bottom so the smallest bar still shows.
                let t = (v - lo) / span
                return size.height - CGFloat(0.12 + 0.88 * t) * size.height
            }
            switch style {
            case .line:
                var path = Path()
                for (i, v) in clean.enumerated() {
                    let x = clean.count == 1 ? size.width / 2 : size.width * CGFloat(i) / CGFloat(clean.count - 1)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y(v))) } else { path.addLine(to: CGPoint(x: x, y: y(v))) }
                }
                context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = clean.last {
                    let dot = CGRect(x: size.width - 2.5, y: y(last) - 2.5, width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .color(tint))
                }
            case .bars(let highlight):
                let n = CGFloat(clean.count)
                let gap: CGFloat = n > 30 ? 1 : 2
                let w = max(1, (size.width - gap * (n - 1)) / n)
                let hot = highlight ?? clean.count - 1
                for (i, v) in clean.enumerated() {
                    let x = CGFloat(i) * (w + gap)
                    let top = y(v)
                    let rect = CGRect(x: x, y: top, width: w, height: size.height - top)
                    let color = i == hot ? tint : Theme.textTertiary
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1, w / 2)), with: .color(color))
                }
            }
            if let reference {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(reference)))
                line.addLine(to: CGPoint(x: size.width, y: y(reference)))
                context.stroke(line, with: .color(referenceTint.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Readouts") {
    VStack(spacing: 0) {
        ReadoutRow {
            ReadoutCell("Battery", value: "3.98", unit: "V", size: .large) {
                HStack(spacing: 7) {
                    SegmentMeter(value: 0.82, segments: 10, tint: Theme.ok)
                    Text("82% · ~3 days").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            CellDivider()
            ReadoutCell("Airtime · 1h", value: "2.1", unit: "%", size: .large) {
                Sparkline(values: [3, 5, 2, 7, 4, 2, 6, 11, 4, 3, 6, 2], tint: Theme.meshcore, style: .bars(highlight: 7))
                    .frame(width: 60, height: 11)
            }
        }
        PanelDivider()
        ReadoutRow {
            ReadoutCell("Noise", value: "−112", unit: "dBm")
            CellDivider()
            ReadoutCell("Best SNR", value: "9.5", unit: "dB")
            CellDivider()
            ReadoutCell("Uptime", value: "3d 04", unit: "h", sub: "since Tuesday")
        }
    }
    .instrumentPanel()
    .padding()
    .screen()
}
