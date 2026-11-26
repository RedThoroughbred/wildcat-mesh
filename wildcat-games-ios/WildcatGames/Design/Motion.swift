import SwiftUI

// MARK: - Pulse ring

/// A ring that expands and fades every time `trigger` changes: a packet
/// heard, a reading logged. Under Reduce Motion it flashes instead.
struct PulseRing: View {
    let trigger: Int
    var color: Color = Theme.textSecondary
    var lineWidth: CGFloat = 2
    var from: CGFloat = 0.9
    var to: CGFloat = 1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .stroke(color, lineWidth: lineWidth)
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        if reduceMotion {
            scale = 1
            opacity = 0.8
            withAnimation(.easeOut(duration: 0.5)) { opacity = 0 }
            return
        }
        scale = from
        opacity = 0.9
        withAnimation(.easeOut(duration: 1.1)) {
            scale = to
            opacity = 0
        }
    }
}

// MARK: - Celebration

/// Sparks bursting from the centre: "found it", a gift opening. Draws with
/// Canvas on a timeline for ~1.8 s after `trigger` changes. Under Reduce
/// Motion it shows a soft glow instead.
struct CelebrationBurst: View {
    let trigger: Int
    var colors: [Color] = [Theme.ok, Theme.ink, Theme.textSecondary]
    var count: Int = 70
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    private struct Spark {
        var angle: Double
        var speed: Double
        var size: Double
        var color: Int
        var spin: Double
    }

    private var sparks: [Spark] {
        var g = SeededGenerator(seed: UInt64(max(1, trigger)))
        return (0..<count).map { _ in
            Spark(angle: Double.random(in: 0..<(2 * .pi), using: &g),
                  speed: Double.random(in: 120...420, using: &g),
                  size: Double.random(in: 2.5...6, using: &g),
                  color: Int.random(in: 0..<max(1, colors.count), using: &g),
                  spin: Double.random(in: -3...3, using: &g))
        }
    }

    var body: some View {
        ZStack {
            if reduceMotion {
                if startedAt != nil {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.ok.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 180))
                        .transition(.opacity)
                }
            } else if let startedAt {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                    let t = timeline.date.timeIntervalSince(startedAt)
                    Canvas { context, size in
                        guard t < 1.9 else { return }
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let life = 1.7
                        let p = min(1, t / life)
                        let ease = 1 - pow(1 - p, 3)
                        for s in sparks {
                            let d = s.speed * ease * 0.9
                            let x = center.x + CGFloat(cos(s.angle) * d)
                            let y = center.y + CGFloat(sin(s.angle) * d) + CGFloat(220 * p * p)
                            let alpha = max(0, 1 - p * 1.1)
                            let r = CGFloat(s.size * (1 - p * 0.5))
                            var ctx = context
                            ctx.opacity = alpha
                            ctx.translateBy(x: x, y: y)
                            ctx.rotate(by: .radians(s.spin * t))
                            let rect = CGRect(x: -r, y: -r * 0.55, width: r * 2, height: r * 1.1)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: r * 0.3), with: .color(colors[s.color % colors.count]))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in
            withAnimation(Theme.Motion.fade) { startedAt = Date() }
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(Theme.Motion.fade) { startedAt = nil }
            }
        }
    }
}

/// A tiny deterministic random source so a burst looks the same each frame.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Glow text

extension View {
    /// Phosphor glow behind text or symbols.
    func glow(_ color: Color, radius: CGFloat = 10, opacity: Double = 0.6) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
    }

    /// Fades in and slides up slightly when it appears (a plain fade under
    /// Reduce Motion).
    func rise() -> some View {
        modifier(RiseIn())
    }
}

private struct RiseIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle)) { shown = true }
            }
    }
}

// MARK: - Haptic ticker

/// Geiger-counter ticks while hunting: faster and firmer as the signal
/// score climbs. Silent below `floor`, or when the last reading is stale.
struct HapticTicker: ViewModifier {
    let score: Double
    let active: Bool
    var floor: Double = 15

    /// Quantised so the loop restarts only when the rate really changes.
    private var bucket: Int { active && score >= floor ? Int(score / 8) : -1 }

    private var interval: Double {
        let s = max(0, min(100, score))
        // 2.4 s at the floor, 0.16 s at full scale.
        let t = (s - floor) / max(1, 100 - floor)
        return 2.4 - (2.4 - 0.16) * max(0, min(1, t))
    }

    func body(content: Content) -> some View {
        content.task(id: bucket) {
            guard bucket >= 0 else { return }
            let step = interval
            let intensity = CGFloat(0.3 + 0.6 * max(0, min(1, score / 100)))
            Haptics.prepare()
            while !Task.isCancelled {
                Haptics.tick(intensity)
                try? await Task.sleep(for: .seconds(step))
            }
        }
    }
}

extension View {
    /// Ticks the Taptic Engine like a Geiger counter while `active`.
    func hapticTicker(score: Double, active: Bool) -> some View {
        modifier(HapticTicker(score: score, active: active))
    }
}
