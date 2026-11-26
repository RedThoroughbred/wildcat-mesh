import SwiftUI

/// The guide's contents.
struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RemiMark(size: 40)
                    Text("Everything about Wildcat, offline. Tap a chapter.")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 6)
                ModuleHeader(nil, "Chapters", detail: "\(Guide.chapters.count)")
                FieldGroup {
                    ForEach(Array(Guide.chapters.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { FieldDivider() }
                        NavRow { GuideChapterView(chapter: c) } label: {
                            FieldRow(symbol: c.symbol, title: c.title, subtitle: c.summary)
                        }
                    }
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("Guide")
    }
}

struct GuideChapterView: View {
    let chapter: GuideChapter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    IconTile(symbol: chapter.symbol, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        if let i = Guide.chapters.firstIndex(of: chapter) {
                            CardLabel("Chapter \(String(format: "%02d", i + 1)) of \(Guide.chapters.count)")
                        }
                        Text(chapter.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                        Text(chapter.summary).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.bottom, 4)
                ForEach(Array(chapter.blocks.enumerated()), id: \.offset) { _, b in block(b) }
                if let i = Guide.chapters.firstIndex(of: chapter), i + 1 < Guide.chapters.count {
                    let next = Guide.chapters[i + 1]
                    NavigationLink { GuideChapterView(chapter: next) } label: {
                        Label("Next: \(next.title)", systemImage: "arrow.right")
                    }
                    .buttonStyle(.fieldSecondary)
                    .padding(.top, 8)
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func block(_ b: GuideChapter.Block) -> some View {
        switch b {
        case .text(let s):
            Text(.init(s))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .steps(let steps):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    if i > 0 { PanelDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        // A neutral number box, like a module number (AB `.no`).
                        Text(String(format: "%02d", i + 1))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                        Text(.init(s)).font(Theme.Fonts.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Theme.Space.rowH)
                    .padding(.vertical, Theme.Space.rowV)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .panel(.inset)
        case .tip(let s):
            Callout(symbol: "lightbulb", text: s)
        case .warning(let s):
            Callout(symbol: "exclamationmark.triangle", text: s, color: Theme.alert)
        case .terms(let terms):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(terms.enumerated()), id: \.offset) { _, t in
                    VStack(alignment: .leading, spacing: 3) {
                        CardLabel(t.0)
                        Text(.init(t.1)).font(Theme.Fonts.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}

/// A tip (neutral, dashed like the AB hint box) or a warning (red) in the guide.
private struct Callout: View {
    let symbol: String
    let text: String
    var color: Color? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color ?? Theme.textSecondary)
            Text(.init(text)).font(Theme.Fonts.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((color ?? .white).opacity(color == nil ? 0.03 : 0.08), in: shape)
        .overlay(shape.strokeBorder(color.map { $0.opacity(0.3) } ?? Theme.hairlineStrong,
                                    style: StrokeStyle(lineWidth: 1, dash: color == nil ? [3, 3] : [])))
    }
}

/// A "?" toolbar button that opens the guide (optionally at one chapter).
struct GuideButton: View {
    var chapter: String? = nil
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Image(systemName: "questionmark.circle") }
            .accessibilityLabel("Guide")
            .sheet(isPresented: $open) {
                NavigationStack {
                    Group {
                        if let id = chapter, let c = Guide.chapter(id) { GuideChapterView(chapter: c) } else { GuideView() }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { open = false } }
                        if chapter != nil {
                            ToolbarItem(placement: .topBarLeading) {
                                NavigationLink("All chapters") { GuideView() }
                            }
                        }
                    }
                }
                .presentationBackground(Theme.bg)
            }
    }
}

/// An inline "How it works" link to a chapter.
struct GuideLink: View {
    let chapter: String
    var title = "How it works"

    var body: some View {
        if let c = Guide.chapter(chapter) {
            NavigationLink { GuideChapterView(chapter: c) } label: {
                Label(title, systemImage: "book").font(Theme.Fonts.dataSmall)
            }
        }
    }
}
