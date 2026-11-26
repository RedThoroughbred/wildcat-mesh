import SwiftUI
import WildcatRadioCore

struct HuntView: View {
    @Environment(HuntModel.self) private var hunt
    @Environment(Radio.self) private var radio
    @Environment(DenStore.self) private var den
    @Environment(PhoneReferee.self) private var referee
    @Environment(InviteHandler.self) private var invites
    @Environment(\.tabRouter) private var router
    @State private var scanning = false
    @State private var showClaim = false
    @State private var confirmLeave = false
    @State private var lastPing: Date?
    @State private var pings = 0

    /// The instrument's keys are pinned at the bottom while there's a fox to hunt.
    private var showsKeys: Bool {
        guard hunt.fox != nil else { return false }
        switch hunt.stage {
        case .hunting, .found: return true
        default: return false
        }
    }

    private var isHunting: Bool { if case .hunting = hunt.stage { return true } else { return false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = hunt.notice {
                    ToastBanner(text: notice, kind: .info)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // Hosting from this phone: the controls stay one tap away, even while hunting too.
                if referee.isHosting, hunt.stage.isActive, let b = referee.board {
                    NavigationLink { HostPhoneView() } label: {
                        FieldRow(symbol: "flag.2.crossed", title: "You're hosting \(b.hunt.code)",
                                 subtitle: b.hunt.phase == .lobby ? "Lobby open · tap to start" : "Hunt \(b.hunt.phase.rawValue)")
                            .panel(.inset)
                    }
                    .buttonStyle(.rowPress)
                }
                switch hunt.stage {
                case .idle, .joining:
                    lobby
                case .hunting:
                    HuntHUD(pings: pings)
                case .found(let place, let points, let proofs, let minutes):
                    ResultCard(title: "FOUND IT", subtitle: "#\(place) · +\(points) pts · \(minutes) min",
                               proofs: proofs)
                    HuntHUD(pings: pings)
                case .ended(let winner, let found, let total):
                    if let mine = hunt.myFind {
                        ResultCard(title: "YOU FOUND IT", subtitle: "#\(mine.place) · +\(mine.points) pts · \(mine.minutes) min",
                                   proofs: mine.proofs)
                    }
                    ResultCard(title: hunt.endedOnTime ? "TIME'S UP" : "HUNT OVER",
                               subtitle: (winner.map { "\($0) wins" } ?? "No finds") + " · \(found)/\(total) found",
                               proofs: [], tint: Theme.textPrimary, celebrate: false,
                               lines: hunt.endedOnTime ? ["The hunt ended when time ran out."] : [])
                    Button("New hunt") { hunt.reset() }
                        .buttonStyle(.fieldPrimary)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 4)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: hunt.notice)
        }
        .screen()
        .safeAreaInset(edge: .bottom) {
            if showsKeys { keys }
        }
        // The instrument takes the whole screen while hunting (AB/06): the keys replace the tab bar.
        .toolbar(showsKeys ? .hidden : .automatic, for: .tabBar)
        .navigationTitle("Fox Hunt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                FoxNavTitle(title: "Fox Hunt", network: .meshtastic, via: radio.huntVia, connected: radio.isReady)
            }
            ToolbarItem(placement: .topBarTrailing) { GuideButton(chapter: "foxhunt") }
        }
        .sheet(isPresented: $scanning) {
            QRScanner(accept: { HuntInvite(link: $0) != nil }) { code in
                if invites.open(code) { scanning = false }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showClaim) { ClaimSheet() }
        // So an accepted invite doesn't stack a second hunt screen on this one.
        .onAppear { router?.huntScreensShown += 1 }
        .onDisappear { router?.huntScreensShown -= 1 }
    }

    // MARK: Before the hunt

