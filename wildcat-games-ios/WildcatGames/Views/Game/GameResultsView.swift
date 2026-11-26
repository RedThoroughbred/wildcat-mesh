import SwiftUI
import WildcatRadioCore

/// Round over (Small Play 2, "Round over"): the round's time, each piece's time and proof, the
/// trail (hunter) or the spots to pick up (hider), then swap who hides, or end the game. After
/// the last round: the standings, as this phone saw them.
struct GameResultsView: View {
    @Environment(GamePlay.self) private var play
    @State private var confirmEnd = false

    private var game: HuntGame? { play.game }
    private var round: HuntGame.Round? { play.round }
    private var total: Int { game?.pieces.count ?? 0 }
    private var isHider: Bool { round?.role == .hider }

    /// The result the hero shows: mine when I hunted, else the round's best hunter.
    private var featured: HuntGame.Result? {
        guard let round, let game else { return nil }
        if !isHider { return round.results.first { $0.isMe } ?? HuntGame.Result(name: game.me, isMe: true) }
        let best = game.suggestedHider(after: round)
        return round.results.first { $0.name == best }
    }

    private func time(_ r: HuntGame.Result) -> TimeInterval {
        guard let game, let round else { return 0 }
        return game.roundTime(r, in: round)
    }

    private func clock(_ r: HuntGame.Result) -> String {
        (r.finds.contains(where: \.approximate) ? "≈" : "") + FoxReadout.clock(time(r))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                if let r = featured, !r.finds.isEmpty { pieceRows(r) }
                if let round, round.results.count > 1 { everyone(round) }
                map
                if let note { Text(note).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                if game?.isOver == true || (game?.rounds.count ?? 0) > 1 { standings }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, 150)
        }
        .screen()
        .safeAreaInset(edge: .bottom) { actions }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GameNavTitle(title: game?.isOver == true ? "Game over" : "Round \(round?.number ?? 1) over",
                             subtitle: "\(game?.code ?? "") · round \(round?.number ?? 1) of \(game?.settings.rounds ?? 1)")
            }
        }
        .confirmationDialog("End the game?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End the game", role: .destructive) { play.endGame() }
        } message: {
            Text("The rounds so far are forgotten on this phone.")
        }
    }

    // MARK: Parts

    @ViewBuilder private var hero: some View {
        let r = featured
        let found = r?.finds.count ?? 0
        let who = r.map { $0.isMe ? "YOU" : $0.name } ?? "NOBODY"
        VStack(spacing: 6) {
            Text(r == nil ? "NOBODY HUNTED" : found == total ? "\(who) FOUND \(found) OF \(total) IN" : "\(who) FOUND \(found) OF \(total)")
                .font(.system(.caption, design: .monospaced)).tracking(1.6).foregroundStyle(Theme.meshtastic)
            Text(r.map(clock) ?? "--:--")
                .font(.system(size: 60, weight: .light, design: .monospaced)).tracking(-2)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let line = heroLine(r) {
                Text(line).font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color(hex: 0x14120d), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.amberDeep, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func heroLine(_ r: HuntGame.Result?) -> String? {
        guard let game, let round else { return nil }
        if game.isOver {
            guard let first = game.standings.first else { return "Nobody hunted." }
            return first.isMe ? "You win the game!" : "\(first.name) wins the game."
        }
        guard let next = game.nextRoundNumber, let r else { return round.endReason == .time ? "Time ran out." : nil }
        let beat = FoxReadout.clock(time(r))
        if isHider { return "Now \(r.name) hides round \(next). You have to beat \(beat)." }
        if game.shouldHideNext {
            let other = round.hider.isEmpty ? "Your friend" : round.hider
            return "Now you hide. \(other) has to beat \(beat)."
        }
        return round.endReason == .time ? "Time ran out." : "Round \(next) is next."
    }

    private func pieceRows(_ r: HuntGame.Result) -> some View {
        FieldGroup {
            ForEach(Array((game?.pieces ?? []).enumerated()), id: \.element.index) { i, p in
                if i > 0 { FieldDivider() }
                let f = r.finds.first { $0.piece == p.index }
                HStack(spacing: 10) {
                    PieceTag(index: p.index, found: f != nil)
                    Text(p.name).font(.system(.subheadline, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(f.map { GameBoardView.proofWords($0.proofs) } ?? "not found").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    Text(f.map { ($0.approximate ? "≈" : "") + FoxReadout.clock($0.elapsed) } ?? "--")
                        .font(.system(.subheadline, design: .monospaced)).foregroundStyle(f == nil ? Theme.textTertiary : Theme.textPrimary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .padding(.horizontal, Theme.Space.rowH)
                .frame(minHeight: 52)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func everyone(_ round: HuntGame.Round) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Everyone this round")
            FieldGroup {
                ForEach(Array(round.results.enumerated()), id: \.offset) { i, r in
                    if i > 0 { FieldDivider() }
                    HStack {
                        Text(r.isMe ? "You" : r.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(r.finds.count) of \(total)").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        Text(clock(r)).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    .padding(.horizontal, Theme.Space.rowH)
                    .frame(minHeight: 46)
                }
            }
        }
    }

    @ViewBuilder private var map: some View {
        if isHider {
            let pins = (game?.pieces ?? []).compactMap { p in round?.hidden(p.index)?.spot.map { (label: p.name, at: $0) } }
            if !pins.isEmpty {
                ZStack(alignment: .topLeading) {
                    GameMap(pins: pins).frame(height: 196)
                    mapLabel("YOUR SPOTS · FOR PICK-UP")
                }
            }
        } else if play.trail.count > 1 {
            ZStack(alignment: .topLeading) {
                GameMap(trail: play.trail).frame(height: 196)
                mapLabel("YOUR TRAIL · \(play.walked < 1000 ? "\(Int(play.walked)) M" : String(format: "%.1f KM", play.walked / 1000))")
            }
        }
    }

    private func mapLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced)).tracking(1.4)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.bg.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(10)
            .allowsHitTesting(false)
    }

    private var note: String? {
        guard let game, let next = game.nextRoundNumber else { return nil }
        if game.shouldHideNext { return "You found them, so pick them up: they are yours to hide in round \(next)." }
        if isHider { return "Your spots are on the map, in case anything is left to pick up." }
        return nil
    }

    @ViewBuilder private var standings: some View {
        let s = game?.standings ?? []
        if !s.isEmpty {
            SectionLabel(game?.isOver == true ? "Final standings" : "So far").padding(.top, 6)
            FieldGroup {
                ForEach(Array(s.enumerated()), id: \.offset) { i, st in
                    if i > 0 { FieldDivider() }
                    HStack(spacing: 12) {
                        Text("#\(i + 1)").font(.system(.callout, design: .monospaced)).foregroundStyle(i == 0 ? Theme.ok : Theme.textTertiary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(st.isMe ? "You" : st.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                            Text("\(st.found) of \(st.possible) found · \(st.roundsHunted) round\(st.roundsHunted == 1 ? "" : "s")")
                                .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text((st.approximate ? "≈" : "") + FoxReadout.clock(st.time))
                            .font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, Theme.Space.rowH)
                    .padding(.vertical, Theme.Space.rowV)
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Times as this phone saw them: the hider's phone timed its round, yours timed your own from the GO, within a few seconds.")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let next = game?.nextRoundNumber {
                let hide = game?.shouldHideNext == true
                Button {
                    Haptics.success()
                    play.nextRound(iHide: hide)
                } label: {
                    Text(hide ? "Swap · you hide round \(next)" : "Hunt round \(next)")
                        .font(.system(.body, design: .monospaced, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.meshtastic, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                Button(hide ? "Someone else hides round \(next)" : "I'll hide round \(next)") { play.nextRound(iHide: !hide) }
                    .buttonStyle(.field(.quiet, .regular))
                Button("End the game") { confirmEnd = true }
                    .buttonStyle(.field(.secondary, .large))
            } else {
                Button { play.endGame() } label: {
                    Text("Done").font(.system(.body, design: .monospaced, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.meshtastic, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, 10)
        .background(Theme.bg.opacity(0.94))
    }
}
