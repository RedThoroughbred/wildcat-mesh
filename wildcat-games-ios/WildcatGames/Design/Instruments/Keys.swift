import SwiftUI

// MARK: - Status key

/// A physical-looking key with an LED in the corner (AB `.key`): a mono
/// label, a small sub-label ("LINK / BLE", "GPS / OFF"), and optionally an
/// SF Symbol. `primary` is the white key for the main action (Ping now).
struct StatusKey: View {
    enum LED: Equatable {
        case none, off, on, warn
        /// Lit in a network colour.
        case network(MeshNetwork)
        case custom(Color)

        var color: Color? {
            switch self {
            case .none: return nil
            case .off: return Theme.textQuaternary
            case .on: return Theme.ok
            case .warn: return Theme.alert
            case .network(let n): return n.color
            case .custom(let c): return c
            }
        }

        var lit: Bool { self != .none && self != .off }
    }

    let label: String
    var sub: String? = nil
    var symbol: String? = nil
    var led: LED = .none
    var primary: Bool = false
    var action: () -> Void = {}

    init(_ label: String, sub: String? = nil, symbol: String? = nil, led: LED = .none,
         primary: Bool = false, action: @escaping () -> Void = {}) {
        self.label = label
        self.sub = sub
        self.symbol = symbol
        self.led = led
        self.primary = primary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 16, weight: .regular))
                        .padding(.bottom, 1)
                }
                Text(label.uppercased())
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let sub {
                    Text(sub.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(primary ? Color(hex: 0x55555c) : Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(primary ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: symbol == nil ? 44 : 52)
            .overlay(alignment: .topLeading) {
                if let color = led.color {
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .shadow(color: led.lit ? color : .clear, radius: 3)
                        .padding(.top, 7)
                        .padding(.leading, 8)
                }
            }
        }
        .buttonStyle(KeyPressStyle(primary: primary))
        .accessibilityLabel([label, sub].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(led.lit ? "on" : led == .off ? "off" : "")
    }
}

/// The key's body: a top-lit gradient, a 12% hairline and a 1 pt shadow
/// under it; it sinks slightly while pressed.
private struct KeyPressStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
        let top = primary ? Color(hex: 0xf2f2f4) : Color(hex: 0x1c1c21)
        let bottom = primary ? Color(hex: 0xdcdce0) : Color(hex: 0x15151a)
        return configuration.label
            .background(shape.fill(LinearGradient(colors: configuration.isPressed ? [bottom, bottom] : [top, bottom],
                                                  startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(primary ? Color(hex: 0xf2f2f4) : Theme.hairlineStrong, lineWidth: 1))
            .overlay(alignment: .top) {
                // Inset highlight along the top edge.
                shape.stroke(Color.white.opacity(configuration.isPressed ? 0 : 0.05), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.1)))
            }
            .shadow(color: .black, radius: 0, y: configuration.isPressed ? 0 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

/// Keys in a row with equal widths and a 6 pt gap. Give a key
/// `.layoutPriority(1)` and a wider frame to make it the big one.
struct StatusKeyRow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Previews

#Preview("Keys") {
    VStack(spacing: 14) {
        StatusKeyRow {
            StatusKey("Link", sub: "BLE", led: .on)
            StatusKey("Bridge", sub: "⇄ MT", led: .on)
            StatusKey("GPS", sub: "Off", led: .off)
            StatusKey("Advert", sub: "Send", led: .off)
        }
        StatusKeyRow {
            StatusKey("Ping now", symbol: "scope", primary: true).frame(maxWidth: .infinity).layoutPriority(1)
            StatusKey("Mark", symbol: "mappin.and.ellipse")
            StatusKey("Sound", symbol: "waveform.path.ecg", led: .on)
            StatusKey("End", symbol: "xmark")
        }
    }
    .padding()
    .screen()
}
