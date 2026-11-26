import SwiftUI

/// The app-wide radio log, newest first, as a terminal transcript: both radios' connection
/// steps, WG lines (hunt moves, Den commands) sent and received, and the bridge's decisions.
/// It lives in the app menu, not in one network's tab.
struct LogView: View {
    @Environment(HuntModel.self) private var hunt

    var body: some View {
        ScrollView {
            if hunt.log.isEmpty {
                EmptyState(symbol: "text.alignleft", title: "Nothing logged yet",
                           text: "Lines from both radios appear here: Meshtastic and MeshCore connection steps, hunt moves and Den commands, and what the bridge relays or skips.")
                    .panel()
                    .padding(Theme.Space.edge)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ModuleHeader(1, "Both radios", detail: "\(hunt.log.count)", action: "Copy all", symbol: "doc.on.doc") {
                        UIPasteboard.general.string = hunt.log.map { "\($0.time.formatted(date: .omitted, time: .standard)) \($0.text)" }
                            .joined(separator: "\n")
                        Haptics.success()
                    }
                    HStack(spacing: 14) {
                        legend(">", "sent", Theme.textPrimary)
                        legend("<", "received", Theme.ok)
                        legend("#", "note", Theme.textTertiary)
                    }
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(hunt.log.reversed()) { line in
                            LogLineView(line: line)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(.well)
                }
                .padding(Theme.Space.edge)
            }
        }
        .screen()
        .navigationTitle("Radio log")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func legend(_ mark: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(mark).font(Theme.Fonts.raw.weight(.semibold)).foregroundStyle(color)
            Text(text).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct LogLineView: View {
    let line: HuntModel.LogLine

    private var mark: (String, Color) {
        switch line.direction {
        case .sent: return (">", Theme.textPrimary)
        case .received: return ("<", Theme.ok)
        case .note: return ("#", Theme.textTertiary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time, format: .dateTime.hour().minute().second())
                .foregroundStyle(Theme.textQuaternary)
                .monospacedDigit()
            Text(mark.0)
                .fontWeight(.semibold)
                .foregroundStyle(mark.1)
            Text(line.text)
                .foregroundStyle(line.direction == .note ? Theme.textTertiary : Theme.textPrimary)
                .textSelection(.enabled)
        }
        .font(Theme.Fonts.raw)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.direction == .sent ? "Sent" : line.direction == .received ? "Received" : "Note"): \(line.text)")
    }
}
