import SwiftUI

/// Version, the privacy policy and support links, and the trademark notice.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                HStack(spacing: 14) {
                    RemiMark(size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wildcat Mesh").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                        Text("Version \(version)").font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.vertical, 8)

                ModuleHeader(1, "Links")
                FieldGroup {
                    Button { openURL(Support.privacy) } label: {
                        FieldRow(symbol: "hand.raised", title: "Privacy policy", subtitle: "No data collected. Everything stays on your iPhone.")
                    }
                    .buttonStyle(.rowPress)
                    FieldDivider()
                    Button { openURL(Support.site) } label: {
                        FieldRow(symbol: "questionmark.circle", title: "Support", subtitle: "Help, requirements and common questions")
                    }
                    .buttonStyle(.rowPress)
                    FieldDivider()
                    Button {
                        if let url = URL(string: "mailto:\(Support.email)?subject=Wildcat%20Mesh") { openURL(url) }
                    } label: {
                        FieldRow(symbol: "envelope", title: "Contact", subtitle: Support.email)
                    }
                    .buttonStyle(.rowPress)
                    FieldDivider()
                    NavRow { LicensesView() } label: {
                        FieldRow(symbol: "doc.text", title: "Open source licences", subtitle: "Reticulum, LXMF, Python and what they use")
                    }
                    FieldDivider()
                    Button { openURL(Support.source) } label: {
                        FieldRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Source code",
                                 subtitle: "Wildcat Mesh is free software under the GNU GPL v3")
                    }
                    .buttonStyle(.rowPress)
                }

                ModuleHeader(2, "Notices")
                // Meshtastic's attribution statement, word for word (their trademark guidelines).
                Text("Meshtastic® is a registered trademark of Meshtastic LLC. Meshtastic software components are released under various licenses, see GitHub for details. No warranty is provided - use at your own risk.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                Text("Wildcat Mesh is an independent app and is not affiliated with or endorsed by Meshtastic LLC, the Meshtastic project or the MeshCore project.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                Text("Includes the Reticulum Network Stack and LXMF by Mark Qvist (Reticulum License). Wildcat Mesh is not affiliated with or endorsed by the Reticulum project.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                Text("© 2026 Seth Egger")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