    @ViewBuilder private var lobby: some View {
        ModuleHeader(1, "Join a hunt")
        if radio.isReady { JoinCard() } else { ConnectFirstCard() }
        ModuleHeader(2, "Other ways to play")
            .padding(.top, 8)
        FieldGroup {
            Button { scanning = true } label: {
                FieldRow(symbol: "qrcode.viewfinder", title: "Scan a host's QR", subtitle: "Joins their hunt and adds its channel")
            }
            .buttonStyle(.rowPress)
            FieldDivider()
            NavRow { HostPhoneView() } label: {
                FieldRow(symbol: "flag.2.crossed",
                         title: referee.isHosting ? "Your hunt · \(referee.board?.hunt.code ?? "")" : "Host from this phone",
                         subtitle: "Your phone referees; hunters scan one QR")
            }
            FieldDivider()
            NavRow { SoloHuntSetup() } label: {
                FieldRow(symbol: "scope", title: "Solo hunt", subtitle: "Hunt any Meshtastic node by its signal, no referee")
            }
            FieldDivider()
            NavRow { MeshCoreHuntView() } label: {
                FieldRow(symbol: "dot.radiowaves.left.and.right", title: "Repeater hunt",
                         subtitle: "Find a MeshCore repeater by its signal")
            }
            if den.isPaired {
                FieldDivider()
                NavRow { HostView() } label: {
                    FieldRow(symbol: "house.lodge", title: "Host on the Den", subtitle: "Your base station referees")
                }
            }
        }
    }

    // MARK: Keys

    private var canPing: Bool {
        radio.isReady && radio.source == .bluetooth
            && (lastPing.map { Date().timeIntervalSince($0) >= SoloHunt.pingCooldown } ?? true)
    }

    private var keys: some View {
        FoxKeyBar {
            PingKey(lastPing: lastPing, cooldown: SoloHunt.pingCooldown, enabled: radio.isReady && radio.source == .bluetooth) {
                ping()
            }
            if isHunting {
                StatusKey("Found it", symbol: "flag.checkered") { showClaim = true }
            }
            TicksKey()
            StatusKey("Leave", symbol: "xmark") { confirmLeave = true }
                .confirmationDialog("Leave this hunt?", isPresented: $confirmLeave, titleVisibility: .visible) {
                    Button("Leave hunt", role: .destructive) { hunt.leave() }
                } message: {
                    Text("The referee takes you off the board. You can join again with the code.")
                }
        }
    }

    /// Asks the fox to answer (a traceroute) for a fresh reading, like Solo
    /// hunt's ping: at most one per 30 s, only with a real node.
    private func ping() {
        guard canPing, let fox = hunt.fox else { return }
        _ = radio.sendTraceroute(to: fox, channel: radio.session.channel(toReach: fox))
        lastPing = Date()
        pings += 1
    }
}

// MARK: - Before the hunt

/// Multiplayer hunts run over Meshtastic today (the referee reads Meshtastic packets).
private struct ConnectFirstCard: View {
    var body: some View {
        NeedsRadioNotice(.meshtastic, why: "Your node hears the fox, and hunt moves travel on its WGHUNT channel. Or practice with a pretend fox.",
                         practice: {})
    }
}

private struct JoinCard: View {
    @Environment(HuntModel.self) private var hunt
    @Environment(Radio.self) private var radio

    var body: some View {
        @Bindable var hunt = hunt
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                NetworkTag(.meshtastic, via: radio.source == .practice ? "practice radio" : nil)
                Spacer()
                if let ch = hunt.huntChannel {
                    Tag("WGHUNT · slot \(ch)")
                }
            }
            LabeledField(title: "Hunt code", text: $hunt.huntCode, prompt: "FOX7")
                .textInputAutocapitalization(.characters)
            LabeledField(title: "Your name", text: $hunt.playerName, prompt: "MAYA")
                .textInputAutocapitalization(.characters)
            if hunt.huntChannel == nil {
                Notice(text: "No WGHUNT channel on your node: moves go out on the primary channel.")
            }
            HStack(spacing: 10) {
                Button {
                    hunt.join()
                } label: {
                    HStack(spacing: 8) {
                        if hunt.stage == .joining { ProgressView().tint(Theme.onAccent) }
                        Text(hunt.stage == .joining ? "Waiting for the referee…" : "Join")
                    }
                }
                .buttonStyle(.fieldPrimary)
                .disabled(hunt.huntCode.isEmpty || hunt.stage == .joining)

                if hunt.stage == .joining {
                    Button("Cancel") { hunt.cancelJoin() }
                        .buttonStyle(.field(.secondary, .large))
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Button("Ask the host") { hunt.askHost() }
                        .buttonStyle(.field(.secondary, .large))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            if let status = hunt.refereeStatus {
                MetaLine(status)
            }
            if radio.source == .practice {
                Notice(text: "Practice: the code on the pretend fox is \(PracticeMesh.code).", symbol: "info.circle")
            }
        }
        .panel()
    }
}

// MARK: - During the hunt

