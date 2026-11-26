import SwiftUI

// MARK: - Screen background

/// The flat near-black behind every screen (AB `--bg`). Texture lives on
/// instrument panels, not the screen.
struct ScreenBackground: View {
    var body: some View {
        Theme.bg.ignoresSafeArea()
    }
}

/// A fine grid of faint white dots: the instrument-panel texture (AB `.inst`:
/// 1 pt dots at 3.5% on a 10 pt pitch). Drawn once.
struct DotGrid: View {
    var spacing: CGFloat = 10
    var opacity: Double = 0.035
    var dot: CGFloat = 2

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            var dots = Path()
            var x: CGFloat = 3
            while x < size.width {
                var y: CGFloat = 3
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(Color.white.opacity(opacity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Thin horizontal lines. Kept for callers of the old theme; AB panels no
/// longer use them.
struct Scanlines: View {
    var spacing: CGFloat = 3
    var opacity: Double = 0.045

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            var y: CGFloat = 0
            var path = Path()
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(Color.black.opacity(opacity)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The background behind a whole screen.
    func screen() -> some View {
        background(ScreenBackground())
    }
}

// MARK: - Panels

/// How much a panel stands out.
enum PanelStyle {
    /// The everyday card.
    case standard
    /// A hero card: an instrument panel with the dot grid.
    case hero
    /// A row inside a list: tighter padding.
    case row
    /// No padding: the caller lays out edge to edge (groups of rows, maps).
    case inset
    /// A recessed well, for inputs, charts and raw data.
    case well

    var padding: CGFloat {
        switch self {
        case .standard: return 14
        case .hero: return 14
        case .row: return 12
        case .inset: return 0
        case .well: return 12
        }
    }

    var radius: CGFloat {
        switch self {
        case .well: return Theme.Radius.key + 1
        default: return Theme.Radius.m
        }
    }
}

/// The AB panel: a flat `surface1` card with a 7% white hairline and 12 pt
/// continuous corners. Hero panels add the instrument dot grid. No glow, no
/// shadow: depth comes from surface steps.
struct FieldPanel: ViewModifier {
    let style: PanelStyle

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: style.radius, style: .continuous) }

    private var fill: Color {
        switch style {
        case .well: return Theme.well
        default: return Theme.surface1
        }
    }

    private var stroke: Color {
        style == .well ? Theme.hairlineStrong : Theme.hairline
    }

    func body(content: Content) -> some View {
        content
            .padding(style.padding)
            .background {
                ZStack {
                    shape.fill(fill)
                    if style == .hero {
                        DotGrid().clipShape(shape)
                    }
                }
            }
            .overlay(shape.strokeBorder(stroke, lineWidth: Theme.Stroke.hairline))
    }
}

extension View {
    /// The standard card (kept from the original theme; same call sites).
    func panel() -> some View { modifier(FieldPanel(style: .standard)) }

    /// A card with a chosen emphasis.
    func panel(_ style: PanelStyle) -> some View { modifier(FieldPanel(style: style)) }
}

// MARK: - Dividers and inputs

/// A hairline between rows in a group.
struct FieldDivider: View {
    var inset: CGFloat = 56

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

extension View {
    /// Text field chrome: mono type on a `surface1` well with a 12% hairline.
    func fieldInput() -> some View {
        self
            .font(Theme.Fonts.data)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.key + 1, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key + 1, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    }
}

// MARK: - System List and Form restyling

extension View {
    /// A `Form` or grouped `List` in AB colours. Sections still need
    /// `.fieldSection()` for their row backgrounds.
    func fieldForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .screen()
            .tint(Theme.accent)
            .toggleStyle(FieldToggleStyle())
            .foregroundStyle(Theme.textPrimary)
    }

    /// Plain `List` whose rows draw their own cards (see `fieldListRow()`).
    func fieldList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .screen()
            .tint(Theme.accent)
    }

    /// A row in a `fieldList()`: clear cell, no separator, card-sized insets.
    func fieldListRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: Theme.Space.edge, bottom: 5, trailing: Theme.Space.edge))
    }
}

extension Section where Parent: View, Content: View, Footer: View {
    /// `surface1` row backgrounds and hairline separators for a Form section.
    func fieldSection() -> some View {
        self
            .listRowBackground(Theme.surface1)
            .listRowSeparatorTint(Theme.hairline)
    }
}
