import SwiftUI

/// The AB design tokens ("Mission Control × Field Instrument"): neutral
/// dark greys, white hairlines, SF Pro prose and SF Mono data. Colour means
/// something: amber is Meshtastic, blue is MeshCore, green is OK, red is an
/// alert. Everything else is grey.
///
/// Source of truth: docs/design/ui-directions/AB/ab.css. The original Field
/// Terminal names (`bg`, `panel`, `amber`, `ink`, `mute`, `cool`, `hot`,
/// `ok`, `hairline`, `mono(_:_:)`, `Fonts.*`) are kept and remapped so every
/// call site still compiles and shifts to AB; new code should prefer the
/// semantic names (`textPrimary`, `meshcore`, `surface2`, ...).
enum Theme {
    // MARK: Surfaces (four levels, darkest first)

    static let bg = Color(hex: 0x09090b)                  // --bg
    static let surface1 = Color(hex: 0x111114)            // --s1: panels, rows
    static let surface2 = Color(hex: 0x17171b)            // --s2: chips, bubbles, buttons
    static let surface3 = Color(hex: 0x1f1f24)            // --s3: selected, pressed
    /// Recessed wells: hex dumps, raw data, inputs.
    static let well = Color(hex: 0x0d0d10)
    static let panel = surface1
    static let panel2 = surface2

    // MARK: Text

    static let textPrimary = Color(hex: 0xededf0)         // --t1
    static let textSecondary = Color(hex: 0xa1a1aa)       // --t2
    static let textTertiary = Color(hex: 0x6b6b75)        // --t3: labels, units, raw lines
    static let textQuaternary = Color(hex: 0x46464e)      // --t4: chevrons, offsets, off LEDs

    /// Old names, remapped: `ink` is primary text, `inkSoft` a step down,
    /// `mute` secondary text (subtitles), `muteDim` tertiary.
    static let ink = textPrimary
    static let inkSoft = Color(hex: 0xc9c9cf)
    static let mute = textSecondary
    static let muteDim = textTertiary

    // MARK: Networks

    /// Meshtastic. Use only for Meshtastic things.
    static let meshtastic = Color(hex: 0xffb000)          // --mt
    /// MeshCore. Use only for MeshCore things.
    static let meshcore = Color(hex: 0x3aa0ff)            // --mc
    /// 12% washes for tinted fills (my bubble, selected row).
    static let meshtasticWash = meshtastic.opacity(0.12)
    static let meshcoreWash = meshcore.opacity(0.12)
    /// RNode (Reticulum). Use only for RNode things.
    static let rnode = Color(hex: 0xb48cff)                // violet

    // MARK: Status

    static let ok = Color(hex: 0x3ecf8e)                  // --ok
    static let alert = Color(hex: 0xff5b50)               // --bad
    static let hot = alert
    static let danger = alert
    static let warn = meshtastic

    // MARK: Accent (old names)

    /// Amber stays #ffb000, which is now Meshtastic's colour. Shared
    /// components no longer default to it; pass it only where it means
    /// Meshtastic (or a deliberate highlight).
    static let amber = meshtastic
    static let amberBright = Color(hex: 0xffc53d)
    static let amberDim = Color(hex: 0xa87400)
    static let amberDeep = Color(hex: 0x604200)
    /// MeshCore blue under its old name.
    static let cool = meshcore

    /// The neutral accent: primary buttons, selected pills, app tint.
    static let accent = textPrimary
    /// Text on an `accent` fill.
    static let onAccent = Color(hex: 0x0a0a0b)

    // MARK: Lines

    /// Hairline strokes on panels and rows (white 7%).
    static let hairline = Color.white.opacity(0.07)       // --line
    /// Stronger hairline: glyph tiles, chips, buttons, keys (white 12%).
    static let hairlineStrong = Color.white.opacity(0.12) // --line2
    /// An unlit meter segment.
    static let segmentOff = Color(hex: 0x24242a)

    // MARK: Signal ramp (cold → warm → hot), 0...100

    /// Stops of the ramp: cold blue, a pale neutral in the middle (so the
    /// blend never turns muddy green), amber, then red.
    private static let rampStops: [(Double, (Double, Double, Double))] = [
        (0.00, (0.227, 0.627, 1.0)),    // meshcore blue
        (0.40, (0.929, 0.929, 0.941)),  // text primary
        (0.65, (1.0, 0.690, 0.0)),      // amber
        (1.00, (1.0, 0.357, 0.314)),    // alert
    ]

    /// The colour for a 0–100 signal score: blue when cold, amber as it
    /// warms, red when the fox is close.
    static func signal(_ score: Double) -> Color {
        let s = max(0, min(100, score)) / 100
        var lower = rampStops[0]
        var upper = rampStops[rampStops.count - 1]
        for i in 0..<(rampStops.count - 1) where s >= rampStops[i].0 && s <= rampStops[i + 1].0 {
            lower = rampStops[i]
            upper = rampStops[i + 1]
            break
        }
        let span = max(0.0001, upper.0 - lower.0)
        let t = (s - lower.0) / span
        let a = lower.1, b = upper.1
        return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }

    // MARK: Type

    /// Fixed-size SF Mono, for data that must line up.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The type scale: SF Pro for prose, SF Mono for data and labels. Styles
    /// built on text styles follow Dynamic Type; big readouts use
    /// `@ScaledMetric` in their views.
    enum Fonts {
        /// Section and cell labels: small caps mono, tracked (AB `.lab`).
        static let label: Font = .system(.caption2, design: .monospaced, weight: .medium)
        static let labelSmall: Font = .system(.caption2, design: .monospaced, weight: .medium)
        /// Row and card titles (AB `.r .t`).
        static let heading: Font = .system(.subheadline, weight: .semibold)
        /// Big words and codes: hunt codes, result titles.
        static let display: Font = .system(.largeTitle, design: .monospaced, weight: .regular)
        /// Screen-level titles: a node's name, a chapter.
        static let title: Font = .system(.title2, weight: .semibold)
        static let body: Font = .system(.body)
        static let callout: Font = .system(.callout)
        static let footnote: Font = .system(.footnote)
        /// Monospaced data at reading size.
        static let data: Font = .system(.subheadline, design: .monospaced)
        static let dataBold: Font = .system(.subheadline, design: .monospaced, weight: .semibold)
        static let dataSmall: Font = .system(.caption, design: .monospaced)
        /// Raw lines under prose: SNR, path, byte counts (AB `.raw`).
        static let raw: Font = .system(.caption2, design: .monospaced)
        static let button: Font = .system(.subheadline, weight: .semibold)
        /// Row subtitles (AB `.r .d`).
        static let detail: Font = .system(.footnote)
    }

    /// Letter spacing for uppercase mono labels (0.08em at 10.5 pt).
    static let labelTracking: CGFloat = 0.9

    // MARK: Spacing, radii, strokes

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        /// Gap between stacked cards on a screen.
        static let stack: CGFloat = 14
        /// Screen edge inset.
        static let edge: CGFloat = 16
        /// Row padding inside a panel (AB `.r`: 11 × 14).
        static let rowV: CGFloat = 11
        static let rowH: CGFloat = 14
    }

    enum Radius {
        /// Tags and number boxes.
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        /// Keys, buttons, hex wells.
        static let key: CGFloat = 9
        /// Panels (AB `.panel`).
        static let m: CGFloat = 12
        static let l: CGFloat = 14
        static let xl: CGFloat = 18
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let bold: CGFloat = 1.5
    }

    // MARK: Motion

    enum Motion {
        /// Quick UI response (chips, selection).
        static let snappy: Animation = .snappy(duration: 0.28)
        /// Cards and sheets settling.
        static let settle: Animation = .spring(response: 0.45, dampingFraction: 0.82)
        /// A celebratory overshoot.
        static let pop: Animation = .spring(response: 0.32, dampingFraction: 0.58)
        /// A plain fade, used when Reduce Motion is on.
        static let fade: Animation = .easeInOut(duration: 0.22)
        /// Slow breathing for live indicators.
        static func breathe(_ seconds: Double = 1.6) -> Animation {
            .easeInOut(duration: seconds).repeatForever(autoreverses: true)
        }
        /// `animation` unless Reduce Motion is on, then a fade.
        static func respecting(_ reduce: Bool, _ animation: Animation) -> Animation {
            reduce ? fade : animation
        }
    }
}

extension Color {
    /// An sRGB colour from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

/// The third radio type: an RNode, a LoRa modem for the Reticulum network. Not a `MeshNetwork`
/// (no chat, no nodes heard, no tab): a console reached from the radios sheet and Manage.
enum RNodeStyle {
    static let name = "RNode"
    static let color = Theme.rnode
    static let symbol = "circle.hexagongrid"
}

/// The two radio networks, for colour and naming in shared components.
enum MeshNetwork: String, CaseIterable, Identifiable, Hashable {
    case meshtastic, meshcore

    var id: String { rawValue }

    var color: Color { self == .meshtastic ? Theme.meshtastic : Theme.meshcore }
    /// 12% fill.
    var wash: Color { color.opacity(0.12) }
    /// 30% stroke for tags and glyph tiles.
    var stroke: Color { color.opacity(0.3) }
    /// "Meshtastic" / "MeshCore".
    var name: String { self == .meshtastic ? "Meshtastic" : "MeshCore" }
    /// "MT" / "MC".
    var short: String { self == .meshtastic ? "MT" : "MC" }
    /// The tab's SF Symbol.
    var symbol: String {
        self == .meshtastic ? "antenna.radiowaves.left.and.right" : "point.3.filled.connected.trianglepath.dotted"
    }
}
