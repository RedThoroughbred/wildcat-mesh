import SwiftUI

// MARK: - Section label

/// "WITH FRIENDS" style header: tracked mono caps in tertiary grey, with an
/// optional trailing detail (AB `.sec`). For a numbered module header use
/// `ModuleHeader`.
struct SectionLabel: View {
    let title: String
    var detail: String? = nil

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Theme.Fonts.label)
                .tracking(Theme.labelTracking)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small caps label inside a card ("FOX", "SIGNAL"). Grey unless a
/// colour means something (a network, a status).
struct CardLabel: View {
    let title: String
    var tint: Color = Theme.textTertiary

    init(_ title: String, tint: Color = Theme.textTertiary) {
        self.title = title
        self.tint = tint
    }

    var body: some View {
        Text(title.uppercased())
            .font(Theme.Fonts.label)
            .tracking(Theme.labelTracking)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Stat tiles

/// A big thin number with a small label. `compact` for rows of four.
/// (For cells inside an instrument panel, use `ReadoutCell`.)
struct StatTile: View {
    let label: String
    let value: String
    var tint: Color = Theme.textPrimary
    var unit: String? = nil
    var compact: Bool = false
    @ScaledMetric(relativeTo: .title) private var bigSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title3) private var smallSize: CGFloat = 21

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            Text(label.uppercased())
                .font(Theme.Fonts.labelSmall)
                .tracking(Theme.labelTracking)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: compact ? smallSize : bigSize, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit)
                        .font(Theme.Fonts.raw)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 10 : 12)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(unit.map { " \($0)" } ?? "")")
    }
}

/// The original four-up stat used on Explore, Territory and the Nodedex.
struct MiniStat: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        StatTile(label: label, value: value, tint: tint, compact: true)
    }
}

// MARK: - Pills and chips

