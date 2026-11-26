import MapKit
import SwiftUI
import WildcatRadioCore

// Pieces shared by the Hunt game's screens (Small Play 2): the title, the clock pill, the
// piece tag, the claim meter, the invite QR, the maps and the placeholder for later games.

/// "Hunt · round 1" over "2 pieces hidden · you hunt" for the navigation bar.
struct GameNavTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The round's countdown (or elapsed time without a limit) in an amber pill, ticking every second.
struct GameClockPill: View {
    @Environment(GamePlay.self) private var play

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let t = ctx.date.timeIntervalSince1970
            let text: String = {
                if let left = play.game?.timeRemaining(at: t) { return FoxReadout.clock(left.rounded(.up)) }
                if let start = play.round?.startedAt { return FoxReadout.clock(t - start) }
                return "--:--"
            }()
            let low = (play.game?.timeRemaining(at: t) ?? 999) <= 60 && play.round?.stage == .live
            Text(text)
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(low ? Theme.alert : Theme.amberBright)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(low ? Theme.alert.opacity(0.5) : Theme.amberDeep, lineWidth: 1))
                .accessibilityLabel(play.settingsHaveLimit ? "Time left \(text)" : "Elapsed \(text)")
        }
    }
}

extension GamePlay {
    var settingsHaveLimit: Bool { game?.settings.timeLimit != nil }
}

/// "PIECE 2": a piece's number tag, in Meshtastic amber (pieces are Meshtastic nodes).
struct PieceTag: View {
    let index: Int
    var found = false

    var body: some View {
        Text(found ? "FOUND" : "PIECE \(index)")
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(found ? Theme.ok : Theme.amberBright)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((found ? Theme.ok : Theme.meshtastic).opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The 20-step meter of the hunter's board: amber up to the claim zone, green inside it,
/// "FAR … CLAIM ZONE ▸" under it.
struct ClaimMeter: View {
    /// 0...1; `zone` and above is the claim zone.
    let value: Double
    var zone: Double = 0.8
    var segments = 20

    var body: some View {
        let lit = SegmentMeter.litCount(value: value, segments: segments)
        let zoneFrom = Int((zone * Double(segments)).rounded())
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i < lit ? (i >= zoneFrom ? Theme.ok : Theme.meshtastic) : Theme.segmentOff)
                        .frame(height: 20)
                }
            }
            HStack {
                Text("FAR")
                Spacer()
                Text("CLAIM ZONE ▸")
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.textQuaternary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value >= zone ? "In the claim zone" : "\(Int((value / max(zone, 0.01) * 100).rounded())) percent of the way to the claim zone")
    }

    /// Where a reading sits: −120 dBm is nothing, the claim line is `zone`; SNR from −20 dB.
    static func fraction(rssi: Double?, snr: Double?, claimRSSI: Double, claimSNR: Double, zone: Double = 0.8) -> Double {
        if let rssi, rssi.isFinite { return max(0, min(1, (rssi + 120) / max(1, claimRSSI + 120) * zone)) }
        if let snr, snr.isFinite { return max(0, min(1, (snr + 20) / max(1, claimSNR + 20) * zone)) }
        return 0
    }
}

/// "The hunt is on: this QR joins it." The hider's invite, for hunters to scan.
struct GameQRSheet: View {
    @Environment(GamePlay.self) private var play
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let invite = play.invite {
                        CardLabel("Hunters scan this")
                        QRImage(text: invite.link)
                        Text("With the iPhone Camera or Wildcat. It adds \(invite.channelName) to their node and joins all \(invite.pieces.count) pieces of \(invite.code). No node? They get the GPS guide.")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        if !invite.isHidden {
                            Notice(text: "Hunters without a node: scan again once every piece is hidden, so the guide knows where to point.",
                                   symbol: "location")
                        }
                        ShareLink(item: invite.link) { Label("Share invite link", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.field(.secondary, .regular))
                    } else {
                        Notice(text: "Connect your node to show the invite: it carries your WGHUNT channel.")
                    }
                }
                .padding(Theme.Space.edge)
                .frame(maxWidth: .infinity)
            }
            .screen()
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
    }
}

