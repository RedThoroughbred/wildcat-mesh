import SwiftUI

/// Every node your own radio has heard directly, rarest first.
struct NodedexView: View {
    @Environment(ExploreModel.self) private var explore

    var body: some View {
        let entries = explore.dex.sorted
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ModuleHeader(1, "Rarity")
                InstrumentPanel {
                    ReadoutRow {
                        ForEach(Array(DexEntry.Rarity.allCases.reversed().enumerated()), id: \.element) { i, r in
                            if i > 0 { CellDivider() }
                            ReadoutCell(r.rawValue, value: "\(entries.filter { $0.rarity == r }.count)") {
                                SegmentMeter(lit: RarityStyle.level(r), of: 4, size: .xs)
                            }
                        }
                    }
                }
                Text("Rarity is the longest distance you heard it from directly: 1 km uncommon, 5 km rare, 15 km legendary. Distance needs the node's position from the Den.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                if entries.isEmpty {
                    EmptyState(symbol: "square.stack.3d.up", title: "Nothing caught yet",
                               text: "Connect your node. Every node it hears directly is added here.")
                        .panel()
                } else {
                    ModuleHeader(2, "Caught", detail: "\(entries.count)")
                    FieldGroup {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { FieldDivider() }
                            DexRow(entry: e)
                        }
                    }
                }
            }
            .padding(Theme.Space.edge)
        }
        .screen()
        .navigationTitle("Nodedex (\(entries.count))")
    }
}

private struct DexRow: View {
    let entry: DexEntry

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "antenna.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.longName ?? entry.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Tag(entry.rarity.rawValue)
                }
                Text("\(entry.name) · heard \(entry.count)× · first \(entry.firstSeen.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(2)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                if let d = entry.longest {
                    Text(Geo.format(d)).font(Theme.Fonts.data).foregroundStyle(Theme.textPrimary)
                }
                SegmentMeter(lit: RarityStyle.level(entry.rarity), of: 4, size: .xs)
                if let s = entry.bestSNR {
                    Text("best \(FoxReadout.format(s, unit: .snr)) dB").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .accessibilityElement(children: .combine)
    }
}

enum RarityStyle {
    /// 1 (common) to 4 (legendary), for a four-segment meter. Rarity has no
    /// colour: colour means a network or a status.
    static func level(_ r: DexEntry.Rarity) -> Int {
        switch r {
        case .common: return 1
        case .uncommon: return 2
        case .rare: return 3
        case .legendary: return 4
        }
    }
}

struct AchievementsView: View {
    @Environment(ExploreModel.self) private var explore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                InstrumentPanel {
                    ReadoutRow {
                        ReadoutCell("Unlocked", value: "\(explore.unlocked.count)", unit: "of \(Achievement.all.count)") {
                            SegmentMeter(lit: explore.unlocked.count, of: Achievement.all.count, tint: Theme.ok, size: .xs)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Achievement.all) { a in
                        AchievementTile(achievement: a, unlocked: explore.unlocked[a.id])
                    }
                }
            }
            .padding(Theme.Space.edge)
        }
        .screen()
        .navigationTitle("Achievements \(explore.unlocked.count)/\(Achievement.all.count)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AchievementTile: View {
    let achievement: Achievement
    let unlocked: Date?

    var body: some View {
        let got = unlocked != nil
        VStack(alignment: .leading, spacing: 8) {
            IconTile(symbol: achievement.symbol, tint: got ? Theme.ok : nil, size: 36)
            Text(achievement.title)
                .font(Theme.Fonts.heading)
                .foregroundStyle(got ? Theme.textPrimary : Theme.textSecondary)
            Text(achievement.detail)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                StatusLED(color: Theme.ok, on: got, size: 6)
                Text(unlocked.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "LOCKED")
                    .font(Theme.Fonts.raw)
                    .tracking(unlocked == nil ? 1 : 0)
                    .foregroundStyle(got ? Theme.textSecondary : Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .panel(got ? .hero : .standard)
        .opacity(got ? 1 : 0.7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(achievement.title), \(got ? "unlocked" : "locked"). \(achievement.detail)")
    }
}
