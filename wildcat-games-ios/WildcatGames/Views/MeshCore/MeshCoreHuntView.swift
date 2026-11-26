import SwiftUI
import WildcatRadioCore

/// Pick a repeater and hunt it down by its signal, with the radar scope.
struct MeshCoreHuntView: View {
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshCoreHunt.self) private var hunt
    @Environment(ExploreModel.self) private var explore
    @Environment(PacketFeed.self) private var feed

    private var foxes: [MeshCore.Contact] {
        link.session.contacts.values.filter { MeshCoreFormat.isInfrastructure($0.kind) }
            .sorted { ($0.lastAdvert ?? .distantPast) > ($1.lastAdvert ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                if let fox = hunt.target {
                    hunting(fox)
                } else {
                    picker
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("MeshCore fox hunt")
        .onAppear { explore.begin() }
        .onDisappear { explore.end() }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            Text("Pick a repeater and find it by its signal alone. Every packet it transmits (its adverts, the traffic it relays, and answers to your pings) moves the scope.")
                .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ModuleHeader(1, "Pick a fox", detail: "\(foxes.count)")
            if !link.state.isReady {
                NeedsRadioNotice(.meshcore, why: "Your node hears the repeater's adverts and relayed traffic.")
            } else if foxes.isEmpty {
                EmptyState(symbol: MeshCoreFormat.symbol(.repeater), title: "No repeaters heard yet",
                           text: "Wait for their adverts, or send yours so they answer.",
                           actionTitle: "Send advert", action: { link.advertise(); Haptics.success() })
                    .panel(.inset)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(foxes.enumerated()), id: \.element.publicKey) { i, c in
                        if i > 0 { FieldDivider() }
                        Button { hunt.start(c) } label: {
                            MeshCoreNodeRow(contact: c, signal: feed.signal(meshcore: c.publicKey), chevron: true)
                        }
                        .buttonStyle(.rowPress)
                    }
                }
                .panel(.inset)
            }
            Notice(text: "Only hunt repeaters you're allowed to walk up to: many sit on private property. Hide your own (like Wildcat Solar) somewhere public and let friends hunt it.",
                   symbol: "hand.raised")
        }
    }

    private func distance(_ fox: MeshCore.Contact) -> Double? {
        guard let p = fox.position, let here = explore.here else { return nil }
        return Geo.distance(here, LatLon(lat: p.latitude, lon: p.longitude))
    }

    @ViewBuilder private func hunting(_ fox: MeshCore.Contact) -> some View {
        let d = distance(fox)
        HStack(spacing: 8) {
            NetworkTag(.meshcore, via: link.session.me?.name)
            Spacer()
            Tag(MeshCoreFormat.kind(fox.kind))
        }
        if hunt.found != nil {
            ResultCard(title: "FOUND IT", subtitle: "\(fox.name) · best \(hunt.best.map { MeshCoreFormat.minus("\($0.rssi) dBm") } ?? "-") · \(hunt.readings.count) readings", proofs: [])
        }
        SignalScope(title: fox.name, rssi: hunt.last?.rssi, snr: hunt.last?.snr, score: hunt.score, time: hunt.last?.at,
                    trend: hunt.trend, pulse: hunt.readings.count,
                    listeningHint: "Waiting to hear \(fox.name) itself… Tap Ping to ask it.",
                    started: hunt.started,
                    footer: "best \(hunt.best.map { MeshCoreFormat.minus("\($0.rssi) dBm · SNR \(String(format: "%.1f", $0.snr))") } ?? "-") · \(hunt.readings.count) readings")
            .hapticTicker(score: hunt.score, active: hunt.isActive && hunt.last != nil)
        if let d, hunt.found == nil {
            // Like Daily Fox: the distance only shows once you're close.
            Text(d < 150 ? "Within \(Geo.format(d)). Look around!" : "Keep going: distance shows once you're within 150 m.")
                .font(Theme.Fonts.dataBold).foregroundStyle(d < 150 ? Theme.ok : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .onChange(of: d < 40) { _, close in if close { hunt.markFound() } }
        }
        StatusKeyRow {
            StatusKey(hunt.canPing ? "Ping now" : "Ping (wait)", symbol: "dot.radiowaves.left.and.right", primary: true) { hunt.ping() }
                .frame(maxWidth: .infinity).layoutPriority(1)
                .disabled(!hunt.canPing || !link.state.isReady)
            if hunt.found == nil {
                StatusKey("Found", symbol: "flag.checkered") { hunt.markFound() }
            }
            StatusKey("End", symbol: "xmark") { hunt.stop() }
        }
    }
}
