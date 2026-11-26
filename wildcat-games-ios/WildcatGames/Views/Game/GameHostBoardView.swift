import SwiftUI
import WildcatRadioCore

/// The hider's view of a live round (Small Play 2): the clock, each piece with who found it
/// and when, the hunters, the invite for anyone late, and End round. This phone's node
/// referees every piece meanwhile, so keep the app open nearby.
struct GameHostBoardView: View {
    @Environment(GamePlay.self) private var play
    @Environment(Radio.self) private var radio
    @State private var confirmEnd = false

    private var game: HuntGame? { play.game }
    private var round: HuntGame.Round? { play.round }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = play.error { ToastBanner(text: e, kind: .danger) }
                if play.resumed { Notice(text: "Picked up where your round was when the app closed.", symbol: "arrow.clockwise") }
                if !radio.isReady {
                    Notice(text: "Your node is disconnected: hunters get no answers until it's back.", color: Theme.alert)
                }
                Text("Your node referees every piece while the round runs. Keep the app open and your node near you.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                SectionLabel("Pieces")
                FieldGroup {
                    ForEach(Array((game?.pieces ?? []).enumerated()), id: \.element.index) { i, p in
                        if i > 0 { FieldDivider() }
                        pieceRow(p, referee: i < (round?.referees.count ?? 0) ? round?.referees[i] : nil)
                    }
                }
                SectionLabel("Hunters", detail: "\(round?.results.count ?? 0)").padding(.top, 6)
                if let results = round?.results, !results.isEmpty {
                    FieldGroup {
                        ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                            if i > 0 { FieldDivider() }
                            hunterRow(r)
                        }
                    }
                } else {
                    Text("Nobody has joined yet. Hunters scan your QR code.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                }
                Button { play.inviteShown = true } label: {
                    FieldRow(symbol: "qrcode", title: "Invite", subtitle: "For a late hunter, or one with no node (the GPS guide)")
                        .panel(.inset)
                }
                .buttonStyle(.rowPress)
                .padding(.top, 6)
                Button("End round \(round?.number ?? 1)", role: .destructive) { confirmEnd = true }
                    .buttonStyle(.field(.destructive, .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GameNavTitle(title: "Hunt · round \(round?.number ?? 1)", subtitle: "you hid \(game?.pieces.count ?? 0) · they hunt")
            }
            ToolbarItem(placement: .topBarTrailing) { GameClockPill() }
        }
        .confirmationDialog("End round \(round?.number ?? 1) for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End the round", role: .destructive) { play.endRound() }
        }
    }

    private func pieceRow(_ p: HuntGame.Piece, referee: FoxReferee?) -> some View {
        let finders = referee?.board?.hunters.filter { $0.found != nil } ?? []
        let seen = referee?.hunt?.foxSeen
        return HStack(spacing: 12) {
            PieceTag(index: p.index, found: !finders.isEmpty)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(.subheadline, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(finders.isEmpty ? "not found yet"
                     : finders.map { "\($0.name) \(FoxReadout.clock($0.found?.elapsed ?? 0))" }.joined(separator: " · "))
                    .font(Theme.Fonts.footnote).foregroundStyle(finders.isEmpty ? Theme.textSecondary : Theme.ok)
                if let c = round?.hidden(p.index)?.calibration {
                    Text("claim line \(FoxReadout.format(c.claimRSSI, unit: .rssi)) dBm").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            HeardAgo(time: seen.map { Date(timeIntervalSince1970: $0) })
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .accessibilityElement(children: .combine)
    }

    private func hunterRow(_ r: HuntGame.Result) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: r.finds.count == (game?.pieces.count ?? 0) ? "checkmark" : "figure.walk",
                     tint: r.finds.isEmpty ? nil : Theme.ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                Text("found \(r.finds.count) of \(game?.pieces.count ?? 0)").font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .accessibilityElement(children: .combine)
    }
}
