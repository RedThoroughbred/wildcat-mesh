import SwiftUI
import WildcatRadioCore

/// Hunt, set up (Small Play 2, "Hunt · set up"): the pieces to hide, rounds, time limit,
/// how a find counts, then the invite and the hide walk. A hunter joins from here too, by
/// scanning the hider's QR code.
struct HuntSetupView: View {
    @Environment(GamePlay.self) private var play
    @Environment(Radio.self) private var radio
    @Environment(PhoneReferee.self) private var referee
    @Environment(InviteHandler.self) private var invites
    @AppStorage(PlayView.playersKey) private var players = 2
    @State private var picked: [NodeNum] = []
    @State private var rounds = 2
    @State private var minutes = 20
    @State private var mode: FoxReferee.Mode = .either
    @State private var scanning = false

    static let limitChoices = [10, 20, 30]

    private var count: Int { picked.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let e = play.error { ToastBanner(text: e, kind: .danger) }
                steps
                if !radio.isReady {
                    NeedsRadioNotice(.meshtastic, why: "Your node hears the pieces as you hide them and referees the hunt. Hunting with no node? Scan the hider's QR code below.",
                                     practice: {})
                        .padding(.top, 6)
                } else if play.huntChannel == nil {
                    Notice(text: "Your node needs the WGHUNT channel: hunters talk to you on it. Add it in Node settings (or make a fox first; it creates one).")
                } else if referee.isHosting {
                    Notice(text: "You're hosting a Fox Hunt (\(referee.board?.hunt.code ?? "")). End it first: one hunt at a time on your node.")
                }
                pieces
                settings
                playersCard
                scanRow
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, 90)
        }
        .scrollDismissesKeyboard(.immediately)
        .screen()
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GameNavTitle(title: "Hunt", subtitle: "\(players >= 3 ? "3 or more" : "2") players · you hide first")
            }
            ToolbarItem(placement: .topBarTrailing) { GuideButton(chapter: "foxhunt") }
        }
        .sheet(isPresented: $scanning) {
            QRScanner(accept: { HuntGame.Invite(link: $0) != nil || HuntInvite(link: $0) != nil }) { code in
                if invites.open(code) { scanning = false }
            }
            .ignoresSafeArea()
        }
        // Nothing picked on a real mesh (the nodes heard may be anyone's); practice picks its two boxes.
        .onAppear {
            if picked.isEmpty, radio.source == .practice { picked = [PracticeMesh.loot, PracticeMesh.gem] }
        }
    }

    // MARK: Parts

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "You hide the pieces. \(players >= 3 ? "Your friends" : "Your friend") can't see where.")
            step(2, "They follow warmer and colder until they're right on one.")
            step(3, rounds == 1 ? "One round: beat the clock." : "Swap roles. Fastest total time wins.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.inset)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.meshtastic)
            Text(text).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var pieces: some View {
        SectionLabel("Pieces to hide", detail: "\(count) of up to \(HuntGame.maxPieces)")
            .padding(.top, 10)
        let nodes = Array(play.candidates.prefix(8))
        if nodes.isEmpty {
            Notice(text: "Your node hasn't heard any other nodes yet. Switch the pieces on near it: any small Meshtastic node on a battery works.")
        } else {
            FieldGroup {
                ForEach(Array(nodes.enumerated()), id: \.element.num) { i, n in
                    if i > 0 { FieldDivider() }
                    pieceRow(n)
                }
            }
        }
    }

    private func pieceRow(_ n: NodeInfo) -> some View {
        let on = picked.contains(n.num)
        let number = picked.firstIndex(of: n.num).map { $0 + 1 }
        return Button {
            Haptics.selection()
            if on { picked.removeAll { $0 == n.num } } else if count < HuntGame.maxPieces { picked.append(n.num) }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? Theme.meshtastic : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? Theme.meshtastic : Theme.textQuaternary, lineWidth: 1.5))
                    .overlay { if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onAccent) } }
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.shortName ?? n.num.short).font(.system(.subheadline, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(meta(n)).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let number { PieceTag(index: number) }
            }
            .padding(.horizontal, Theme.Space.rowH)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .disabled(!on && count >= HuntGame.maxPieces)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func meta(_ n: NodeInfo) -> String {
        var parts: [String] = []
        if let b = n.metrics?.batteryLevel, b > 0 { parts.append(b > 100 ? "plugged in" : "battery \(b)%") }
        if let h = n.lastHeard { parts.append("heard \(FoxReadout.ago(Date().timeIntervalSince(h)))") }
        return parts.isEmpty ? (n.longName ?? n.num.id) : parts.joined(separator: " · ")
    }

    @ViewBuilder private var settings: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Rounds")
                FieldSegmented(options: [(1, "1"), (2, "2"), (3, "3")], selection: $rounds)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Time limit")
                FieldSegmented(options: Self.limitChoices.map { ($0, "\($0)") }, selection: $minutes)
            }
        }
        .padding(.top, 10)
        Text(rounds == 1 ? "One round of \(minutes) minutes: beat the clock."
                         : "\(rounds) rounds, \(minutes) min each. You swap who hides every round.")
            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
        SectionLabel("How a find counts")
            .padding(.top, 10)
        FieldSegmented(options: [(FoxReferee.Mode.either, "Signal or code"), (.code, "Code"), (.signal, "Signal")], selection: $mode)
        Text(modeHelp).font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    private var modeHelp: String {
        switch mode {
        case .either: return "Standing right by a piece counts, or the code on its label."
        case .code: return "Only the 4-digit code on the piece's label counts."
        case .signal: return "Standing right by a piece counts. Good for kids."
        }
    }

    @ViewBuilder private var playersCard: some View {
        SectionLabel("Players")
            .padding(.top, 10)
        FieldGroup {
            HStack(spacing: 10) {
                StatusLED(color: Theme.ok, on: radio.isReady, size: 8)
                Text("You").font(Theme.Fonts.body).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(radio.isReady ? "hiding · your node" : "hiding · connect your node")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Space.rowH)
            .frame(minHeight: 44)
            FieldDivider()
            HStack(spacing: 10) {
                StatusLED(color: Theme.ok, on: false, size: 8)
                Text(players >= 3 ? "Friends" : "Your friend").font(Theme.Fonts.body).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("hunting · scans your QR").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Space.rowH)
            .frame(minHeight: 44)
        }
        Text("A friend with no node can still hunt: their warmer/colder comes from GPS and is marked \"guide\".")
            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    private var scanRow: some View {
        Button { scanning = true } label: {
            FieldRow(symbol: "qrcode.viewfinder", title: "Hunting, not hiding?", subtitle: "Scan the hider's QR code to join their hunt")
                .panel(.inset)
        }
        .buttonStyle(.rowPress)
        .padding(.top, 10)
    }

    private var canHost: Bool { radio.isReady && play.huntChannel != nil && count > 0 && !referee.isHosting }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                if play.game != nil || create() { play.inviteShown = true }
            } label: {
                Image(systemName: "qrcode").font(.system(size: 20))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(Theme.meshtastic)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.amberDeep, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canHost)
            .opacity(canHost ? 1 : 0.5)
            .accessibilityLabel("Invite with QR")
            Button { _ = create() } label: {
                Text(count == 1 ? "Hide 1 piece" : "Hide \(count) pieces")
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(canHost ? Theme.onAccent : Theme.textTertiary)
                    .background(canHost ? Theme.meshtastic : Theme.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canHost)
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, 10)
        .background(Theme.bg.opacity(0.94))
    }

    /// Opens the game: the hide walk takes over this screen.
    private func create() -> Bool {
        play.host(pieces: picked, rounds: rounds, limitMinutes: minutes, mode: mode)
    }
}