/// The hunt instrument for a Den- or phone-refereed hunt: your own node's
/// readings of the fox, and the referee's verdict and bearing.
struct HuntHUD: View {
    @Environment(HuntModel.self) private var hunt
    @Environment(Radio.self) private var radio
    @Environment(Heading.self) private var heading
    @Environment(\.scenePhase) private var phase
    @AppStorage(TicksKey.storageKey) private var ticks = true
    /// Pings sent from this screen.
    var pings: Int = 0

    /// A reading in the last three minutes: the fox is still being heard.
    private var fresh: Bool {
        guard let t = hunt.tracker?.latest?.time else { return false }
        return Date().timeIntervalSince(t) < 180
    }

    /// The referee's latest line, if any.
    private var verdict: (trend: WG.Trend, best: WG.Signal, bearing: Int?, askForCode: Bool)? {
        if case .warmth(_, let trend, _, _, let best, let bearing, let askForCode) = hunt.warmth {
            return (trend, best, bearing, askForCode)
        }
        return nil
    }

    var body: some View {
        let tracker = hunt.tracker
        let samples = tracker?.samples ?? []
        let score = tracker?.latest?.score ?? 0
        VStack(alignment: .leading, spacing: 8) {
            if hunt.fox == nil {
                PickFoxCard()
                Button("Leave hunt", role: .destructive) { hunt.leave() }
                    .buttonStyle(.field(.quiet, .regular))
            } else {
                FoxTargetCard(network: .meshtastic, fox: hunt.foxLabel() ?? "?", detail: foxDetail, code: hunt.huntCode)
                FoxSignalPanel(network: .meshtastic, samples: samples, best: tracker?.best, listening: listening)
                    .hapticTicker(score: score, active: ticks && hunt.stage == .hunting && fresh && phase == .active)
                FoxInstrumentRow {
                    FoxBearingRadar(bearing: verdict?.bearing.map(Double.init), heading: heading.degrees,
                                    tint: MeshNetwork.meshtastic.color, pulse: samples.count, live: fresh,
                                    noBearing: "waiting for referee")
                } readouts: {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        FoxReadoutGrid(cells: cells(now: ctx.date)) { refereeCell }
                    }
                }
                FoxInstructionLine(instruction)
            }
        }
        .sensoryFeedback(trigger: tracker?.trend ?? .none) { _, new in
            switch new {
            case .warmer: return .increase
            case .colder: return .decrease
            default: return nil
            }
        }
        .onAppear { heading.start() }
        .onDisappear { heading.stop() }
    }

    private var foxDetail: String? {
        guard let fox = hunt.fox else { return nil }
        return radio.session.nodes[fox]?.longName ?? fox.id
    }

    private var listening: String {
        (hunt.tracker?.indirectCount ?? 0) > 0
            ? "Heard only through relays so far: that says it's on, not how far. Move around."
            : "Waiting to hear the fox directly. It beacons about once a minute."
    }

    private func cells(now: Date) -> [FoxCell] {
        let tracker = hunt.tracker
        let samples = tracker?.samples ?? []
        let unit = FoxReadout.unit(for: tracker?.latest)
        let best = tracker?.best.flatMap { FoxReadout.value($0, unit) }
        let hops = hunt.fox.flatMap { radio.session.nodes[$0]?.hopsAway }
        return [
            clockCell(now: now),
            pings > 0 ? FoxCell(label: "Pings", value: "\(pings)", sub: "\(samples.count) readings")
                      : FoxCell(label: "Readings", value: "\(samples.count)",
                                sub: (tracker?.indirectCount ?? 0) > 0 ? "+\(tracker?.indirectCount ?? 0) relayed" : nil),
            FoxCell(label: "Best", value: best.map { FoxReadout.format($0, unit: unit) } ?? "--", unit: best == nil ? nil : unit.short),
            FoxCell(label: "Hops", value: hops.map(String.init) ?? "--",
                    sub: hops.map { $0 == 0 ? "direct" : "relayed" }),
        ]
    }

    /// A countdown when the hunt has a time limit, else time since the first reading.
    private func clockCell(now: Date) -> FoxCell {
        guard hunt.timeLimit != nil else {
            let first = hunt.tracker?.samples.first
            return FoxCell(label: "Elapsed", value: first.map { FoxReadout.clock(now.timeIntervalSince($0.time)) } ?? "--",
                           sub: first == nil ? "from first reading" : nil)
        }
        guard let left = hunt.timeRemaining(at: now) else {
            return FoxCell(label: "Time left", value: "--", sub: "asking the host")
        }
        return FoxCell(label: "Time left", value: FoxReadout.clock(left.rounded(.up)),
                       sub: hunt.deadline == nil ? "starts at GO" : left <= 0 ? "time's up" : nil)
    }

    private var refereeCell: some View {
        let text: String
        if let v = verdict {
            let best = v.best.rssi.map { "\(FoxReadout.format(Double($0), unit: .rssi)) dBm" }
                ?? v.best.snr.map { "\(FoxReadout.format($0, unit: .snr)) dB SNR" } ?? v.best.wire
            text = "\(v.trend.rawValue.capitalized) · best \(best)"
        } else {
            text = "Waiting for its first verdict."
        }
        return FoxWideCell(label: "Referee", text: text)
    }

    private var instruction: (lead: String, rest: String) {
        let samples = hunt.tracker?.samples ?? []
        let unit = FoxReadout.unit(for: samples.last)
        return FoxReadout.instruction(hasReading: !samples.isEmpty,
                                      warmth: FoxReadout.warmth(change: FoxReadout.change(samples, unit: unit), unit: unit),
                                      bearing: verdict?.bearing.map(Double.init),
                                      veryClose: verdict?.askForCode ?? false,
                                      listening: listening)
    }
}

