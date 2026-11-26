import SwiftUI
import UIKit
import WildcatRadioCore

// The Fox Hunt instrument (AB/06-foxhunt): the target and hunt code, a big
// SNR readout with a 20-step meter and a 2-minute trend, a bearing radar,
// readout cells, one plain-English instruction and a row of keys. Shared by
// Fox Hunt (Den or phone refereed), Solo hunt and Daily Fox. Everything is
// passed in as plain values; the words and numbers come from `FoxReadout`.

// MARK: - Title

/// "Fox Hunt" over "● Meshtastic · via STAY" for the navigation bar.
struct FoxNavTitle: View {
    let title: String
    let network: MeshNetwork
    let via: String
    var connected: Bool = true

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 5) {
                StatusLED(color: network.color, on: connected, size: 6)
                Text("\(network.name) · \(via)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Target

/// The fox on the left, the hunt code (tap to copy) on the right.
struct FoxTargetCard: View {
    let network: MeshNetwork
    let fox: String
    var detail: String? = nil
    var codeLabel: String = "Hunt code"
    var code: String? = nil
    var copyable: Bool = true
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "antenna.radiowaves.left.and.right", tint: network.color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                CardLabel("Fox")
                Text(fox)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(Theme.Fonts.raw)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let code {
                VStack(alignment: .trailing, spacing: 3) {
                    CardLabel(codeLabel)
                    if copyable {
                        Button(action: copy) { codeText(code) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(codeLabel) \(code)")
                            .accessibilityHint(copied ? "Copied" : "Copies it")
                    } else {
                        codeText(code)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .instrumentPanel(dots: false)
    }

    private func codeText(_ code: String) -> some View {
        HStack(spacing: 6) {
            Text(code)
                .font(.system(.title3, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if copyable {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copied ? Theme.ok : Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func copy() {
        guard let code else { return }
        UIPasteboard.general.string = code
        Haptics.selection()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Signal panel

/// 01 SIGNAL (big number, warmer/colder over 30 s, RSSI, 20-step meter)
/// and 02 TREND (bars with the best marked) in one instrument panel.
struct FoxSignalPanel: View {
    let network: MeshNetwork
    let samples: [FoxTracker.Sample]
    var best: FoxTracker.Sample? = nil
    /// What we are waiting for (read out by VoiceOver until the first reading).
    var listening: String

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 74

    private var latest: FoxTracker.Sample? { samples.last }
    /// SNR until a reading says otherwise (the meter's scale shows it while listening).
    private var unit: FoxReadout.Unit { latest == nil ? .snr : FoxReadout.unit(for: latest) }
    private var value: Double? { latest.flatMap { FoxReadout.value($0, unit) } }
    private var change: Double? { FoxReadout.change(samples, unit: unit) }
    private var warmth: FoxReadout.Warmth { FoxReadout.warmth(change: change, unit: unit) }

    private var warmthColor: Color {
        switch warmth {
        case .warmer: return Theme.ok
        case .colder: return Theme.alert
        case .steady, .none: return Theme.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(1, "Signal") { HeardAgo(time: latest?.time) }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            HStack(alignment: .bottom, spacing: 8) {
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(FoxReadout.format(value, unit: unit))
                            .font(.system(size: heroSize, weight: .thin))
                            .tracking(-2.5)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(unit.label)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }
                    .layoutPriority(1)
                } else {
                    Text("Listening")
                        .font(.system(.largeTitle, weight: .thin))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 14)
                }
                Spacer(minLength: 0)
                side
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            SegmentMeter(value: FoxReadout.meterFraction(value, unit: unit), segments: 20, network: network,
                         size: .large, scale: FoxReadout.meterScale(unit))
                .padding(.horizontal, 14)
                .padding(.top, 10)
            // While listening, the instruction line under the instrument says what to do.
            Spacer().frame(height: 12)
            PanelDivider()
            trend
        }
        .instrumentPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var side: some View {
        if latest != nil {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(warmth.arrow) \(warmth.word)")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(warmthColor)
                    .lineLimit(1)
                    .padding(.bottom, 4)
                if let change {
                    sideValue("\(FoxReadout.format(change, unit: unit, signed: true)) \(unit.short)", "Last 30 s")
                }
                if unit == .snr, let rssi = latest?.rssi {
                    sideValue("\(FoxReadout.format(Double(rssi), unit: .rssi)) dBm", "RSSI")
                        .padding(.top, 4)
                }
            }
            .fixedSize()
            .padding(.bottom, 14)
        }
    }

    private func sideValue(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Text(label.uppercased())
                .font(.system(size: 9.5, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var trend: some View {
        let t = FoxReadout.trend(samples, unit: unit)
        let bestValue = best.flatMap { FoxReadout.value($0, unit) } ?? t.values.max()
        let detail = t.windowed ? "2 min" : "last \(t.values.count)"
        return VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(2, "Trend", detail: t.values.isEmpty ? nil : detail) {
                if let bestValue {
                    Text("- - best \(FoxReadout.format(bestValue, unit: unit)) \(unit.short)")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.ok)
                }
            }
            TrendBars(values: t.values, best: bestValue, tint: network.color)
                .frame(height: 44)
                .overlay {
                    if t.values.isEmpty {
                        Text("Readings appear here as your node hears the fox.")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var accessibilityText: String {
        guard let value else { return "Signal. Listening. \(listening)" }
        var parts = ["Signal \(FoxReadout.format(value, unit: unit)) \(unit.label)", warmth.word]
        if let change { parts.append("\(FoxReadout.format(change, unit: unit, signed: true)) \(unit.short) in the last 30 seconds") }
        if unit == .snr, let rssi = latest?.rssi { parts.append("RSSI \(rssi) dBm") }
        return parts.joined(separator: ", ")
    }
}

/// "● heard 4 s ago", ticking every second; the LED is green while the
/// reading is under three minutes old.
struct HeardAgo: View {
    let time: Date?
    var verb: String = "heard"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let age = time.map { ctx.date.timeIntervalSince($0) }
            HStack(spacing: 5) {
                StatusLED(color: Theme.ok, on: (age ?? .infinity) < 180, size: 5)
                Text(age.map { "\(verb) \(FoxReadout.ago($0))" } ?? "not heard yet")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}

/// The trend strip (AB `.trend`): grey bars, the best one green, the
/// latest in the network colour, a dashed line at the best reading.
struct TrendBars: View {
    let values: [Double]
    var best: Double? = nil
    var tint: Color = Theme.textPrimary
    /// How many bar slots the strip has.
    var slots: Int = 24

    var body: some View {
        Canvas { context, size in
            let clean = values.filter(\.isFinite)
            guard !clean.isEmpty, size.width > 0, size.height > 0 else { return }
            let ref = best.flatMap { $0.isFinite ? $0 : nil }
            let lo = min(clean.min() ?? 0, ref ?? .infinity)
            let hi = max(clean.max() ?? 1, ref ?? -.infinity)
            let span = max(hi - lo, 0.0001)
            func y(_ v: Double) -> CGFloat {
                size.height - CGFloat(0.14 + 0.86 * (v - lo) / span) * size.height
            }
            // Fixed slots, newest on the right: the strip fills in like a scope.
            let n = CGFloat(max(slots, clean.count))
            let gap: CGFloat = 3
            let w = max(1, (size.width - gap * (n - 1)) / n)
            let offset = n - CGFloat(clean.count)
            let bestIndex = clean.indices.max { clean[$0] < clean[$1] }
            let lastIndex = clean.count - 1
            for (i, v) in clean.enumerated() {
                let x = (CGFloat(i) + offset) * (w + gap)
                let top = y(v)
                let color: Color = i == lastIndex ? tint : (i == bestIndex && clean.count > 1 ? Theme.ok : Theme.textTertiary)
                context.fill(Path(roundedRect: CGRect(x: x, y: top, width: w, height: size.height - top), cornerRadius: 1),
                             with: .color(color.opacity(color == Theme.textTertiary ? 0.8 : 1)))
            }
            if let ref {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(ref)))
                line.addLine(to: CGPoint(x: size.width, y: y(ref)))
                context.stroke(line, with: .color(Theme.ok.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Bearing radar

/// Range rings, cardinal ticks and the bearing to the fox (AB/04 map
/// style): a wedge when the spread is known, a line and a dot, and the
/// phone in the middle. Heading-up when the compass works, north-up when it
/// doesn't. A slow sweep runs while live, unless Reduce Motion or Reduce
/// Transparency is on.
struct FoxBearingRadar: View {
    let bearing: Double?
    var spread: Double? = nil
    var distance: Double? = nil
    var heading: Double? = nil
    var tint: Color = Theme.textPrimary
    /// Changes with each reading: fires a ring.
    var pulse: Int = 0
    var live: Bool = true
    /// Footer text when there's no bearing.
    var noBearing: String = "no bearing yet"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 6) {
            dial
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            HStack(spacing: 4) {
                Text(footer)
                    .foregroundStyle(bearing == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let distance, distance.isFinite {
                    Text("~\(Geo.format(distance))").foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 2)
        }
        .padding(8)
        .instrumentPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bearing.map { "Fox bearing \(Int($0.rounded())) degrees, \(FoxReadout.direction($0))" } ?? "No bearing yet")
    }

    private var footer: String {
        guard let bearing else { return noBearing }
        return FoxReadout.degrees(bearing) + (spread.map { " ±\(Int($0.rounded()))°" } ?? "")
    }

    private var dial: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2 * 0.9
            ZStack {
                ZStack {
                    Circle().stroke(Theme.textPrimary.opacity(0.14), lineWidth: 1)
                        .frame(width: r * 2, height: r * 2)
                    ForEach([0.66, 0.33], id: \.self) { f in
                        Circle().stroke(Theme.textPrimary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(width: r * 2 * f, height: r * 2 * f)
                    }
                    CardinalTicks(radius: r)
                        .stroke(Theme.textPrimary.opacity(0.25), lineWidth: 1)
                    Text("N")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .offset(y: -r * 0.76)
                    if live && !reduceMotion && !reduceTransparency {
                        TimelineView(.animation) { ctx in
                            let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
                            Circle()
                                .fill(AngularGradient(stops: [.init(color: tint.opacity(0), location: 0),
                                                              .init(color: tint.opacity(0), location: 0.82),
                                                              .init(color: tint.opacity(0.13), location: 1)],
                                                      center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
                                .frame(width: r * 2, height: r * 2)
                                .rotationEffect(.degrees(angle))
                        }
                        .allowsHitTesting(false)
                    }
                    if let bearing {
                        if let spread, spread > 0 {
                            Wedge(bearing: bearing, spread: spread, radius: r)
                                .fill(tint.opacity(0.16))
                            Wedge(bearing: bearing, spread: spread, radius: r)
                                .stroke(tint.opacity(0.5), lineWidth: 1)
                        }
                        BearingLine(bearing: bearing, radius: r)
                            .stroke(tint, lineWidth: 1.5)
                        Circle()
                            .fill(tint)
                            .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                            .frame(width: 9, height: 9)
                            .offset(x: r * 0.66 * sin(bearing * .pi / 180), y: -r * 0.66 * cos(bearing * .pi / 180))
                    }
                }
                .rotationEffect(.degrees(-(heading ?? 0)))
                .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy), value: heading)
                .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle), value: bearing)
                PulseRing(trigger: pulse, color: tint.opacity(0.6), lineWidth: 1.5, from: 0.1, to: 1)
                    .frame(width: r * 2, height: r * 2)
                // You, in the middle: an arrow pointing the way the phone faces, or a dot without a compass.
                if heading != nil {
                    PhoneArrow().fill(Theme.textPrimary).frame(width: 11, height: 15)
                } else {
                    Circle().fill(Theme.textPrimary).frame(width: 7, height: 7)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CardinalTicks: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        for i in 0..<4 {
            let a = Double(i) * .pi / 2
            let dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
            p.move(to: CGPoint(x: c.x + dx * (radius - 4), y: c.y + dy * (radius - 4)))
            p.addLine(to: CGPoint(x: c.x + dx * (radius + 4), y: c.y + dy * (radius + 4)))
        }
        return p
    }
}

private struct Wedge: Shape {
    let bearing: Double
    let spread: Double
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: radius, startAngle: .degrees(bearing - spread - 90),
                 endAngle: .degrees(bearing + spread - 90), clockwise: false)
        p.closeSubpath()
        return p
    }
}

private struct BearingLine: Shape {
    let bearing: Double
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a = bearing * .pi / 180
        p.move(to: c)
        p.addLine(to: CGPoint(x: c.x + radius * CGFloat(sin(a)), y: c.y - radius * CGFloat(cos(a))))
        return p
    }
}

/// The phone: a small arrowhead pointing up.
private struct PhoneArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.22))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Readouts

/// One readout for `FoxReadoutGrid`.
struct FoxCell {
    let label: String
    let value: String
    var unit: String? = nil
    var sub: String? = nil
}

/// Four readouts in a 2 × 2 grid and a wide one underneath (AB `.cells2`).
struct FoxReadoutGrid<Bottom: View>: View {
    let cells: [FoxCell]
    @ViewBuilder let bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                if row > 0 { PanelDivider() }
                ReadoutRow {
                    cell(row * 2)
                    CellDivider()
                    cell(row * 2 + 1)
                }
            }
            PanelDivider()
            bottom
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .instrumentPanel()
    }

    @ViewBuilder private func cell(_ i: Int) -> some View {
        if cells.indices.contains(i) {
            let c = cells[i]
            ReadoutCell(c.label, value: c.value, unit: c.unit, sub: c.sub)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }
}

/// The wide cell under the grid: a label, an optional small meter and a line.
struct FoxWideCell: View {
    let label: String
    var lit: Int? = nil
    var of: Int = 8
    var tint: Color = Theme.ok
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CardLabel(label)
            HStack(spacing: 6) {
                if let lit { SegmentMeter(lit: lit, of: of, tint: tint, size: .xs) }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension FoxWideCell {
    /// FIXES: readings taken with a GPS fix, which the signal-trail bearing
    /// is fitted from (it needs 4, spread over 15 m).
    static func fixes(_ count: Int, bearing: Double?) -> FoxWideCell {
        let text: String
        if bearing != nil {
            text = "\(count) fixes · bearing from your walk"
        } else if count < 4 {
            text = "\(count) of 4 for a bearing"
        } else {
            text = "\(count) fixes · walk wider (15 m+)"
        }
        return FoxWideCell(label: "Fixes", lit: min(count, 4), of: 4, tint: Theme.ok, text: text)
    }
}

/// The radar and the readouts side by side, the same height.
struct FoxInstrumentRow<Radar: View, Readouts: View>: View {
    @ViewBuilder let radar: Radar
    @ViewBuilder let readouts: Readouts

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            radar.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            readouts.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Instruction

/// The one plain-English line: "**Getting warmer.** Head north-east…".
struct FoxInstructionLine: View {
    let lead: String
    let rest: String

    init(_ line: (lead: String, rest: String)) {
        lead = line.lead
        rest = line.rest
    }

    var body: some View {
        (Text(lead).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
         + Text(" " + rest).foregroundStyle(Theme.textSecondary))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, 2)
    }
}

// MARK: - Keys

/// The key row pinned at the bottom of a hunt: the first key is half as
/// wide again as the others (PING NOW / MARK / SOUND / END in AB/06).
struct FoxKeyBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FirstWideLayout { content }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 10)
            .padding(.bottom, 6)
            // Solid under the keys (a disabled key is see-through), fading in above them.
            .background {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .bottom)
                        .frame(height: 10)
                    Theme.bg
                }
                .ignoresSafeArea()
            }
    }
}

/// Lays keys in a row: the first gets 1.5 shares of the width, the rest one
/// each; all as tall as the tallest.
private struct FirstWideLayout: Layout {
    var spacing: CGFloat = 6

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let shares = 1.5 + Double(count - 1)
        let free = max(0, total - spacing * CGFloat(count - 1))
        return (0..<count).map { i in free * CGFloat((i == 0 && count > 1 ? 1.5 : 1) / shares) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? CGFloat(subviews.count) * 80
        let w = widths(total, count: subviews.count)
        let h = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width, count: subviews.count)
        var x = bounds.minX
        for (view, width) in zip(subviews, w) {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// The haptic Geiger ticks on or off, shared by every hunt.
struct TicksKey: View {
    @AppStorage(TicksKey.storageKey) private var on = true
    static let storageKey = "hunt.ticks"

    var body: some View {
        StatusKey("Ticks", symbol: "waveform.path.ecg", led: on ? .on : .off) { on.toggle() }
            .accessibilityHint("Geiger-counter taps that speed up as you get closer")
    }
}

/// A ping key with its cooldown ("PING NOW" / "PING 12 S").
struct PingKey: View {
    let lastPing: Date?
    let cooldown: TimeInterval
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let wait = lastPing.map { Int((cooldown - ctx.date.timeIntervalSince($0)).rounded(.up)) } ?? 0
            StatusKey(wait > 0 ? "Ping \(wait) s" : "Ping now", symbol: "scope", primary: true, action: action)
                .disabled(!enabled)
        }
    }
}

// MARK: - Which radio

extension Radio {
    /// "via STAY", "practice radio", "no node": the second half of a hunt's
    /// title line, saying which radio hears the fox.
    var huntVia: String {
        switch source {
        case .practice: return "practice radio"
        case .none: return "no node"
        case .bluetooth:
            guard isReady else { return statusText.lowercased() }
            return "via " + (session.myNode.map { session.label(for: $0) } ?? "your node")
        }
    }
}

// MARK: - Previews

#Preview("Fox instrument") {
    // FoxTracker.Sample has no public initialiser: the preview shows the listening state.
    let samples: [FoxTracker.Sample] = []
    return ScrollView {
        VStack(spacing: 8) {
            FoxTargetCard(network: .meshtastic, fox: "ZEUZ", detail: "Zeus the Fox", code: "FOX7")
            FoxSignalPanel(network: .meshtastic, samples: samples, best: samples.last, listening: "Listening…")
            FoxInstrumentRow {
                FoxBearingRadar(bearing: 47, spread: 20, distance: 1200, tint: Theme.meshtastic)
            } readouts: {
                FoxReadoutGrid(cells: [FoxCell(label: "Elapsed", value: "12:41"), FoxCell(label: "Pings", value: "38"),
                                       FoxCell(label: "Best", value: "−1.0", unit: "dB"),
                                       FoxCell(label: "Hops", value: "0", sub: "heard direct")]) {
                    FoxWideCell(label: "Fixes", lit: 6, text: "6 of 8 for a good fix")
                }
            }
            FoxInstructionLine(("Getting warmer.", "Head north-east (047°), about 1.2 km."))
        }
        .padding()
    }
    .safeAreaInset(edge: .bottom) {
        FoxKeyBar {
            StatusKey("Ping now", symbol: "scope", primary: true)
            StatusKey("Found it", symbol: "flag.checkered")
            TicksKey()
            StatusKey("End", symbol: "xmark")
        }
    }
    .screen()
}
