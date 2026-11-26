import SwiftUI
import WildcatRadioCore

/// The hero instrument: a radar scope with a sweeping beam, a signal arc
/// that shifts blue → amber → red as you close in, a needle, and the
/// reading in the middle. Shared by Fox Hunt, Solo hunt and Daily Fox.
///
/// Everything is passed in as plain values, so the models stay untouched.
struct SignalScope: View {
    let title: String
    let rssi: Int?
    let snr: Double?
    let score: Double
    let time: Date?
    let trend: FoxTracker.Trend
    /// Changes with every reading; fires the pulse ring.
    let pulse: Int
    /// Shown in the middle while there is no reading yet.
    var listeningHint: String = "Waiting to hear the fox directly…"
    /// A running clock in the corner, if the hunt is timed.
    var started: Date? = nil
    /// Bottom line under the number.
    var footer: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 62

    private var hasReading: Bool { rssi != nil || snr != nil }
    private var tint: Color { hasReading ? Theme.signal(score) : Theme.amberDim }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                CardLabel(title)
                Spacer()
                if let started {
                    Text(started, style: .timer)
                        .font(Theme.Fonts.dataSmall)
                        .foregroundStyle(Theme.mute)
                        .monospacedDigit()
                }
                TrendChip(trend: trend, hasReading: hasReading)
            }
            dial
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: 300)
            if let footer {
                Text(footer)
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(Theme.mute)
                    .multilineTextAlignment(.center)
            }
        }
        .panel(.hero)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard hasReading else { return "\(title). Listening. \(listeningHint)" }
        var parts = ["\(title). Signal \(Int(score)) of 100"]
        if let rssi { parts.append("\(rssi) dBm") }
        parts.append(trendWord)
        return parts.joined(separator: ", ")
    }

    private var trendWord: String {
        switch trend {
        case .warmer: return "warmer"
        case .colder: return "colder"
        case .steady: return "steady"
        case .none: return "first reading"
        }
    }

    // MARK: Dial

    private var dial: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let arcWidth = max(12, side * 0.06)
            ZStack {
                // Glass
                Circle()
                    .fill(RadialGradient(colors: [Theme.surface3, Theme.bg], center: .center,
                                         startRadius: side * 0.05, endRadius: side * 0.55))
                // Rings and crosshair
                ForEach([0.30, 0.52, 0.74], id: \.self) { f in
                    Circle().stroke(Theme.hairline, lineWidth: 1)
                        .frame(width: side * f, height: side * f)
                }
                Crosshair().stroke(Theme.hairline, lineWidth: 1)
                    .frame(width: side * 0.78, height: side * 0.78)
                // Sweep: driven by the clock, so it always runs (a repeatForever
                // animation started on appear can silently fail inside pushed screens).
                // With Reduce Motion there's no beam at all: a frozen wedge reads as a glitch.
                if !reduceTransparency && !reduceMotion {
                    TimelineView(.animation) { ctx in
                        let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
                        ZStack {
                            Circle()
                                .fill(AngularGradient(colors: [tint.opacity(0.0), tint.opacity(0.0), tint.opacity(0.0), tint.opacity(0.05), tint.opacity(0.28)],
                                                      center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
                            // The beam's leading edge, where the gradient is brightest.
                            Capsule()
                                .fill(LinearGradient(colors: [tint.opacity(0.05), tint.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: side * 0.39, height: 1.5)
                                .offset(x: side * 0.195)
                        }
                        .frame(width: side * 0.78, height: side * 0.78)
                        .rotationEffect(.degrees(angle))
                    }
                    .opacity(hasReading ? 0.9 : 0.5)
                    .allowsHitTesting(false)
                }
                // Pulse on each reading
                PulseRing(trigger: pulse, color: tint, lineWidth: 2, from: 0.4, to: 1.0)
                    .frame(width: side * 0.78, height: side * 0.78)
                // Arc track and fill
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(Theme.surface3, style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.1, to: 0.1 + 0.8 * max(0, min(100, hasReading ? score : 0)) / 100)
                    .stroke(AngularGradient(colors: [Theme.cool, Theme.amber, Theme.hot], center: .center,
                                            startAngle: .degrees(36), endAngle: .degrees(324)),
                            style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .shadow(color: tint.opacity(0.55), radius: 10)
                    .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle), value: score)
                // Tick marks along the arc
                ArcTicks().stroke(Theme.textQuaternary, lineWidth: 1)
                    .frame(width: side - arcWidth * 2.6, height: side - arcWidth * 2.6)
                // Needle
                Needle()
                    .fill(tint)
                    .frame(width: 6, height: side * 0.36)
                    .offset(y: -side * 0.18)
                    .rotationEffect(.degrees(hasReading ? -144 + 288 * max(0, min(100, score)) / 100 : -144))
                    .shadow(color: tint.opacity(0.8), radius: 6)
                    .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle), value: score)
                    .opacity(hasReading ? 1 : 0.35)
                readout(side: side)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func readout(side: CGFloat) -> some View {
        VStack(spacing: 2) {
            if hasReading {
                Text(rssi.map { "\($0)" } ?? snr.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: numberSize, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .glow(tint, radius: 14, opacity: 0.55)
                Text(rssi != nil ? "dBm · SNR \(snr.map { String(format: "%.1f", $0) } ?? "--")" : "SNR dB")
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(Theme.inkSoft)
                if let time {
                    Text(time, style: .relative)
                        .font(Theme.Fonts.labelSmall)
                        .foregroundStyle(Theme.mute)
                        .monospacedDigit()
                }
            } else {
                Text("LISTENING")
                    .font(Theme.Fonts.title)
                    .tracking(2)
                    .foregroundStyle(Theme.amber)
                    .glow(Theme.amber)
                Text(listeningHint)
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(Theme.mute)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, side * 0.16)
        .frame(width: side * 0.7)
    }
}

/// "WARMER" / "COLDER" / "STEADY" in its signal colour.
struct TrendChip: View {
    let trend: FoxTracker.Trend
    var hasReading: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (text, color): (String, Color) = {
            switch trend {
            case .warmer: return ("WARMER", Theme.hot)
            case .colder: return ("COLDER", Theme.cool)
            case .steady: return ("STEADY", Theme.mute)
            case .none: return (hasReading ? "FIRST" : "—", Theme.mute)
            }
        }()
        Chip(text, color: color)
            .id(text)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.pop), value: text)
    }
}

