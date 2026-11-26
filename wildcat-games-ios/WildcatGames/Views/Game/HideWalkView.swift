import SwiftUI
import WildcatRadioCore

/// Hide the pieces (Small Play 2, "Hide the pieces"): one piece at a time, walk, set it
/// down, tap Hidden here beside it. That records the spot (for picking it up, and the
/// hunters' GPS guide) and this phone's node's reading right beside it, which sets the
/// piece's claim line. The round starts only when every piece is hidden.
struct HideWalkView: View {
    @Environment(GamePlay.self) private var play
    @Environment(Radio.self) private var radio
    @State private var hiding: Int?
    @State private var again: Int?
    @State private var typed: [Int: String] = [:]
    @State private var badCode: Int?
    @State private var confirmCancel = false

    private var game: HuntGame? { play.game }
    private var round: HuntGame.Round? { play.round }
    private var total: Int { game?.pieces.count ?? 0 }
    private var done: Int { game?.hiddenCount ?? 0 }

    /// The piece being hidden now: the one picked to hide again, else the first not yet hidden.
    private var current: HuntGame.Piece? {
        if let again, let p = play.piece(again) { return p }
        return game?.pieces.first { round?.hidden($0.index) == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = play.error { ToastBanner(text: e, kind: .danger) }
                if play.resumed { Notice(text: "Picked up where you were when the app closed.", symbol: "arrow.clockwise") }
                if !radio.isReady {
                    NeedsRadioNotice(.meshtastic, why: "Your node hears each piece as you hide it, and referees the round for the hunters.")
                }
                progress
                ForEach(game?.pieces ?? [], id: \.index) { p in
                    if let h = round?.hidden(p.index), current?.index != p.index { hiddenCard(p, h) }
                }
                if let p = current { hideCard(p) }
                joinedLine
                // iOS asks when this screen opens (onAppear), so nothing shows before the answer.
                // After a no: what the game goes without, and no pointer to Settings for a
                // choice made in this run (App Review guideline 5.1.1(iv)).
                LocationNotice(access: LocationAccess(play.location.authorization),
                               without: "the spots aren't remembered and hunters with no node get no guide. The game still works.")
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.textTertiary)
                    Text("Stay inside the play area, off private property, and somewhere you'll find again. The app remembers each spot for pick-up.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, 90)
        }
        .scrollDismissesKeyboard(.immediately)
        .screen()
        .safeAreaInset(edge: .bottom) { startBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GameNavTitle(title: "Hide the pieces", subtitle: "Round \(round?.number ?? 1) · only you see this")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { play.inviteShown = true } label: { Image(systemName: "qrcode") }
                    .accessibilityLabel("Invite hunters")
                Menu {
                    Button("Cancel the game", role: .destructive) { confirmCancel = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Cancel the game for everyone?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel the game", role: .destructive) { play.endGame() }
        }
        .onAppear { play.location.begin(asking: true) }
        .onDisappear { play.location.end() }
    }

    // MARK: Parts

    private var progress: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.segmentOff)
                    Capsule().fill(Theme.meshtastic).frame(width: geo.size.width * CGFloat(done) / CGFloat(max(1, total)))
                }
            }
            .frame(height: 6)
            Text("\(done) of \(total) hidden")
                .font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func hiddenCard(_ p: HuntGame.Piece, _ h: HuntGame.Hidden) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.name).font(.system(.subheadline, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                PieceTag(index: p.index)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(FoxReadout.ago(ctx.date.timeIntervalSince1970 - h.t)).font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                }
            }
            Text(Self.hiddenLine(h)).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if round?.stage == .hiding {
                Button("Hide it again") { again = p.index }
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.meshtastic)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// "Hidden. Heard at −41 dBm right beside it, so a claim needs about −55 or stronger: within a few steps."
    static func hiddenLine(_ h: HuntGame.Hidden) -> String {
        let c = h.calibration
        let spot = h.spot == nil ? " No GPS fix: the spot isn't saved." : ""
        if let rssi = c.reading?.rssi {
            let at = FoxReadout.format(rssi, unit: .rssi)
            let line = FoxReadout.format(c.claimRSSI, unit: .rssi)
            if c.isWeak {
                return "Hidden. Your node heard it only at \(at) dBm right beside it: is it switched on? A claim needs \(line) or stronger." + spot
            }
            return "Hidden. Heard at \(at) dBm right beside it, so a claim needs about \(line) or stronger: within a few steps." + spot
        }
        if let snr = c.reading?.snr {
            return "Hidden. Heard at SNR \(FoxReadout.format(snr, unit: .snr)) dB beside it, so a claim needs SNR \(FoxReadout.format(c.claimSNR, unit: .snr)) or better." + spot
        }
        return "Hidden, but your node didn't hear it: a claim needs the usual \(FoxReadout.format(c.claimRSSI, unit: .rssi)) dBm. Check it's switched on." + spot
    }

    @ViewBuilder private func hideCard(_ p: HuntGame.Piece) -> some View {
        let reading = play.reading(p.index)
        let node = radio.session.nodes[p.node]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(p.name).font(.system(.title3, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                PieceTag(index: p.index)
                Spacer()
                HStack(spacing: 6) {
                    StatusLED(color: Theme.ok, on: reading != nil, size: 7)
                    Text(reading != nil ? "beeping" : "not heard yet").font(Theme.Fonts.footnote)
                        .foregroundStyle(reading != nil ? Theme.ok : Theme.textTertiary)
                }
            }
            Text(LocalizedStringKey(p.code == nil
                 ? "Type the code on \(p.name)'s label, walk to a hiding spot, set it down, then tap **Hidden here** while you stand next to it."
                 : "Walk to a hiding spot, set \(p.name) down, then tap **Hidden here** while you stand next to it."))
                .font(Theme.Fonts.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                cell("Signal", reading.flatMap { $0.rssi.map { FoxReadout.format(Double($0), unit: .rssi) } ?? $0.snr.map { "S" + FoxReadout.format($0, unit: .snr) } } ?? "--")
                cell("Battery", node?.metrics?.batteryLevel.map { $0 > 100 ? "USB" : "\($0)%" } ?? "--")
                cell("Label code", p.code ?? "????")
            }
            if p.code == nil { codeEntry(p) }
            Button {
                hiding = p.index
                Task {
                    await play.hide(piece: p.index)
                    hiding = nil
                    again = nil
                    Haptics.success()
                }
            } label: {
                HStack(spacing: 8) {
                    if hiding == p.index { ProgressView().tint(Theme.onAccent) }
                    Text(hiding == p.index ? "Saving the spot…" : "Hidden here")
                }
                .font(.system(.body, design: .monospaced, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.meshtastic.opacity(p.code == nil ? 0.35 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(p.code == nil || hiding != nil)
            if reading == nil {
                Text("Your node hasn't heard \(p.name) in the last two minutes. Hidden here still works, with the usual claim line.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(hex: 0x14120d), in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).strokeBorder(Theme.amberDeep, lineWidth: 1))
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, design: .monospaced)).tracking(1.2).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(.title3, design: .monospaced)).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// A swapped-in hider types the code on the label (checked against the game).
    private func codeEntry(_ p: HuntGame.Piece) -> some View {
        let binding = Binding(get: { typed[p.index] ?? "" }, set: { v in
            let digits = String(v.filter(\.isNumber).prefix(4))
            typed[p.index] = digits
            badCode = nil
            if digits.count == 4, !play.learnCode(piece: p.index, code: digits) { badCode = p.index }
        })
        return VStack(alignment: .leading, spacing: 6) {
            CardLabel("Code on its label")
            TextField("0000", text: binding)
                .font(.system(.title2, design: .monospaced))
                .tracking(6)
                .keyboardType(.numberPad)
                .fieldInput()
            if badCode == p.index {
                Text("That's not \(p.name)'s code. Check the label.").font(Theme.Fonts.footnote).foregroundStyle(Theme.alert)
            }
        }
    }

    @ViewBuilder private var joinedLine: some View {
        let names = Array(Set(round?.referees.flatMap { $0.hunters.values.filter { !$0.left }.map(\.name) } ?? [])).sorted()
        HStack(spacing: 8) {
            StatusLED(color: Theme.ok, on: !names.isEmpty, size: 6)
            Text(names.isEmpty ? "No hunters yet: they scan your QR code (top right)." : "Joined: " + names.joined(separator: ", "))
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
        }
    }

    private var startBar: some View {
        let ready = game?.canStart == true && again == nil
        let limit = game?.settings.timeLimit.map { " · " + FoxReadout.clock($0) } ?? ""
        return Button {
            Haptics.success()
            play.start()
        } label: {
            Text(ready ? "Start round \(round?.number ?? 1)\(limit)" : "Hide every piece to start")
                .font(.system(.body, design: .monospaced, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(ready ? Theme.onAccent : Theme.textTertiary)
                .background(ready ? Theme.meshtastic : Theme.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ready ? Theme.meshtastic : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, 10)
        .background(Theme.bg.opacity(0.94))
    }
}
