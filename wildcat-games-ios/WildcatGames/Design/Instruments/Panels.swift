import SwiftUI

// MARK: - Instrument panel

/// The AB instrument container (`.panel.inst`): `surface1` with a faint dot
/// grid, a 7% hairline and 12 pt continuous corners. No padding by default:
/// readout rows and dividers run edge to edge.
struct InstrumentPanel<Content: View>: View {
    var padding: CGFloat = 0
    var dots: Bool = true
    @ViewBuilder let content: Content

    init(padding: CGFloat = 0, dots: Bool = true, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.dots = dots
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel(padding: padding, dots: dots)
    }
}

extension View {
    /// Draws this view on an instrument panel (see `InstrumentPanel`).
    func instrumentPanel(padding: CGFloat = 0, dots: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
        return self
            .padding(padding)
            .background {
                ZStack {
                    shape.fill(Theme.surface1)
                    if dots { DotGrid().clipShape(shape) }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Module header

/// A numbered section label: "01  THIS RADIO · 7 ……… Switch" (AB `.sec`
/// with `.no`). The trailing slot takes a small action or hint.
struct ModuleHeader<Trailing: View>: View {
    let number: Int?
    let title: String
    var detail: String? = nil
    let trailing: Trailing

    init(_ number: Int?, _ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.number = number
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let number {
                Text(String(format: "%02d", max(0, number)))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 3)
                    .frame(minHeight: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            }
            (Text(title.uppercased()).foregroundStyle(Theme.textTertiary)
             + Text(detail.map { " · \($0)" } ?? "").foregroundStyle(Theme.textSecondary))
                .font(Theme.Fonts.label)
                .tracking(Theme.labelTracking)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(_ number: Int?, _ title: String, detail: String? = nil) {
        self.init(number, title, detail: detail) { EmptyView() }
    }
}

extension ModuleHeader where Trailing == ModuleAction {
    /// With a small trailing action ("Switch", "What's this?").
    init(_ number: Int?, _ title: String, detail: String? = nil,
         action: String, symbol: String? = nil, perform: @escaping () -> Void) {
        self.init(number, title, detail: detail) { ModuleAction(title: action, symbol: symbol, perform: perform) }
    }
}

/// The grey trailing link on a `ModuleHeader`.
struct ModuleAction: View {
    let title: String
    var symbol: String? = nil
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(title)
            }
            .font(Theme.Fonts.footnote)
            .foregroundStyle(Theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Network tag

/// Which network something travels on: a coloured mono pill ("MESHCORE"),
/// optionally followed by "via Wildcat Bag". `.header` is the bigger form
/// that heads a group of chats (LED + bold name + via).
struct NetworkTag: View {
    enum Style { case tag, header }

    let network: MeshNetwork
    var via: String? = nil
    var style: Style = .tag
    /// Draws the header LED grey (the radio is not connected).
    var connected: Bool = true

    init(_ network: MeshNetwork, via: String? = nil, style: Style = .tag, connected: Bool = true) {
        self.network = network
        self.via = via
        self.style = style
        self.connected = connected
    }

    var body: some View {
        HStack(spacing: style == .header ? 8 : 6) {
            switch style {
            case .tag:
                Text(network.name.uppercased())
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(network.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                        .strokeBorder(network.stroke, lineWidth: 1))
                    .fixedSize()
            case .header:
                StatusLED(color: network.color, on: connected, size: 8)
                Text(network.name.uppercased())
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(connected ? network.color : Theme.textTertiary)
                    .fixedSize()
            }
            if let via {
                Text("via \(via)")
                    .font(style == .header ? .subheadline : Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(network.name)\(via.map { " via \($0)" } ?? "")")
    }
}

// MARK: - Meta line

/// The plain-English line under a message or row ("5 hops · strong
/// signal"), with an optional small meter in front and an optional raw mono
/// line under it ("SNR 12.2 · −97 dBm · path 7a›c4").
struct MetaLine: View {
    let text: String
    var raw: String? = nil
    /// 0...1 for a 5-segment meter in front of the text.
    var signal: Double? = nil
    var tint: Color = Theme.textPrimary
    var alignment: HorizontalAlignment = .leading

    init(_ text: String, raw: String? = nil, signal: Double? = nil, tint: Color = Theme.textPrimary,
         alignment: HorizontalAlignment = .leading) {
        self.text = text
        self.raw = raw
        self.signal = signal
        self.tint = tint
        self.alignment = alignment
    }

    init(_ text: String, raw: String? = nil, signal: Double? = nil, network: MeshNetwork,
         alignment: HorizontalAlignment = .leading) {
        self.init(text, raw: raw, signal: signal, tint: network.color, alignment: alignment)
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 6) {
                if let signal { SegmentMeter(value: signal, tint: tint, size: .small) }
                Text(text)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            if let raw {
                Text(raw)
                    .font(Theme.Fonts.raw)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Panels") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            ModuleHeader(1, "This radio", action: "Switch", symbol: "antenna.radiowaves.left.and.right") {}
            InstrumentPanel(padding: 14) {
                Text("All good. Hearing 7 nodes.").foregroundStyle(Theme.textSecondary)
            }
            ModuleHeader(3, "Heard nearby", detail: "7")
            NetworkTag(.meshcore, via: "Wildcat Bag")
            NetworkTag(.meshtastic, via: "GO", style: .header)
            MetaLine("5 hops · strong signal", raw: "SNR 12.2 · −97 dBm · path 7a›c4›19", signal: 1, network: .meshcore)
        }
        .padding()
    }
    .screen()
}
