import SwiftUI

/// About → Open source licences: what ships inside the app, under which licence, with the full text.
struct LicensesView: View {
    private let components = OpenSourceComponent.all()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                Text("Reticulum in Wildcat Mesh is the official Reticulum Network Stack and LXMF by Mark Qvist, included unchanged, running in a Python runtime inside the app. Wildcat Mesh is not affiliated with or endorsed by the Reticulum project.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ModuleHeader(1, "Included software", detail: "\(components.count)")
                FieldGroup {
                    ForEach(Array(components.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { FieldDivider() }
                        NavRow { LicenseTextView(component: c) } label: {
                            FieldRow(symbol: "doc.text", title: c.name, subtitle: c.line)
                        }
                    }
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("Open source licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseTextView: View {
    let component: OpenSourceComponent
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(component.name).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    Text("\(component.line) · \(component.by)").font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textTertiary)
                }
                if !component.note.isEmpty {
                    Text(component.note).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: component.source) {
                    Button { openURL(url) } label: {
                        Label("Source code", systemImage: "arrow.up.right.square").font(Theme.Fonts.footnote)
                    }
                }
                Text(component.text() ?? "The licence text is missing from this build.")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