// MARK: - Shapes

struct Crosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Short radial ticks along the 288° gauge arc.
struct ArcTicks: Shape {
    var count: Int = 24

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0...count {
            let f = Double(i) / Double(count)
            // Same sweep as the arc: from 126° (bottom-left) clockwise through 288°.
            let a = (126 + 288 * f) * .pi / 180
            let long = i % 6 == 0
            let inner = r - (long ? 8 : 4)
            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
        }
        return p
    }
}

/// A slim pointer with a rounded base; drawn pointing up from the centre.
struct Needle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 3), control: CGPoint(x: rect.midX, y: rect.maxY + 3))
        p.closeSubpath()
        return p
    }
}

// MARK: - Compass

/// A bearing arrow in a dial that turns with the phone's heading.
struct CompassDial: View {
    /// Where to go, degrees from true north; nil shows a question mark.
    let bearing: Double?
    /// The phone's heading, if the compass is available.
    let heading: Double?
    var size: CGFloat = 72
    var tint: Color = Theme.amber
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Theme.surface3, Theme.bg], center: .center, startRadius: 0, endRadius: size * 0.55))
            Circle().stroke(tint.opacity(0.3), lineWidth: 1.5)
            CompassTicks().stroke(tint.opacity(0.45), lineWidth: 1)
                .padding(3)
                .rotationEffect(.degrees(-(heading ?? 0)))
                .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy), value: heading)
            Text("N")
                .font(.system(size: size * 0.14, weight: .bold, design: .monospaced))
                .foregroundStyle(tint.opacity(0.8))
                .offset(y: -size * 0.36)
                .rotationEffect(.degrees(-(heading ?? 0)))
                .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy), value: heading)
            if let bearing {
                Image(systemName: "location.north.fill")
                    .font(.system(size: size * 0.40, weight: .bold))
                    .foregroundStyle(tint)
                    .glow(tint, radius: 8)
                    .rotationEffect(.degrees(bearing - (heading ?? 0)))
                    .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy), value: heading)
                    .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle), value: bearing)
            } else {
                Image(systemName: "questionmark")
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(Theme.mute)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bearing.map { "Bearing \(Int($0)) degrees" } ?? "No bearing yet")
    }
}

struct CompassTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<16 {
            let a = Double(i) / 16 * 2 * .pi
            let len: CGFloat = i % 4 == 0 ? 6 : 3
            p.move(to: CGPoint(x: c.x + cos(a) * (r - len), y: c.y + sin(a) * (r - len)))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
        }
        return p
    }
}
