import SwiftUI
import WildcatRadioCore

/// Every game in one place. Nothing here needs a Den. "Who's playing?" (Small Play 2) picks
/// the games that fit: on your own, two of you, or three or more.
struct PlayView: View {
    @Environment(HuntModel.self) private var hunt
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(RNodeLink.self) private var rnode
    @Environment(ExploreModel.self) private var explore
    @Environment(DenStore.self) private var den
    @Environment(PhoneReferee.self) private var referee
    @Environment(GamePlay.self) private var gamePlay
    @Environment(GiftStore.self) private var gifts
    @Environment(\.tabRouter) private var router
    @AppStorage(PlayView.playersKey) private var players = 2
    @State private var showHunt = false
    @State private var showGame = false

    static let playersKey = "play.players"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    masthead
                    inProgress
                    // No radio on either network yet (and App Review): the pretend fox is the first thing to try.
                    if !radio.isReady && !meshcore.state.isReady {
                        Button {
                            PracticeMode.start(radio, meshcore)
                            showHunt = true   // straight to the pretend fox
                        } label: {
                            GameRow(symbol: "figure.walk.motion", title: "Practice", tag: "No radio needed",
                                    text: "Pretend Meshtastic and MeshCore radios and a fox on this phone. Every game works in practice.")
                                .panel(.inset)
                        }
                        .buttonStyle(.rowPress)
                        .accessibilityHint("Starts pretend radios on both networks and opens Fox Hunt")
                    }
                    if Features.smallPlay {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Who's playing?")
                            FieldSegmented(options: [(1, "Just me"), (2, "2 of us"), (3, "3 or more")], selection: $players)
                        }
                        VStack(spacing: 10) {
                            ForEach(Self.games(for: players), id: \.self) { g in
                                NavigationLink { destination(g) } label: { card(g) }
                                    .buttonStyle(.rowPress)
                            }
                        }
                    }
                    MyMeshCard()
                    SectionLabel(Features.smallPlay ? "More ways to play" : "Games")
                    FieldGroup {
                        NavRow { HuntView() } label: {
                            GameRow(symbol: "scope", title: "Fox Hunt", tag: MeshNetwork.meshtastic.name,
                                    text: "One fox, any number of hunters: join by code or QR, or host one from this phone.")
                        }
                        FieldDivider(inset: 62)
                        NavRow { SoloHuntSetup() } label: {
                            GameRow(symbol: "scope", title: "Solo hunt", tag: MeshNetwork.meshtastic.name,
                                    text: "Hunt any node your Meshtastic radio hears, by its signal. No referee.")
                        }
                        FieldDivider(inset: 62)
                        NavRow { MeshCoreHuntView() } label: {
                            GameRow(symbol: "dot.radiowaves.left.and.right", title: "Repeater hunt", tag: MeshNetwork.meshcore.name,
                                    text: "Find a real MeshCore repeater by its signal alone.")
                        }
                        if !Features.smallPlay || !Self.games(for: players).contains(.gifts) {
                            FieldDivider(inset: 62)
                            NavRow { GiftsView() } label: { GiftsCard() }
                        }
                    }
                    DailyFoxCard()
                    FieldGroup {
                        NavRow { ExploreView() } label: {
                            GameRow(symbol: "map", title: "Explore", tag: MeshNetwork.meshtastic.name,
                                    text: "Your collection and your ground: Nodedex, achievements, Territory and coverage walks.")
                        }
                    }
                }
                .padding(Theme.Space.edge)
                .padding(.bottom, Theme.Space.xl)
            }
            .screen()
            .navigationTitle("Play")
            .toolbar { TabToolbar() }
            .navigationDestination(isPresented: $showHunt) { HuntView() }
            .navigationDestination(isPresented: $showGame) { HuntGameView() }
            // An accepted invite opens the hunt screen (or the Hunt game's).
            .onChange(of: router?.huntRequest ?? 0) { _, _ in showHunt = true }
            .onChange(of: router?.gameRequest ?? 0) { _, _ in if Features.smallPlay { showGame = true } }
            // Location only if already allowed: Daily Fox and Territory ask when opened.
            .onAppear { explore.begin(asking: false) }
            #if DEBUG
            // Developer-only: -FoxDemo (with -Practice) joins the pretend fox's hunt and opens it, for screenshots.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-FoxDemo") else { return }
                try? await Task.sleep(for: .seconds(2))
                hunt.huntCode = PracticeMesh.code
                hunt.playerName = "MAYA"
                showHunt = true
                try? await Task.sleep(for: .seconds(1))
                hunt.join()
            }
            #endif
            .onDisappear { explore.end() }
            .task { if den.nodes.isEmpty { await den.refresh() } }
        }
    }

    /// Back to whatever is running on this phone: a Hunt game, a hosted Fox Hunt, a hunt.
    @ViewBuilder private var inProgress: some View {
        if Features.smallPlay, gamePlay.isActive {
            NavigationLink { HuntGameView() } label: {
                Label("Hunt in progress: back to it", systemImage: gamePlay.isHider ? "eye.slash" : "scope")
            }
            .buttonStyle(.fieldPrimary)
        }
        // Hosting from this phone: back to the board (even after a restart). Hunting: back to the hunt.
        if referee.isHosting {
            NavigationLink { HostPhoneView() } label: {
                Label("Fox Hunt in progress: back to it", systemImage: "flag.2.crossed")
            }
            .buttonStyle(gamePlay.isActive ? FieldButtonStyle.field(.secondary, .regular) : FieldButtonStyle.fieldPrimary)
            if hunt.stage.isActive {
                NavigationLink { HuntView() } label: {
                    Label("Your hunter screen", systemImage: "scope")
                }
                .buttonStyle(.field(.secondary, .regular))
            }
        } else if hunt.stage.isActive {
            NavigationLink { HuntView() } label: {
                Label("Fox Hunt in progress: back to it", systemImage: "scope")
            }
            .buttonStyle(gamePlay.isActive ? FieldButtonStyle.field(.secondary, .regular) : FieldButtonStyle.fieldPrimary)
        }
    }

    /// The games on Play, by who's playing.
    enum Game: String, Hashable, CaseIterable {
        case hunt, prowl, gifts, daily, trails, solo
    }

    /// Just me: Daily Fox, trails, a solo hunt. Two: Hunt, Prowl, Geo Gifts. Three or more: Hunt, Prowl, trails.
    static func games(for players: Int) -> [Game] {
        switch players {
        case ...1: return [.daily, .trails, .solo]
        case 2: return [.hunt, .prowl, .gifts]
        default: return [.hunt, .prowl, .trails]
        }
    }

    private func card(_ g: Game) -> GameCard {
        switch g {
        case .hunt:
            return GameCard(symbol: "scope", kicker: "HUNT",
                            pitch: players >= 3 ? "One hides, everyone else races to find the pieces first."
                                                : "One hides up to three pieces, the other hunts them by signal. Then swap and beat their time.",
                            chips: ["15–30 min", "1–3 pieces", "phones OK"], detail: gamePlay.isActive ? "in progress" : nil)
        case .prowl:
            return GameCard(symbol: "figure.run", kicker: "PROWL",
                            pitch: "One of you is the fox, on the move. Track them by their node until you tag them.",
                            chips: ["10–20 min", "a node each"], detail: "soon")
        case .gifts:
            return GameCard(symbol: "gift", kicker: "GEO GIFTS",
                            pitch: "Leave a message that only opens when they stand in the right place.",
                            chips: ["any time", "no node needed"], detail: gifts.locked.isEmpty ? nil : "\(gifts.locked.count) locked")
        case .daily:
            return GameCard(symbol: "calendar", kicker: "DAILY FOX",
                            pitch: "A real node near you is today's fox. Keep your streak going.",
                            chips: ["5–60 min", "your node"])
        case .trails:
            return GameCard(symbol: "point.topleft.down.to.point.bottomright.curvepath", kicker: "TRAILS",
                            pitch: "Walk a loop of stops in your park, a clue at each one.",
                            chips: ["1–2 km", "a few stops", "phones OK"], detail: "soon")
        case .solo:
            return GameCard(symbol: "scope", kicker: "HUNT",
                            pitch: "Practise on your own: find a node near you by its signal.",
                            chips: ["solo", "your node"])
        }
    }

    @ViewBuilder private func destination(_ g: Game) -> some View {
        switch g {
        case .hunt: HuntGameView()
        case .prowl:
            ComingSoonView(title: "Prowl", symbol: "figure.run",
                           text: "One of you carries a node and is the fox, on the move. The others track that node by its signal until they tag you. Coming in an update.")
        case .gifts: GiftsView()
        case .daily: DailyFoxEntry()
        case .trails:
            ComingSoonView(title: "Trails", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                           text: "A loop of stops in your park, each with a clue, made by you or a friend. Coming in an update.")
        case .solo: SoloHuntSetup()
        }
    }

    /// The mark and a one-line status, like the top of a radio's screen.
    private var masthead: some View {
        HStack(spacing: 12) {
            RemiMark(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("WILDCAT MESH")
                    .font(Theme.Fonts.label)
                    .tracking(Theme.labelTracking)
                    .foregroundStyle(Theme.textSecondary)
                Text(Self.status(RadioStatus.meshtastic(radio), RadioStatus.meshcore(meshcore), RadioStatus.rnode(rnode),
                                 practice: radio.source == .practice && meshcore.isDemo))
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    /// The masthead line, reading every radio: "3 radios connected · 11 heard",
    /// "MeshCore · Hilltop · 5 heard", "No radio connected · …". "Heard" counts the
    /// mesh nodes; the RNode hears packets, not nodes, so it adds to the count of
    /// radios but not to the heard.
    static func status(_ mt: RadioStatus, _ mc: RadioStatus, _ rn: RadioStatus? = nil, practice: Bool = false) -> String {
        let up = [mt, mc, rn].compactMap { $0 }.filter(\.connected)
        switch up.count {
        case 0:
            return "No radio connected · games still work in practice"
        case 1:
            let r = up[0]
            let heard = r.network == nil ? nil : r.heard
            return "\(r.kindName) · \(r.name)" + (heard.map { " · \($0) heard" } ?? "")
        default:
            let heard = up.filter { $0.network != nil }.compactMap(\.heard).reduce(0, +)
            let pretend = up.filter { $0.network != nil }.count
            return practice ? "Practice · \(pretend) pretend radios · \(heard) heard" : "\(up.count) radios connected · \(heard) heard"
        }
    }
}

/// A game on Play (AB row): an outlined glyph, the name, one line about it,
/// an optional tag or count, and a chevron.
struct GameRow: View {
    let symbol: String
    let title: String
    var tag: String? = nil
    let text: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Theme.Fonts.heading)
                        .foregroundStyle(Theme.textPrimary)
                    if let tag { Tag(tag) }
                }
                Text(text)
                    .font(Theme.Fonts.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let detail {
                Text(detail)
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Chevron()
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Daily Fox from its card on Play: the hunt when one is running or done today, else how to start one.
private struct DailyFoxEntry: View {
    @Environment(ExploreModel.self) private var explore

    var body: some View {
        if explore.todayRun != nil {
            DailyFoxView()
        } else {
            ScrollView {
                DailyFoxCard().padding(Theme.Space.edge)
            }
            .screen()
            .navigationTitle("Daily Fox")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { explore.begin() }
            .onDisappear { explore.end() }
        }
    }
}