/// "Join MAYA's hunt?" after scanning a hider's QR code or opening their link.
struct GameInviteSheet: View {
    let invite: HuntGame.Invite
    var onJoined: () -> Void
    @Environment(InviteHandler.self) private var invites
    @Environment(Radio.self) private var radio
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            HStack(spacing: 12) {
                IconTile(symbol: "scope", tint: Theme.meshtastic, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        CardLabel("Hunt invite")
                        NetworkTag(.meshtastic)
                    }
                    Text(invite.code).font(.system(.largeTitle, design: .monospaced, weight: .light)).foregroundStyle(Theme.textPrimary)
                }
            }
            MetaLine("Round \(invite.round) of \(invite.rounds), hidden by \(invite.hider.isEmpty ? "your friend" : invite.hider). \(invite.pieces.count) piece\(invite.pieces.count == 1 ? "" : "s") to find" + (invite.limit.map { " in \($0) minutes." } ?? "."),
                     raw: invite.pieces.map(\.name).joined(separator: " · "))
            if let plan = invites.gamePlan { Notice(text: plan) }
            switch invites.step {
            case .working(let s): ProgressView(s).tint(Theme.textSecondary)
            case .failed(let s): ToastBanner(text: s, kind: .danger)
            default: EmptyView()
            }
            Spacer()
            Button {
                Task {
                    await invites.acceptGame()
                    if invites.step == .joined {
                        onJoined()
                        dismiss()
                    }
                }
            } label: {
                Label(radio.isReady ? "Join the hunt" : "Hunt with the GPS guide", systemImage: "flag.checkered").frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
            .disabled({ if case .working = invites.step { return true } else { return false } }())
            Button("Not now") { invites.pendingGame = nil }
                .buttonStyle(.field(.quiet, .regular))
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Space.edge)
        .screen()
        .presentationDetents([.medium, .large])
    }
}

/// A small dark map: a trail (the hunter's walk) and/or pins (the hider's spots, for pick-up).
struct GameMap: View {
    var trail: [Coordinate] = []
    var pins: [(label: String, at: Coordinate)] = []

    private var region: MapCameraPosition {
        let all = trail + pins.map(\.at)
        guard let first = all.first else { return .automatic }
        let lats = all.map(\.latitude), lons = all.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: ((lats.min() ?? first.latitude) + (lats.max() ?? first.latitude)) / 2,
                                            longitude: ((lons.min() ?? first.longitude) + (lons.max() ?? first.longitude)) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.0015, ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.6),
                                    longitudeDelta: max(0.0015, ((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.6))
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    var body: some View {
        Map(initialPosition: region, interactionModes: [.pan, .zoom]) {
            if trail.count > 1 {
                MapPolyline(coordinates: trail.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(Theme.meshtastic, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [6, 5]))
            }
            if let start = trail.first {
                Annotation("Start", coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)) {
                    MapDot(color: Theme.textPrimary, size: 11)
                }
            }
            ForEach(Array(pins.enumerated()), id: \.offset) { _, pin in
                Annotation(pin.label, coordinate: CLLocationCoordinate2D(latitude: pin.at.latitude, longitude: pin.at.longitude)) {
                    MapDot(color: Theme.ok, size: 13)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// A game card on Play: an amber glyph, the game's name as a mono kicker, one line about it,
/// and what it needs as chips ("15–30 min", "1–3 pieces", "phones OK").
struct GameCard: View {
    let symbol: String
    let kicker: String
    let pitch: String
    let chips: [String]
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.meshtastic)
                .frame(width: 48, height: 48)
                .background(Theme.meshtastic.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.amberDeep, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(kicker)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.meshtastic)
                    if let detail {
                        Spacer(minLength: 6)
                        Text(detail).font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Text(pitch)
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                ChipFlow(chips: chips)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
            Chevron().padding(.top, 16)
        }
        .padding(14)
        .background(Color(hex: 0x14120d), in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).strokeBorder(Color(hex: 0x3a2a06), lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Small grey mono chips that wrap.
struct ChipFlow: View {
    let chips: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { c in
                Text(c)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }
}

/// Lays children left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A game that comes in a later update (Prowl, Trails): what it will be, and nothing to break.
struct ComingSoonView: View {
    let title: String
    let symbol: String
    let text: String

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Emblem(symbol: symbol, tint: Theme.meshtastic, size: 72)
                    .padding(.top, 30)
                Text(title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                Text(text)
                    .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Tag("COMING IN AN UPDATE", color: Theme.meshtastic)
            }
            .padding(Theme.Space.edge)
            .frame(maxWidth: .infinity)
        }
        .screen()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
