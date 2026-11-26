import SwiftUI
import WidgetKit

@main
struct WildcatWidgetBundle: WidgetBundle {
    var body: some Widget { WildcatMeshWidget() }
}

struct WildcatEntry: TimelineEntry {
    let date: Date
    let snapshot: WildcatSnapshot?
}

struct WildcatProvider: TimelineProvider {
    func placeholder(in context: Context) -> WildcatEntry { WildcatEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (WildcatEntry) -> Void) {
        completion(WildcatEntry(date: Date(), snapshot: context.isPreview ? .placeholder : WildcatSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WildcatEntry>) -> Void) {
        // The app reloads the timeline when things change; this is just a fallback refresh.
        let entry = WildcatEntry(date: Date(), snapshot: WildcatSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct WildcatMeshWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WildcatSnapshot.widgetKind, provider: WildcatProvider()) { entry in
            WildcatWidgetView(entry: entry)
                .containerBackground(for: .widget) { W.bg }
                .widgetURL(URL(string: "wildcat://open"))
        }
        .configurationDisplayName("Wildcat Mesh")
        .description("Your Meshtastic and MeshCore nodes, the bridge, and the latest messages.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// The app's AB tokens, for the widget (it can't see the app's Theme): neutral
/// darks, amber only for Meshtastic, blue only for MeshCore, green OK.
enum W {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.043)            // #09090b
    static let panel = Color(red: 0.067, green: 0.067, blue: 0.078)         // #111114
    static let line = Color.white.opacity(0.07)
    static let line2 = Color.white.opacity(0.12)
    static let meshtastic = Color(red: 1.0, green: 0.690, blue: 0.0)        // #ffb000
    static let meshcore = Color(red: 0.227, green: 0.627, blue: 1.0)        // #3aa0ff
    static let ok = Color(red: 0.243, green: 0.812, blue: 0.557)            // #3ecf8e
    static let t1 = Color(red: 0.929, green: 0.929, blue: 0.941)            // #ededf0
    static let t2 = Color(red: 0.631, green: 0.631, blue: 0.667)            // #a1a1aa
    static let t3 = Color(red: 0.420, green: 0.420, blue: 0.459)            // #6b6b75
    static let t4 = Color(red: 0.275, green: 0.275, blue: 0.306)            // #46464e
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .monospaced) }

    static func color(_ network: String) -> Color { network == "MC" ? meshcore : meshtastic }
}

struct WildcatWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WildcatEntry

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .systemSmall: small(s)
            case .systemMedium: medium(s)
            default: large(s)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                label("Wildcat Mesh")
                Text("Open Wildcat and connect a node.").font(.system(size: 13)).foregroundStyle(W.t1)
                Spacer(minLength: 0)
                HStack(spacing: 10) { led(false, W.meshtastic); led(false, W.meshcore) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Sizes

    /// Both radios as LED lines, and the unread count.
    private func small(_ s: WildcatSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(s)
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 7) {
                radioLine(s.meshtastic, network: "MT")
                radioLine(s.meshcore, network: "MC")
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(s.unreadMeshtastic + s.unreadMeshCore)")
                    .font(.system(size: 26, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(W.t1)
                Text("unread").font(W.mono(10)).foregroundStyle(W.t3)
                Spacer(minLength: 0)
                bridgeLED(s)
            }
        }
    }

    /// Radios with readouts on the left, the latest message on the right.
    private func medium(_ s: WildcatSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                header(s)
                radioBlock(s.meshtastic, network: "MT")
                radioBlock(s.meshcore, network: "MC")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(W.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    label("Latest")
                    Spacer(minLength: 0)
                    unread(s)
                }
                if s.recent.isEmpty {
                    Text("No messages yet.").font(.system(size: 12)).foregroundStyle(W.t3)
                }
                ForEach(s.recent.prefix(2)) { message($0, lines: 2) }
                Spacer(minLength: 0)
                bridge(s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Two readout cards, the bridge, and four latest lines.
    private func large(_ s: WildcatSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { header(s); Spacer(); unread(s) }
            HStack(spacing: 0) {
                radioCard(s.meshtastic, network: "MT")
                Rectangle().fill(W.line).frame(width: 1)
                radioCard(s.meshcore, network: "MC")
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(W.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(W.line, lineWidth: 1))
            bridge(s)
            label("Latest")
            if s.recent.isEmpty {
                Text("No messages yet.").font(.system(size: 12)).foregroundStyle(W.t3)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(s.recent.prefix(4).enumerated()), id: \.element.id) { i, l in
                    if i > 0 { Rectangle().fill(W.line).frame(height: 1) }
                    message(l, lines: 1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Pieces

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(W.mono(9, .medium)).tracking(0.8).foregroundStyle(W.t3).lineLimit(1)
    }

    private func header(_ s: WildcatSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            label("Wildcat Mesh")
            Text(s.updated, style: .relative).font(W.mono(9)).foregroundStyle(W.t4).lineLimit(1)
        }
    }

    private func led(_ on: Bool, _ tint: Color) -> some View {
        Circle()
            .fill(on ? tint : W.t4)
            .frame(width: 6, height: 6)
            .background(Circle().fill(tint.opacity(on ? 0.18 : 0)).padding(-3))
    }

    private func name(_ network: String) -> String { network == "MC" ? "MeshCore" : "Meshtastic" }

    /// "● STAY · 5" (small).
    private func radioLine(_ n: WildcatSnapshot.Node?, network: String) -> some View {
        HStack(spacing: 7) {
            led(n?.connected == true, W.color(network))
            Text(n?.name ?? name(network))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(n == nil ? W.t3 : W.t1)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(n.map { "\($0.heard)" } ?? "off").font(W.mono(10)).foregroundStyle(W.t3)
        }
    }

    /// LED, name, and a raw line (medium).
    private func radioBlock(_ n: WildcatSnapshot.Node?, network: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                led(n?.connected == true, W.color(network))
                Text(n?.name ?? name(network))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(n == nil ? W.t3 : W.t1)
                    .lineLimit(1)
            }
            Text(n.map { [ "\($0.heard) heard", $0.batteryVolts.map { String(format: "%.2f V", $0) } ].compactMap { $0 }.joined(separator: " · ") }
                    ?? "\(name(network).uppercased()) · off")
                .font(W.mono(9.5))
                .foregroundStyle(W.t3)
                .lineLimit(1)
                .padding(.leading, 12)
        }
    }

    /// Network tag, name, and readouts (large).
    private func radioCard(_ n: WildcatSnapshot.Node?, network: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                led(n?.connected == true, W.color(network))
                tag(network)
            }
            Text(n?.name ?? "Not connected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(n == nil ? W.t3 : W.t1)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                readout("Heard", n.map { "\($0.heard)" } ?? "—", unit: nil)
                readout("Batt", n?.batteryVolts.map { String(format: "%.2f", $0) } ?? "—", unit: n?.batteryVolts == nil ? nil : "V")
            }
            if let h = n?.lastHeard {
                Text(h, style: .relative).font(W.mono(9)).foregroundStyle(W.t3).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func readout(_ label: String, _ value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(W.mono(8, .medium)).tracking(0.6).foregroundStyle(W.t3)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 20, weight: .light)).monospacedDigit().foregroundStyle(W.t1)
                if let unit { Text(unit).font(W.mono(9)).foregroundStyle(W.t3) }
            }
        }
    }

