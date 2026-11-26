import SwiftUI

/// Your collection: territory, coverage, Nodedex, achievements. Opened from Play and the ≡ menu
/// (it was a tab until 2.0, when Reticulum took the fifth place in the tab bar).
struct ExploreView: View {
    @Environment(ExploreModel.self) private var explore
    @Environment(DenStore.self) private var den

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let toast = explore.toast {
                    ToastBanner(text: toast, kind: .success)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(4))
                            withAnimation { explore.toast = nil }
                        }
                }
                ModuleHeader(1, "Your collection")
                statsPanel
                ModuleHeader(2, "Your ground")
                    .padding(.top, 8)
                links
                ModuleHeader(3, "Today")
                    .padding(.top, 8)
                DailyFoxCard()
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: explore.toast)
        }
        .screen()
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { GuideButton(chapter: "explore") } }
        .onAppear { explore.begin(asking: false); explore.checkAchievements() }
        .task { if den.nodes.isEmpty { await den.refresh() } }
        .onDisappear { explore.end() }
    }

    private var statsPanel: some View {
        let s = explore.stats
        return InstrumentPanel {
            ReadoutRow {
                ReadoutCell("Tiles", value: "\(s.tiles)", sub: "walked")
                CellDivider()
                ReadoutCell("Nodedex", value: "\(s.dex)", sub: "nodes")
                CellDivider()
                ReadoutCell("Foxes", value: "\(s.foxes)", sub: "found")
                CellDivider()
                ReadoutCell("Streak", value: "\(s.streak)", sub: s.streak == 1 ? "day" : "days")
            }
        }
    }

    private var links: some View {
        FieldGroup {
            NavRow { TerritoryView() } label: {
                FieldRow(symbol: "hexagon", title: "Territory", subtitle: "Your walked tiles and the Den's frontier",
                         detail: "\(explore.territory.explored)")
            }
            FieldDivider()
            NavRow { CoverageView() } label: {
                FieldRow(symbol: "figure.walk", title: "Coverage walk / drive", subtitle: "Log where your mesh reaches")
            }
            FieldDivider()
            NavRow { NodedexView() } label: {
                FieldRow(symbol: "square.stack.3d.up", title: "Nodedex", subtitle: "Every node heard directly",
                         detail: "\(explore.dex.entries.count)")
            }
            FieldDivider()
            NavRow { AchievementsView() } label: {
                FieldRow(symbol: "rosette", title: "Achievements", subtitle: "Firsts and milestones",
                         detail: "\(explore.unlocked.count)/\(Achievement.all.count)")
            }
        }
    }
}

// MARK: - Daily Fox card

struct DailyFoxCard: View {
    @Environment(ExploreModel.self) private var explore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "pawprint", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Fox").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                    Text(explore.today).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if let run = explore.todayRun, run.found != nil {
                    statusTag("Found", on: true)
                } else if let run = explore.todayRun, !run.isOver {
                    statusTag("Live", on: true)
                }
            }
            if let run = explore.todayRun {
                if run.found != nil {
                    Text("Found \(run.foxName)")
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.textPrimary)
                    MetaLine("Come back tomorrow for a new fox.",
                             raw: "\(run.score) points · \(Geo.format(run.walked)) walked · \(run.pings) pings · \(run.hints) hints")
                } else if run.gaveUp {
                    Text("It was \(run.foxName)").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    MetaLine("A new fox appears tomorrow.")
                } else {
                    MetaLine("Hunt in progress: \(run.foxName)", raw: "\(Geo.format(run.walked)) walked · \(run.pings) pings")
                    NavigationLink { DailyFoxView() } label: {
                        Label("Back to the hunt", systemImage: "scope")
                    }
                    .buttonStyle(.fieldPrimary)
                }
            } else if explore.here == nil, explore.access != .allowed {
                Text("A real node near you is today's fox. It's picked from where you are.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                LocationNotice(access: explore.access) { explore.askLocation() }
            } else if let blocker = explore.foxBlocker {
                Text(blocker).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                rangePicker
            } else {
                Text("A real node near you is today's fox. Find it by its signal alone. Its location stays hidden until you're within 100 m.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                rangePicker
                HStack(spacing: 10) {
                    NavigationLink {
                        DailyFoxView()
                    } label: {
                        Label("Start the hunt", systemImage: "scope")
                    }
                    .buttonStyle(.fieldPrimary)
                    .simultaneousGesture(TapGesture().onEnded { explore.startDailyFox() })
                    Button("Other fox") { explore.differentFox() }
                        .buttonStyle(.field(.secondary, .large))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .panel()
    }

    private func statusTag(_ text: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            StatusLED(color: Theme.ok, on: on, size: 6)
            Tag(text, color: Theme.ok)
        }
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardLabel("Search within")
            FieldSegmented(options: [(2000.0, "2 km"), (5000.0, "5 km"), (10_000.0, "10 km"), (25_000.0, "25 km")],
                           selection: Bindable(explore).maxDistance)
        }
    }
}

/// The Geo Gifts row on Play.
struct GiftsCard: View {
    @Environment(GiftStore.self) private var gifts

    var body: some View {
        GameRow(symbol: "gift", title: "Geo Gifts",
                text: gifts.locked.isEmpty ? "Leave a message that only opens at a place."
                    : "\(gifts.locked.count) locked gift\(gifts.locked.count == 1 ? "" : "s") waiting for you",
                detail: gifts.locked.isEmpty ? nil : "\(gifts.locked.count) locked")
    }
}