/// "● Practice" status capsule with an optional live pulse.
struct StatusPill: View {
    let text: String
    var color: Color = Theme.textTertiary
    var live: Bool = false
    var pulse: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var blipScale: CGFloat = 1
    @State private var blipOpacity: Double = 0

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(color.opacity(blipOpacity), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .scaleEffect(blipScale)
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(color.opacity(live ? (breathing ? 0.22 : 0.10) : 0)).padding(-3))
            }
            Text(text)
                .font(Theme.Fonts.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Theme.surface1, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        .onAppear {
            guard live, !reduceMotion else { return }
            withAnimation(Theme.Motion.breathe()) { breathing = true }
        }
        .onChange(of: live) { _, isLive in
            if isLive, !reduceMotion {
                withAnimation(Theme.Motion.breathe()) { breathing = true }
            } else {
                withAnimation(Theme.Motion.fade) { breathing = false }
            }
        }
        .onChange(of: pulse) { _, _ in blip() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    /// A ring that leaps out of the dot: a packet was heard.
    private func blip() {
        if reduceMotion {
            blipOpacity = 0.9
            withAnimation(Theme.Motion.fade.delay(0.15)) { blipOpacity = 0 }
            return
        }
        blipScale = 1
        blipOpacity = 0.95
        withAnimation(.easeOut(duration: 0.7)) {
            blipScale = 3.2
            blipOpacity = 0
        }
    }
}

/// A solid capsule with dark text ("FOUND", "LIVE"). Neutral white unless
/// a colour means something.
struct Chip: View {
    let text: String
    var color: Color = Theme.accent
    var small: Bool = false

    init(_ text: String, color: Color = Theme.accent, small: Bool = false) {
        self.text = text
        self.color = color
        self.small = small
    }

    var body: some View {
        Text(text.uppercased())
            .font(small ? Theme.Fonts.labelSmall.weight(.semibold) : Theme.Fonts.label.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, small ? 6 : 8)
            .padding(.vertical, small ? 2 : 3)
            .background(color, in: RoundedRectangle(cornerRadius: Theme.Radius.xs + 1, style: .continuous))
            .lineLimit(1)
    }
}

/// An outlined mono tag ("REPEATER", "2 HOPS"), AB `.tag`: grey with a 12%
/// hairline, or a meaningful colour with a 30% stroke.
struct Tag: View {
    let text: String
    var color: Color = Theme.textSecondary

    init(_ text: String, color: Color = Theme.textSecondary) {
        self.text = text
        self.color = color
    }

    private var stroke: Color {
        color == Theme.textSecondary || color == Theme.mute ? Theme.hairlineStrong : color.opacity(0.3)
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous).strokeBorder(stroke, lineWidth: 1))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A radio setting as a mono chip ("910.525 MHz", "BW 62.5", "3 hops"), AB
/// `.chip`: the value in primary text, an optional lead or unit in tertiary.
/// Both network tabs and the RNode console draw their radio with these.
struct RadioChip: View {
    let value: String
    var lead: String? = nil
    var unit: String? = nil

    init(_ value: String, lead: String? = nil, unit: String? = nil) {
        self.value = value
        self.lead = lead
        self.unit = unit
    }

    var body: some View {
        HStack(spacing: 3) {
            if let lead { Text(lead).foregroundStyle(Theme.textTertiary) }
            Text(value).foregroundStyle(Theme.textPrimary)
            if let unit { Text(unit).foregroundStyle(Theme.textTertiary) }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        .fixedSize()
    }
}

// MARK: - Icon tile

/// A symbol in an outlined square, the leading element of rows and cards
/// (AB `.glyph`). Neutral grey by default; pass a network or status colour
/// only when it means something.
struct IconTile: View {
    let symbol: String
    var tint: Color? = nil
    var size: CGFloat = 30

    private var glyph: Color { tint ?? Theme.textSecondary }
    private var stroke: Color { tint.map { $0.opacity(0.28) } ?? Theme.hairlineStrong }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .regular))
            .foregroundStyle(glyph)
            .frame(width: size, height: size)
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Four-letter node name on a coloured plate (amber direct, grey relayed,
/// blue internet).
struct NamePlate: View {
    let name: String
    var color: Color = Theme.amber

    var body: some View {
        Text(name)
            .font(Theme.Fonts.dataBold)
            .foregroundStyle(Theme.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 54, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityLabel(name)
    }
}

// MARK: - Rows

/// A list row (AB `.r`): outlined glyph, title, optional subtitle, trailing
/// detail, chevron. `tint` colours the glyph only when it means something.
struct FieldRow: View {
    let symbol: String
    var tint: Color? = nil
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var chevron: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if chevron { Chevron() }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// The trailing disclosure mark.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textQuaternary)
            .accessibilityHidden(true)
    }
}

/// "Key … value" on detail screens.
struct KeyValueRow: View {
    let key: String
    let value: String
    var tint: Color = Theme.textPrimary

    init(_ key: String, _ value: String, tint: Color = Theme.textPrimary) {
        self.key = key
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(Theme.Fonts.data)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// A group of rows in one inset panel. Put `FieldDivider()` between rows.
struct FieldGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .panel(.inset)
    }
}

/// A row that pushes a destination, drawn as a plain card (no system chevron).
struct NavRow<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    var body: some View {
        NavigationLink(destination: destination, label: label)
            .buttonStyle(.rowPress)
    }
}

// MARK: - Buttons

/// AB buttons: primary (white fill, dark text), secondary (`surface2`, 12%
/// hairline), destructive (red) and quiet (grey text).
struct FieldButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, quiet }
    enum Size { case large, regular, small }

    var kind: Kind = .primary
    var size: Size = .large
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat {
        switch size {
        case .large: return 48
        case .regular: return 40
        case .small: return 32
        }
    }

    private var font: Font {
        switch size {
        case .large: return .system(.body, weight: .semibold)
        case .regular: return .system(.subheadline, weight: .semibold)
        case .small: return .system(.footnote, weight: .semibold)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onAccent
        case .secondary: return Theme.textPrimary
        case .destructive: return Theme.alert
        case .quiet: return Theme.textSecondary
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: size == .large ? 12 : 10, style: .continuous)
        return configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(size == .small ? 1 : 2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, size == .small ? 12 : 18)
            .padding(.vertical, 6)
            .frame(minHeight: height)
            .frame(maxWidth: size == .small ? nil : .infinity)
            .background {
                switch kind {
                case .primary: shape.fill(Theme.accent)
                case .secondary: shape.fill(Theme.surface2)
                case .destructive: shape.fill(Theme.alert.opacity(0.10))
                case .quiet: shape.fill(Color.clear)
                }
            }
            .overlay {
                switch kind {
                case .primary: shape.strokeBorder(Theme.accent, lineWidth: 1)
                case .secondary: shape.strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                case .destructive: shape.strokeBorder(Theme.alert.opacity(0.35), lineWidth: 1)
                case .quiet: shape.strokeBorder(Color.clear, lineWidth: 0)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

/// A row or card that dims and shrinks slightly while pressed.
struct RowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == FieldButtonStyle {
    static var fieldPrimary: FieldButtonStyle { FieldButtonStyle(kind: .primary, size: .large) }
    static var fieldSecondary: FieldButtonStyle { FieldButtonStyle(kind: .secondary, size: .large) }
    static var fieldDestructive: FieldButtonStyle { FieldButtonStyle(kind: .destructive, size: .large) }
    static var fieldQuiet: FieldButtonStyle { FieldButtonStyle(kind: .quiet, size: .regular) }
    static func field(_ kind: FieldButtonStyle.Kind, _ size: FieldButtonStyle.Size = .large) -> FieldButtonStyle {
        FieldButtonStyle(kind: kind, size: size)
    }
}

extension ButtonStyle where Self == RowPressStyle {
    static var rowPress: RowPressStyle { RowPressStyle() }
}

/// Switches are green when on (white would hide the knob).
struct FieldToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Theme.ok)
    }
}

