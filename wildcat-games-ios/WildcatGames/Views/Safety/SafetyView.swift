import SwiftUI
import WildcatRadioCore

/// Blocked people, the word filter and how to report: moderation that lives on this phone.
struct SafetyView: View {
    @Environment(Safety.self) private var safety
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var safety = safety
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                SectionLabel("Word filter")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $safety.filterWords) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide strong language").font(Theme.Fonts.heading).foregroundStyle(Theme.ink)
                            Text("Slurs and strong swearing in messages you receive show as •••• until you tap. Notifications never show them.")
                                .font(Theme.Fonts.footnote).foregroundStyle(Theme.mute)
                        }
                    }
                }
                .panel()

                let blocked = safety.blocked
                SectionLabel("Blocked", detail: blocked.isEmpty ? nil : "\(blocked.count)")
                if blocked.isEmpty {
                    EmptyState(symbol: "hand.raised", title: "Nobody blocked",
                               text: "Long-press a message to block or report its sender. You can also block from People or a node's page.")
                        .panel(.inset)
                } else {
                    FieldGroup {
                        ForEach(Array(blocked.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { FieldDivider(inset: 58) }
                            HStack(spacing: 12) {
                                IconTile(symbol: "hand.raised", size: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(s.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                        Tag(s.network == .meshtastic ? "MT" : s.network == .meshcore ? "MC" : "RNS",
                                            color: s.network == .meshtastic ? Theme.meshtastic : s.network == .meshcore ? Theme.meshcore : RNodeStyle.color)
                                    }
                                    Text(detail(s)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button("Unblock") { safety.unblock(s) }
                                    .buttonStyle(.field(.secondary, .small))
                            }
                            .padding(.horizontal, Theme.Space.rowH)
                            .padding(.vertical, Theme.Space.rowV)
                        }
                    }
                    Text("Blocked people's messages are hidden, send no notifications and never cross the bridge. Blocking a Meshtastic node also makes your connected node ignore it.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.mute)
                }

                SectionLabel("Report")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Long-press a message and choose Report… to email it to the Wildcat team. Messages travel radio to radio with no server, so reports go by email from your phone.")
                        .font(Theme.Fonts.callout).foregroundStyle(Theme.inkSoft)
                    Button {
                        if let url = URL(string: "mailto:\(Support.email)?subject=\(Report.encode(Report.subject))") { openURL(url) }
                    } label: {
                        Label(Support.email, systemImage: "envelope").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.field(.secondary, .regular))
                }
                .panel()
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("Safety")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ s: BlockedSender) -> String {
        switch s.network {
        case .meshtastic: return "Meshtastic · " + (s.key.isEmpty ? "blocked by name" : s.key)
        case .meshcore: return "MeshCore · " + (s.key.isEmpty ? "blocked by name" : String(s.key.prefix(8)))
        case .reticulum: return "Reticulum · " + Reticulum.shortAddress(s.key)
        }
    }
}