    /// "MESHTASTIC" / "MESHCORE" outlined in the network colour.
    private func tag(_ network: String, short: Bool = false) -> some View {
        Text(short ? network : name(network).uppercased())
            .font(W.mono(8.5, .medium))
            .tracking(0.5)
            .foregroundStyle(W.color(network))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.color(network).opacity(0.3), lineWidth: 1))
            .fixedSize()
    }

    private func bridgeLED(_ s: WildcatSnapshot) -> some View {
        HStack(spacing: 4) {
            led(s.bridgeOn, W.ok)
            Text("⇄").font(W.mono(10)).foregroundStyle(s.bridgeOn ? W.t2 : W.t4)
        }
    }

    private func bridge(_ s: WildcatSnapshot) -> some View {
        HStack(spacing: 6) {
            led(s.bridgeOn, W.ok)
            Text(s.bridgeOn ? "BRIDGE ON" : "BRIDGE OFF").font(W.mono(9, .medium)).tracking(0.5)
                .foregroundStyle(s.bridgeOn ? W.t2 : W.t3)
            if s.bridgeOn {
                Text(["\(s.bridged) crossed", s.bridgeChannels].compactMap { $0 }.joined(separator: " · "))
                    .font(W.mono(9)).foregroundStyle(W.t3).lineLimit(1)
            }
        }
    }

    private func unread(_ s: WildcatSnapshot) -> some View {
        let n = s.unreadMeshtastic + s.unreadMeshCore
        return HStack(spacing: 4) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10))
            Text("\(n)").font(W.mono(12, .semibold))
        }
        .foregroundStyle(n > 0 ? W.t1 : W.t3)
    }

    private func message(_ l: WildcatSnapshot.Line, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                tag(l.network, short: true)
                Text(l.from).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(W.t1).lineLimit(1)
                Spacer(minLength: 0)
                Text(l.at, style: .time).font(W.mono(9)).foregroundStyle(W.t3)
            }
            Text(l.text).font(.system(size: 12)).foregroundStyle(W.t2).lineLimit(lines)
        }
    }
}