// MARK: - Segmented control

/// A segmented control: the selected segment is a white key that slides.
struct FieldSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    guard !selected else { return }
                    Haptics.selection()
                    withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(Theme.Fonts.footnote.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.onAccent : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.accent)
                                    .matchedGeometryEffect(id: "segment", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    }
}

// MARK: - Labeled text field

/// "HUNT CODE" over a big mono text field.
struct LabeledField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardLabel(title)
            TextField(prompt, text: $text)
                .font(.system(size: size, weight: .regular, design: .monospaced))
                .autocorrectionDisabled()
                .fieldInput()
        }
    }
}

// MARK: - Empty state, toast, notice

/// Nothing here yet: a symbol, a line, and optionally something to do.
struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 1).frame(width: 84, height: 84)
                Circle().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4])).frame(width: 60, height: 60)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(text)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.field(.secondary, .regular))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}

/// A short message across the top of a screen. Info is neutral; success,
/// warn and danger carry their status colour.
struct ToastBanner: View {
    enum Kind { case info, success, warn, danger }
    let text: String
    var kind: Kind = .info

    private var color: Color {
        switch kind {
        case .info: return Theme.surface3
        case .success: return Theme.ok
        case .warn: return Theme.amber
        case .danger: return Theme.alert
        }
    }

    private var foreground: Color { kind == .info ? Theme.textPrimary : Theme.onAccent }

    private var symbol: String {
        switch kind {
        case .info: return "dot.radiowaves.left.and.right"
        case .success: return "checkmark.seal.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(text).font(Theme.Fonts.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            .strokeBorder(kind == .info ? Theme.hairlineStrong : Color.clear, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.4), radius: 14, y: 4)
    }
}

/// An inline hint or caution inside a card. Neutral grey by default (AB
/// hint box); pass a colour for a real warning or error.
struct Notice: View {
    let text: String
    var color: Color? = nil
    var symbol: String = "exclamationmark.triangle"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(text).font(Theme.Fonts.footnote).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color ?? Theme.textSecondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((color ?? Color.white).opacity(color == nil ? 0.03 : 0.09), in: shape)
        .overlay(shape.strokeBorder(color.map { $0.opacity(0.25) } ?? Theme.hairlineStrong,
                                    style: StrokeStyle(lineWidth: 1, dash: color == nil ? [3, 3] : [])))
    }
}

// MARK: - Game card

/// The emblem of a game: a symbol in an outlined ring on a dark disc.
struct Emblem: View {
    let symbol: String
    var tint: Color? = nil
    var size: CGFloat = 64

    private var glyph: Color { tint ?? Theme.textPrimary }

    var body: some View {
        ZStack {
            Circle().fill(Theme.surface2)
            Circle().strokeBorder(tint.map { $0.opacity(0.3) } ?? Theme.hairlineStrong, lineWidth: 1)
            Circle().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .padding(size * 0.12)
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .regular))
                .foregroundStyle(glyph)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A big card on Play: emblem, name, one line, and an optional trailing detail.
struct HeroCard: View {
    let symbol: String
    let title: String
    let text: String
    var tint: Color? = nil
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Emblem(symbol: symbol, tint: tint, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    CardLabel(title, tint: tint ?? Theme.textSecondary)
                    if let detail {
                        Spacer(minLength: 6)
                        Text(detail).font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(text)
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Chevron()
        }
        .panel(.hero)
        .accessibilityElement(children: .combine)
    }
}
