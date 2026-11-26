import SwiftUI

/// One entry on the `PacketTicker`.
struct TickerEvent: Identifiable, Equatable {
    enum Direction: String { case rx = "RX", tx = "TX" }

    let id: UUID
    let network: MeshNetwork
    var direction: Direction = .rx
    /// The packet kind in caps ("ADVERT", "GRP_TXT"), optional.
    var kind: String? = nil
    /// The rest of the line ("OAK.RPT.02 −3.2dB").
    let text: String
    let time: Date

    init(id: UUID = UUID(), network: MeshNetwork, direction: Direction = .rx, kind: String? = nil,
         text: String, time: Date = Date()) {
        self.id = id
        self.network = network
        self.direction = direction
        self.kind = kind
        self.text = text
        self.time = time
    }
}

/// The live strip under the nav bar (AB `.ticker`): a LIVE lamp, then the
/// newest packets left to right, each with its network dot, RX/TX, kind,
/// text and age. New entries slide in from the left. No data wiring: pass
/// the recent events (newest first or last; they are sorted).
struct PacketTicker: View {
    let events: [TickerEvent]
    var live: Bool = true
    /// How many entries to keep on the strip.
    var limit: Int = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [TickerEvent] {
        Array(events.sorted { $0.time > $1.time }.prefix(max(1, limit)))
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                StatusLED(color: Theme.ok, on: live, size: 6)
                Text("LIVE")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(live ? Theme.textSecondary : Theme.textTertiary)
            }
            .padding(.leading, Theme.Space.edge)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            // A non-scrolling scroll view: takes the width it is given and
            // clips the strip, however long the entries are.
            ScrollView(.horizontal, showsIndicators: false) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 0) {
                        ForEach(shown) { event in
                            entry(event, now: context.date)
                                .transition(reduceMotion ? .opacity
                                            : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .scrollDisabled(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                LinearGradient(colors: [Theme.surface1.opacity(0), Theme.surface1], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 48)
                    .allowsHitTesting(false)
            }
            .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.settle), value: shown.map(\.id))
        }
        .frame(height: 28)
        .background(Theme.surface1)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .font(.system(size: 10.5, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func entry(_ e: TickerEvent, now: Date) -> some View {
        HStack(spacing: 6) {
            Circle().fill(e.network.color).frame(width: 4, height: 4)
            Text(e.direction.rawValue).foregroundStyle(e.direction == .rx ? Theme.ok : Theme.textPrimary)
            if let kind = e.kind { Text(kind).foregroundStyle(Theme.textSecondary) }
            Text(e.text).foregroundStyle(Theme.textTertiary)
            Text(Self.age(e.time, now: now)).foregroundStyle(Theme.textTertiary)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
    }

    /// "4s", "3m", "2h".
    static func age(_ time: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(time)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    private var accessibilityText: String {
        guard let first = shown.first else { return "Live packets: none yet" }
        return "Latest packet: \(first.direction.rawValue) \(first.kind ?? "") \(first.text) on \(first.network.name)"
    }
}

#Preview("Ticker") {
    struct Demo: View {
        @State private var events: [TickerEvent] = [
            TickerEvent(network: .meshcore, kind: "ADVERT", text: "OAK.RPT.02 −3.2dB", time: .now.addingTimeInterval(-4)),
            TickerEvent(network: .meshcore, kind: "GRP_TXT", text: "#public 5h", time: .now.addingTimeInterval(-12)),
        ]
        var body: some View {
            VStack {
                PacketTicker(events: events)
                Button("Add") {
                    events.append(TickerEvent(network: Bool.random() ? .meshcore : .meshtastic, kind: "TEXT", text: "MAYA hi"))
                }
            }
            .screen()
        }
    }
    return Demo()
}
