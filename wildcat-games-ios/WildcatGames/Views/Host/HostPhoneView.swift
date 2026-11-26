import SwiftUI
import WildcatRadioCore

/// Host a Fox Hunt refereed by this phone: pick the fox, set its code, show
/// the join QR, start, and watch the board. No Den needed.
struct HostPhoneView: View {
    @Environment(PhoneReferee.self) private var host
    @Environment(Radio.self) private var radio
    @Environment(HuntModel.self) private var hunt
    @Environment(GamePlay.self) private var gamePlay
    @Environment(\.dismiss) private var dismiss
    @State private var fox: NodeNum?
    /// Starts as a random, non-obvious code: write it on the fox, or change it.
    @State private var foxCode = FoxCode.random()
    @State private var mode: FoxReferee.Mode = .code
    @State private var code = HostPhoneView.randomCode()
    /// Minutes; 0 is no limit.
    @State private var limitMinutes = HostPhoneView.defaultLimit
    @State private var confirmEnd = false

    static let limitChoices = [0, 10, 20, 30, 45]
    static let defaultLimit = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let e = host.error { ToastBanner(text: e, kind: .danger) }
                if host.resumed, host.isHosting {
                    Notice(text: "Picked up where your hunt was when the app closed.", symbol: "arrow.clockwise")
                }
                if let board = host.board {
                    header(board)
                    controls(board)
                    // In the lobby the QR comes first; once it's live, the board does.
                    let live = board.hunt.phase == .live
                    if live { hunters(board, number: 2) }
                    if board.hunt.phase != .ended, let invite = host.invite {
                        ModuleHeader(live ? 3 : 2, "Invite")
                            .padding(.top, 8)
                        inviteCard(invite)
                    }
                    if !live { hunters(board, number: board.hunt.phase == .ended ? 2 : 3) }
                } else {
                    form
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .scrollDismissesKeyboard(.immediately)
        .screen()
        .navigationTitle("Host a hunt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                FoxNavTitle(title: "Host a hunt", network: .meshtastic, via: radio.huntVia, connected: radio.isReady)
            }
        }
        .confirmationDialog("End the hunt for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End hunt", role: .destructive) { host.end() }
        }
    }

    static func randomCode() -> String {
        "FOX" + String((0..<2).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
    }

    // MARK: New hunt

    private var foxChoices: [NodeInfo] {
        let me = radio.session.myNode
        return radio.session.nodes.values.filter { $0.num != me }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
    }

    /// This phone referees a Hunt game round: one referee on the node at a time.
    private var refereeingGame: Bool { gamePlay.isHider && gamePlay.round?.stage != .over }

    private var canCreate: Bool {
        radio.isReady && fox != nil && foxCode.count == 4 && foxCode.allSatisfy(\.isNumber) && host.huntChannel != nil && !refereeingGame
    }

    @ViewBuilder private var form: some View {
        Text("Your phone referees the hunt through your node: hunters scan one QR code to join. No Den, no Pi.")
            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 6)
        if !radio.isReady {
            NeedsRadioNotice(.meshtastic, why: "Your phone referees the hunt through it, on the WGHUNT channel.")
        } else if host.huntChannel == nil {
            Notice(text: "Your node needs the WGHUNT channel: hunters talk to you on it. Add it in Node settings (or make a fox first; it creates one).")
        } else if refereeingGame {
            Notice(text: "You're refereeing a Hunt game (\(gamePlay.game?.code ?? "")). End it first: one hunt at a time on your node.")
        }
        ModuleHeader(1, "New hunt")
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Fox node")
                Picker("Fox node", selection: $fox) {
                    Text("Pick the fox").tag(NodeNum?.none)
                    ForEach(foxChoices, id: \.num) { n in
                        Text("\(n.shortName ?? n.num.short) · \(n.longName ?? n.num.id)").tag(NodeNum?.some(n.num))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fieldInput()
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledField(title: "Code written on the fox", text: $foxCode, prompt: "4417")
                    .keyboardType(.numberPad)
                    .onChange(of: foxCode) { _, v in if v.count > 4 { foxCode = String(v.prefix(4)) } }
                Text("A random code: write it on the fox, or type your own.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("How a find counts")
                FieldSegmented(options: [(FoxReferee.Mode.code, "Code"), (.signal, "Signal"), (.either, "Either")], selection: $mode)
                Text(modeHelp).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Time limit, minutes")
                FieldSegmented(options: Self.limitChoices.map { ($0, $0 == 0 ? "None" : "\($0)") }, selection: $limitMinutes)
                Text(limitMinutes == 0 ? "Runs until everyone finds the fox or you end it."
                                       : "Ends on its own \(limitMinutes) minutes after you start it.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            LabeledField(title: "Hunt code", text: $code, prompt: "FOX7")
                .textInputAutocapitalization(.characters)
            Button {
                if let fox {
                    _ = host.create(fox: fox, foxCode: foxCode, mode: mode, code: code,
                                    timeLimit: limitMinutes > 0 ? TimeInterval(limitMinutes) * 60 : nil)
                }
            } label: {
                Label("Open the lobby", systemImage: "qrcode").frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
            .disabled(!canCreate)
        }
        .panel()
    }

    private var modeHelp: String {
        switch mode {
        case .code: return "Hunters must type the 4-digit code written on the fox."
        case .signal: return "Getting very close by radio is a find. Good for kids."
        case .either: return "The code, or a very strong signal."
        }
    }

    // MARK: Running

    private func phaseWord(_ h: FoxReferee.Hunt) -> String {
        switch h.phase {
        case .lobby: return "Lobby"
        case .live: return "Live"
        case .ended: return h.endReason == .time ? "Time's up" : "Over"
        }
    }

    @ViewBuilder private func header(_ b: FoxReferee.Board) -> some View {
        let active = b.hunters.filter { !$0.left }
        let found = b.hunters.filter { $0.found != nil }.count
        ModuleHeader(1, "Your hunt") {
            HStack(spacing: 5) {
                StatusLED(color: Theme.ok, on: b.hunt.phase == .live, size: 6)
                Text(phaseWord(b.hunt))
            }
        }
        FoxTargetCard(network: .meshtastic, fox: b.hunt.foxName, detail: b.hunt.fox.id, code: b.hunt.code)
        InstrumentPanel {
            ReadoutRow {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if let limit = b.hunt.timeLimit {
                        // A countdown with a time limit (whole seconds, rounded up: it starts at 20:00).
                        let left = b.hunt.timeRemaining(at: ctx.date.timeIntervalSince1970) ?? limit
                        ReadoutCell("Time left", value: FoxReadout.clock(left.rounded(.up)),
                                    sub: b.hunt.startedAt == nil ? "starts with the hunt" : left <= 0 ? "time's up" : nil,
                                    tint: b.hunt.phase == .live && left <= 60 ? Theme.alert : Theme.textPrimary)
                    } else {
                        ReadoutCell("Elapsed", value: b.hunt.startedAt.map {
                            FoxReadout.clock((b.hunt.endedAt ?? ctx.date.timeIntervalSince1970) - $0)
                        } ?? "--", sub: b.hunt.startedAt == nil ? "not started" : nil)
                    }
                }
                CellDivider()
                ReadoutCell("Hunters", value: "\(active.count)")
                CellDivider()
                ReadoutCell("Found", value: "\(found)")
            }
            PanelDivider()
            HStack(spacing: 8) {
                CardLabel("Fox")
                Spacer()
                if let seen = b.hunt.foxSeen {
                    HeardAgo(time: Date(timeIntervalSince1970: seen))
                } else {
                    HStack(spacing: 5) {
                        StatusLED(color: Theme.alert, on: true, size: 5)
                        Text("not heard yet: power it up near your node").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func inviteCard(_ invite: HuntInvite) -> some View {
        VStack(spacing: 12) {
            CardLabel("Hunters scan this")
            QRImage(text: invite.link)
            Text("With the iPhone Camera or Wildcat. It adds \(invite.channelName) to their node and joins \(invite.code).")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            ShareLink(item: invite.link) { Label("Share invite link", systemImage: "square.and.arrow.up") }
                .buttonStyle(.field(.secondary, .regular))
            if !hunt.stage.isActive {
                Button {
                    hunt.join(invite: invite)
                    dismiss()
                } label: {
                    Label("Hunt too, on this phone", systemImage: "figure.walk").frame(maxWidth: .infinity)
                }
                .buttonStyle(.field(.secondary, .regular))
            }
        }
        .frame(maxWidth: .infinity)
        .panel()
    }

    @ViewBuilder private func controls(_ b: FoxReferee.Board) -> some View {
        switch b.hunt.phase {
        case .lobby:
            Button { host.start() } label: {
                Label("Start the hunt (\(b.hunters.filter { !$0.left }.count) joined)", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
        case .live:
            Button("End hunt", role: .destructive) { confirmEnd = true }
                .buttonStyle(.field(.destructive, .regular))
                .frame(maxWidth: .infinity)
        case .ended:
            if let w = b.hunt.winner {
                ToastBanner(text: "\(w) wins!", kind: .success)
            }
            if let why = Self.endLine(b.hunt) {
                MetaLine(why)
            }
            Button { host.reset(); code = Self.randomCode(); foxCode = FoxCode.random() } label: {
                Label("New hunt", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
        }
    }

    /// Why the hunt ended, in words.
    static func endLine(_ h: FoxReferee.Hunt) -> String? {
        switch h.endReason {
        case .time?: return "Time ran out" + (h.timeLimit.map { " after \(Int(($0 / 60).rounded())) minutes." } ?? ".")
        case .allFound?: return "Everyone found the fox."
        case .host?: return "You ended the hunt."
        case nil: return nil
        }
    }

    @ViewBuilder private func hunters(_ b: FoxReferee.Board, number: Int) -> some View {
        ModuleHeader(number, "Hunters", detail: "\(b.hunters.filter { !$0.left }.count)")
            .padding(.top, 8)
        if b.hunters.isEmpty {
            Text("Nobody yet. Hunters scan the QR code, or send WG JOIN \(b.hunt.code) on \(b.hunt.channelName).")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            FieldGroup {
                ForEach(Array(b.hunters.enumerated()), id: \.element.id) { i, h in
                    if i > 0 { FieldDivider() }
                    HunterRow(hunter: h)
                }
            }
        }
    }
}

private struct HunterRow: View {
    let hunter: FoxReferee.Hunter

    var body: some View {
        HStack(spacing: 12) {
            if let f = hunter.found {
                Text("#\(f.place)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.ok)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ok.opacity(0.3), lineWidth: 1))
            } else {
                IconTile(symbol: trendSymbol, tint: trendColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(hunter.name).font(Theme.Fonts.heading).foregroundStyle(hunter.left ? Theme.textTertiary : Theme.textPrimary)
                Text(detail).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let raw { Text(raw).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if let s = hunter.best?.score {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Int(s))").font(Theme.Fonts.data).foregroundStyle(Theme.textPrimary)
                    SegmentMeter(value: s / 100, tint: Theme.textPrimary, size: .xs)
                }
                .accessibilityLabel("Best score \(Int(s)) of 100")
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .opacity(hunter.left ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }

    private var trendSymbol: String {
        switch hunter.trend {
        case "HOT": return "flame"
        case "WARMER": return "arrow.up.right"
        case "COLDER": return "arrow.down.right"
        case "STEADY": return "arrow.right"
        default: return "ellipsis"
        }
    }

    private var trendColor: Color? {
        switch hunter.trend {
        case "HOT", "WARMER": return Theme.ok
        case "COLDER": return Theme.alert
        default: return nil
        }
    }

    /// The plain line: what they're doing.
    private var detail: String {
        if let f = hunter.found { return "Found it · +\(f.points) points · \(f.clock)" }
        if hunter.left { return "Left the hunt" }
        guard hunter.last != nil else { return "Joined, no readings yet" }
        return "\(hunter.trend.capitalized)" + (hunter.bearing.map { " · heading \(FoxReadout.direction($0.degrees))" } ?? "")
    }

    /// The raw line under it: proofs, last reading, bearing and spread.
    private var raw: String? {
        if let f = hunter.found { return f.proofs.map(\.rawValue).joined(separator: " + ") }
        guard let last = hunter.last else { return nil }
        let sig = last.rssi.map { "\(FoxReadout.format($0, unit: .rssi)) dBm" }
            ?? last.snr.map { "SNR \(FoxReadout.format($0, unit: .snr))" } ?? "?"
        let brg = hunter.bearing.map { " · brg \(FoxReadout.degrees($0.degrees)) ±\(Int($0.spread.rounded()))°" } ?? ""
        return "last \(sig)\(brg)"
    }
}