private struct PickFoxCard: View {
    @Environment(HuntModel.self) private var hunt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(1, "Which node is the fox?", detail: "\(hunt.candidateFoxes.count)")
            Text(hunt.foxHint.map { "The referee calls it \($0), but your node hasn't heard of it yet. Pick it, or wait." }
                 ?? "Waiting for the referee to name the fox. You can also pick it.")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FieldGroup {
                ForEach(Array(hunt.candidateFoxes.enumerated()), id: \.element.num) { i, n in
                    if i > 0 { FieldDivider() }
                    Button {
                        hunt.choose(fox: n.num)
                    } label: {
                        FieldRow(symbol: "antenna.radiowaves.left.and.right", tint: MeshNetwork.meshtastic.color,
                                 title: n.shortName ?? "?", subtitle: n.longName, detail: n.num.short)
                    }
                    .buttonStyle(.rowPress)
                }
            }
        }
    }
}

// MARK: - Claim and results

private struct ClaimSheet: View {
    @Environment(HuntModel.self) private var hunt
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var digits: CGFloat = 44

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                ModuleHeader(nil, "Code on the fox")
                TextField("0000", text: $code)
                    .font(.system(size: digits, weight: .light, design: .monospaced))
                    .tracking(8)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .onAppear { focused = true }
                    // The codes on the boxes are 4 digits.
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(4))
                        if digits != new { code = digits }
                    }
                    .fieldInput()
                Text("Every fox box has a 4-digit code written on it. Type it to prove you found it.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    hunt.claim(code: code)
                    dismiss()
                } label: {
                    Label("Claim the find", systemImage: "flag.checkered")
                }
                .buttonStyle(.fieldPrimary)
                .disabled(code.count < 4)
                Spacer()
            }
            .padding(20)
            .screen()
            .navigationTitle("Found it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.bg)
    }
}

/// "FOUND IT": the result card, shared by every hunt.
struct ResultCard: View {
    let title: String
    let subtitle: String
    var proofs: [WG.Proof] = []
    var tint: Color = Theme.ok
    var celebrate: Bool = true
    var lines: [String] = []
    @State private var burst = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if celebrate { StatusLED(color: tint, size: 6) }
                CardLabel(celebrate ? "Result" : "Hunt")
            }
            Text(title)
                .font(.system(.largeTitle, design: .monospaced, weight: .light))
                .tracking(1)
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(subtitle)
                .font(Theme.Fonts.data)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            ForEach(lines, id: \.self) { line in
                Text(line).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            }
            if !proofs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(proofs, id: \.self) { p in Tag(Self.label(p), color: Theme.ok) }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .panel(.hero)
        .overlay { if celebrate { CelebrationBurst(trigger: burst, colors: [tint, Theme.textPrimary, Theme.textSecondary]) } }
        .scaleEffect(burst > 0 || reduceMotion || !celebrate ? 1 : 0.94)
        .onAppear {
            guard celebrate else { return }
            Haptics.success()
            withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.pop)) { burst += 1 }
        }
        .accessibilityElement(children: .combine)
    }

    static func label(_ p: WG.Proof) -> String {
        switch p {
        case .rfWitnessed: return "RF WITNESSED"
        case .rfAttested: return "RF ATTESTED"
        case .code: return "CODE"
        }
    }
}
