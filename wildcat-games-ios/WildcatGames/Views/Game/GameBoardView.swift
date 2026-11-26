import SwiftUI
import WildcatRadioCore

/// The hunter's board (Small Play 2, "Hunting"): the piece in focus as a big instrument (your
/// node's signal, or the GPS guide without a node), the other pieces as rows, the clock, what
/// you've found and walked; Found it, ticks and leave at the bottom.
struct GameBoardView: View {
    @Environment(GamePlay.self) private var play
    @Environment(Radio.self) private var radio
    @Environment(InviteHandler.self) private var invites
    @Environment(\.scenePhase) private var phase
    @AppStorage(TicksKey.storageKey) private var ticks = true
    @State private var claiming: ClaimTarget?
    @State private var confirmLeave = false
    @State private var scanning = false

    struct ClaimTarget: Identifiable { let id: Int }

    private var game: HuntGame? { play.game }
    private var round: HuntGame.Round? { play.round }
    private var live: Bool { round?.stage == .live }
    private var pieces: [HuntGame.Piece] { game?.pieces ?? [] }
    private var myFinds: [HuntGame.Find] { game?.myFinds ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let n = play.notice {
                    ToastBanner(text: n, kind: .info).transition(.move(edge: .top).combined(with: .opacity))
                }
                if live {
                    sourceLine
                    if let p = play.piece(play.focus) ?? pieces.first { focused(p) }
                    others
                    readouts
                } else {
                    waiting
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 4)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: play.notice)
        }
        .screen()
        .safeAreaInset(edge: .bottom) { if live { keys } }
        .toolbar(live ? .hidden : .automatic, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GameNavTitle(title: "Hunt · round \(round?.number ?? 1)",
                             subtitle: "\(pieces.count) piece\(pieces.count == 1 ? "" : "s") hidden · you hunt")
            }
            ToolbarItem(placement: .topBarTrailing) { if live { GameClockPill() } else { GuideButton(chapter: "foxhunt") } }
        }
        .sheet(item: $claiming) { GameClaimView(piece: $0.id) }
        .sheet(isPresented: $scanning) {
            QRScanner(accept: { HuntGame.Invite(link: $0) != nil }) { code in
                if invites.open(code) { scanning = false }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Leave this hunt?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave the hunt", role: .destructive) { play.endGame() }
        } message: {
            Text("The hider's referee takes you off every piece. The game ends on this phone.")
        }
        .onAppear {
            play.location.begin(asking: play.guide)
            if play.guide, let fix = play.location.fix { play.sampleScent(at: fix) }
        }
        .onDisappear { play.location.end() }
    }

    // MARK: Waiting for the round

    @ViewBuilder private var waiting: some View {
        let hider = round?.hider.isEmpty == false ? round!.hider : "Your friend"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.meshtastic)
                Text("\(hider) is hiding the pieces").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
            }
            Text(play.guide
                 ? "No node, so you hunt with the GPS guide. Scan the hider's QR code once every piece is hidden, then start your clock when they say go."
                 : "The round starts when every piece is hidden. Your node joins each piece; the GO comes over the radio.")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        SectionLabel("Pieces", detail: play.guide ? "guide" : "\(play.joined.count) of \(pieces.count) joined")
            .padding(.top, 6)
        FieldGroup {
            ForEach(Array(pieces.enumerated()), id: \.element.index) { i, p in
                if i > 0 { FieldDivider() }
                HStack(spacing: 10) {
                    PieceTag(index: p.index)
                    Text(p.name).font(.system(.subheadline, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(waitingState(p)).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.Space.rowH)
                .frame(minHeight: 48)
            }
        }
        if play.guide {
            Button {
                Haptics.success()
                play.go()
            } label: { Label("Start my clock: they said go", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                .buttonStyle(.fieldPrimary)
                .disabled(round?.hidden.allSatisfy { $0.sharedSpot == nil } ?? true)
        } else if play.joined.count < pieces.count {
            Button { play.joinRound() } label: {
                HStack(spacing: 8) {
                    if play.joining { ProgressView().tint(Theme.onAccent) }
                    Text(play.joining ? "Waiting for the hider…" : "Join again")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
            .disabled(play.joining || !radio.isReady)
        }
        Button { scanning = true } label: {
            FieldRow(symbol: "qrcode.viewfinder", title: "Scan the hider's QR", subtitle: "For their claim lines, and the guide's spots")
                .panel(.inset)
        }
        .buttonStyle(.rowPress)
        Button("Leave the game", role: .destructive) { confirmLeave = true }
            .buttonStyle(.field(.quiet, .regular))
            .frame(maxWidth: .infinity)
    }

    private func waitingState(_ p: HuntGame.Piece) -> String {
        if play.guide { return round?.hidden(p.index)?.sharedSpot == nil ? "no spot yet" : "spot in" }
        return play.joined.contains(p.index) ? "joined" : "no answer yet"
    }

    // MARK: Live

    private var sourceLine: some View {
        HStack(spacing: 8) {
            Text(play.guide ? "GUIDE · GPS" : "SIGNAL · YOUR NODE")
                .font(.system(size: 10.5, design: .monospaced)).tracking(1)
                .foregroundStyle(play.guide ? Theme.amberBright : Theme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(play.guide ? "from your phone's GPS, not the radio" : "heard directly by your node")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
            Spacer()
        }
    }

    private func found(_ p: HuntGame.Piece) -> HuntGame.Find? { myFinds.first { $0.piece == p.index } }

    /// The piece's latest reading by this phone (signal) or the guide.
    private struct Look {
        var value: String?
        var unit: String
        var fraction: Double
        var zone: Double
        var trend: FoxTracker.Trend
        var score: Double
        var inZone: Bool
        var detail: String?
    }

    private func look(_ p: HuntGame.Piece) -> Look {
        let cal = round?.hidden(p.index)?.calibration ?? HuntGame.Calibration(reading: nil)
        if play.guide {
            let r = play.scent[p.index]
            return Look(value: r?.words, unit: "", fraction: (r?.score ?? 0) / 100, zone: 0.9,
                        trend: play.scentTrend[p.index] ?? .none, score: r?.score ?? 0, inZone: r?.isHot ?? false,
                        detail: r == nil ? (round?.hidden(p.index)?.sharedSpot == nil ? "no spot in your invite" : "waiting for GPS") : "guide")
        }
        let s = play.reading(p.index)
        let tracker = play.trackers[p.index]
        // RSSI when the node gives it: the claim lines are RSSI, as the referee rules.
        let unit: FoxReadout.Unit = s.map { $0.rssi != nil ? .rssi : .snr } ?? .rssi
        let value = s.flatMap { FoxReadout.value($0, unit) }
        return Look(value: value.map { FoxReadout.format($0, unit: unit) }, unit: unit.label,
                    fraction: ClaimMeter.fraction(rssi: s?.rssi.map(Double.init), snr: s?.snr, claimRSSI: cal.claimRSSI, claimSNR: cal.claimSNR),
                    zone: 0.8, trend: tracker?.trend ?? .none, score: s?.score ?? 0, inZone: play.isInZone(p.index),
                    detail: tracker?.best.map { b in
                        let bv = FoxReadout.value(b, unit).map { FoxReadout.format($0, unit: unit) } ?? "--"
                        return "best \(bv)"
                    })
    }

    @ViewBuilder private func focused(_ p: HuntGame.Piece) -> some View {
        let l = look(p)
        let f = found(p)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PieceTag(index: p.index, found: f != nil)
                Text(p.name).font(.system(.title3, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if f == nil { trendLabel(l.trend) }
            }
            if let f {
                Text(FoxReadout.clock(f.elapsed)).font(.system(size: 56, weight: .light, design: .monospaced)).foregroundStyle(Theme.ok)
                Text("Found, " + Self.proofWords(f.proofs) + ". Pick another piece below.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(l.value ?? "Listening")
                        .font(.system(size: l.value == nil || play.guide ? 34 : 64, weight: .light, design: .monospaced))
                        .tracking(l.value == nil || play.guide ? 0 : -2)
                        .foregroundStyle(l.value == nil ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                    if l.value != nil, !l.unit.isEmpty {
                        Text(l.unit).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        if !play.guide { HeardAgo(time: play.trackers[p.index]?.latest?.time) }
                        if let d = l.detail { Text(d).font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary) }
                    }
                }
                ClaimMeter(value: l.fraction, zone: l.zone)
                instruction(p, l)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .hapticTicker(score: l.score, active: ticks && live && f == nil && l.value != nil && phase == .active)
        .sensoryFeedback(trigger: l.trend) { _, new in
            switch new {
            case .warmer: return .increase
            case .colder: return .decrease
            default: return nil
            }
        }
    }

    private func trendLabel(_ t: FoxTracker.Trend) -> some View {
        let (word, symbol, color): (String, String, Color) = {
            switch t {
            case .warmer: return ("Warmer", "arrowtriangle.up.fill", Theme.ok)
            case .colder: return ("Colder", "arrowtriangle.down.fill", Theme.alert)
            case .steady: return ("Steady", "arrowtriangle.right.fill", Theme.textSecondary)
            case .none: return ("", "", Theme.textSecondary)
            }
        }()
        return HStack(spacing: 5) {
            if !symbol.isEmpty { Image(systemName: symbol).font(.system(size: 10)) }
            Text(word).font(.system(.subheadline, weight: .semibold))
        }
        .foregroundStyle(color)
    }

    private func instruction(_ p: HuntGame.Piece, _ l: Look) -> some View {
        let (lead, rest): (String, String) = {
            if l.value == nil {
                return play.guide ? ("Waiting.", "The guide needs a GPS fix, and the spot from the hider's invite.")
                                  : ("Listening.", "Waiting to hear \(p.name) directly. It beacons about once a minute.")
            }
            if l.inZone { return ("Right on it.", "Look around you, then tap Found it.") }
            if l.fraction >= 0.65 { return ("Close.", "A few more steps this way and you can claim it.") }
            switch l.trend {
            case .warmer: return ("Warmer.", "Keep going this way.")
            case .colder: return ("Colder.", "Turn around, or try another way.")
            default: return ("Keep moving.", play.guide ? "The guide changes every few steps." : "The signal changes as you walk.")
            }
        }()
        return (Text(lead).bold().foregroundStyle(Theme.textPrimary) + Text(" " + rest).foregroundStyle(Theme.textSecondary))
            .font(Theme.Fonts.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func proofWords(_ proofs: [FoxReferee.Proof]) -> String {
        let code = proofs.contains(.code), signal = proofs.contains(.rfAttested) || proofs.contains(.rfWitnessed)
        return code && signal ? "signal + code" : code ? "code" : signal ? "signal" : "found"
    }

    @ViewBuilder private var others: some View {
        let rest = pieces.filter { $0.index != play.focus }
        if !rest.isEmpty {
            SectionLabel("Also hidden").padding(.top, 4)
            VStack(spacing: 8) {
                ForEach(rest, id: \.index) { p in
                    Button {
                        Haptics.selection()
                        play.focus = p.index
                    } label: { otherRow(p) }
                        .buttonStyle(.rowPress)
                }
            }
        }
    }

    private func otherRow(_ p: HuntGame.Piece) -> some View {
        let l = look(p)
        let f = found(p)
        return HStack(spacing: 12) {
            PieceTag(index: p.index, found: f != nil)
            Text(p.name).font(.system(.callout, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            if let f {
                Text(FoxReadout.clock(f.elapsed)).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.ok)
            } else {
                SegmentMeter(lit: Int((l.fraction / max(l.zone, 0.01) * 5).rounded(.down)), of: 5,
                             tint: l.inZone ? Theme.ok : Theme.amberDim, size: .regular)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(l.trend == .none ? (l.value == nil ? "listening" : "heard") : l.trend == .warmer ? "warmer" : l.trend == .colder ? "colder" : "steady")
                    Text(l.value ?? "--")
                }
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .padding(14)
        .panel()
        .accessibilityHint("Shows it big")
    }

    private var readouts: some View {
        HStack(spacing: 8) {
            stat("Found", "\(myFinds.count)/\(pieces.count)")
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                stat("Elapsed", round?.startedAt.map { FoxReadout.clock(min(ctx.date.timeIntervalSince1970, round?.endedAt ?? .infinity) - $0) } ?? "--")
            }
            stat("Walked", play.walked < 1000 ? "\(Int(play.walked)) m" : String(format: "%.1f km", play.walked / 1000))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, design: .monospaced)).tracking(1.2).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(.title3, design: .monospaced)).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .combine)
    }

    private var keys: some View {
        FoxKeyBar {
            StatusKey("Found it", symbol: "flag.checkered", primary: true) {
                // The piece in focus, or the first one not found yet.
                let focusOpen = play.piece(play.focus).map { found($0) == nil } ?? false
                if let target = focusOpen ? play.focus : pieces.first(where: { found($0) == nil })?.index {
                    claiming = ClaimTarget(id: target)
                }
            }
            TicksKey()
            StatusKey("Leave", symbol: "xmark") { confirmLeave = true }
        }
    }
}

/// Claim a piece (Small Play 2, "Claim"): in the zone by this phone's node (or the guide), the
/// code on the label, or the signal alone when the hider allowed it.
struct GameClaimView: View {
    let piece: Int
    @Environment(GamePlay.self) private var play
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var answer: String?
    @FocusState private var focused: Bool

    private var name: String { play.pieceName(piece) }
    private var mode: FoxReferee.Mode { play.game?.settings.mode ?? .code }
    private var inZone: Bool { play.guide ? (play.scent[piece]?.isHot ?? false) : play.isInZone(piece) }

    private var value: String {
        if play.guide { return play.scent[piece]?.words ?? "--" }
        guard let s = play.reading(piece) else { return "--" }
        let unit: FoxReadout.Unit = s.rssi != nil ? .rssi : .snr
        return FoxReadout.value(s, unit).map { FoxReadout.format($0, unit: unit) } ?? "--"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Circle().strokeBorder(inZone ? Theme.ok : Theme.textQuaternary, lineWidth: 2)
                            .background(Circle().fill((inZone ? Theme.ok : Theme.textQuaternary).opacity(0.06)))
                            .shadow(color: inZone ? Theme.ok.opacity(0.2) : .clear, radius: 18)
                        VStack(spacing: 4) {
                            Text(value).font(.system(size: play.guide ? 24 : 44, weight: .light, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.5)
                            Text(inZone ? "IN THE ZONE" : "NOT YET")
                                .font(.system(size: 12, design: .monospaced)).tracking(1.6)
                                .foregroundStyle(inZone ? Theme.ok : Theme.textTertiary)
                        }
                        .padding(20)
                    }
                    .frame(width: 180, height: 180)
                    .padding(.top, 16)
                    .accessibilityElement(children: .combine)
                    Text(inZone ? "You're right on it." : "Not in the zone yet.")
                        .font(.system(.title2, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text(play.guide
                         ? (inZone ? "The guide says it's within about 25 m. Look around for the box." : "The guide doesn't think you're close. You can still claim it if you've found it.")
                         : (inZone ? "Your node hears \(name) directly, stronger than the claim line. Look around you for the box." : "Your node doesn't hear \(name) above its claim line yet. Found the box anyway? The code works."))
                        .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 10) {
                        CardLabel("Code on the box's label")
                        TextField("0000", text: $code)
                            .font(.system(size: 34, weight: .light, design: .monospaced))
                            .tracking(10)
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .focused($focused)
                            .onChange(of: code) { _, new in
                                let d = String(new.filter(\.isNumber).prefix(4))
                                if d != new { code = d }
                                answer = nil
                            }
                            .fieldInput()
                        Text(modeNote).font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if let answer { Text(answer).font(Theme.Fonts.footnote).foregroundStyle(Theme.alert) }
                    }
                    .padding(16)
                    .panel()
                    Button { claim(code: code) } label: { Text("Claim \(name)").frame(maxWidth: .infinity) }
                        .buttonStyle(.fieldPrimary)
                        .disabled(code.count < 4)
                    if !play.guide, mode != .code {
                        Button { claim(code: nil) } label: { Text("Claim by signal only").frame(maxWidth: .infinity) }
                            .buttonStyle(.field(.secondary, .large))
                            .disabled(!inZone)
                    }
                }
                .padding(Theme.Space.edge)
            }
            .scrollDismissesKeyboard(.immediately)
            .screen()
            .navigationTitle("Claim \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
    }

    private var modeNote: String {
        if play.guide { return "With no node, the code on the label is how you claim: this phone checks it." }
        switch mode {
        case .code: return "In this game only the code counts. The hider chose \"code\"."
        case .signal: return "In this game the signal alone counts: get into the zone. A code isn't needed."
        case .either: return "Can't find the label? In this game the signal alone counts too. The hider chose \"signal or code\"."
        }
    }

    private func claim(code: String?) {
        if play.guide, let code {
            switch play.claimByCode(piece: piece, code: code) {
            case .found, .alreadyFound: Haptics.success(); dismiss()
            case .wrongCode: answer = "That's not \(name)'s code."
            case .notStarted: answer = "Start your clock first (the hider said go)."
            case .over: answer = "The round is over."
            case .noSuchPiece: answer = "That piece isn't in this round."
            }
            return
        }
        play.claim(piece: piece, code: code)
        Haptics.selection()
        dismiss()
    }
}
