import SwiftUI
import WildcatRadioCore

/// Pick the node to hunt.
struct SoloHuntSetup: View {
    @Environment(Radio.self) private var radio
    @Environment(SoloHunt.self) private var solo
    @State private var query = ""
    @State private var go = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hunt any node by its signal alone. No referee needed: have someone hide your fox, or hide it yourself and walk away for a few minutes first.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                if radio.isReady {
                    ModuleHeader(1, "Which node is the fox?", detail: "\(nodes.count)")
                    if nodes.isEmpty {
                        EmptyState(symbol: "scope", title: "No nodes yet",
                                   text: query.isEmpty ? "Your node hasn't heard anyone. Give it a minute." : "Nothing matches \(query).")
                            .panel()
                    } else {
                        FieldGroup {
                            ForEach(Array(nodes.enumerated()), id: \.element.num) { i, n in
                                if i > 0 { FieldDivider(inset: 78) }
                                Button {
                                    solo.start(n.num)
                                    go = true
                                } label: {
                                    NodeRow(node: n)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                }
                                .buttonStyle(.rowPress)
                            }
                        }
                    }
                } else {
                    NeedsRadioNotice(.meshtastic, why: "Your node hears the fox. On MeshCore? Try the repeater hunt on Play.")
                }
            }
            .padding(Theme.Space.edge)
        }
        .screen()
        .searchable(text: $query, prompt: "Find your fox")
        .navigationTitle("Solo hunt")
        .navigationDestination(isPresented: $go) { SoloHuntView() }
    }

    private var nodes: [NodeInfo] {
        radio.session.nodes.values
            .filter { $0.num != radio.session.myNode }
            .filter { query.isEmpty || [$0.shortName, $0.longName, $0.num.id].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) } }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
    }
}

/// Hunting one node on your own: the Fox Hunt instrument with your own
/// readings, pings, and the direction your located readings point.
struct SoloHuntView: View {
    @Environment(SoloHunt.self) private var solo
    @Environment(Radio.self) private var radio
    @Environment(Heading.self) private var heading
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TicksKey.storageKey) private var ticks = true
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let f = solo.finished, let s = solo.started {
                    result(f.timeIntervalSince(s))
                } else {
                    instrument
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 4)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .safeAreaInset(edge: .bottom) {
            if solo.isActive { keys }
        }
        .toolbar(solo.isActive ? .hidden : .automatic, for: .tabBar)
        .navigationTitle("Solo hunt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                FoxNavTitle(title: "Solo hunt", network: .meshtastic, via: radio.huntVia, connected: radio.isReady)
            }
            ToolbarItem(placement: .topBarTrailing) { GuideButton(chapter: "foxhunt") }
        }
        .onAppear { heading.start() }
        .onDisappear { heading.stop() }
        .sensoryFeedback(trigger: solo.tracker?.trend ?? .none) { _, new in
            switch new {
            case .warmer: return .increase
            case .colder: return .decrease
            default: return nil
            }
        }
        .onChange(of: solo.isActive, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
    }

    private var foxName: String {
        guard let f = solo.fox else { return "?" }
        return radio.session.label(for: f)
    }

    private var fresh: Bool {
        guard let t = solo.tracker?.latest?.time else { return false }
        return Date().timeIntervalSince(t) < 180
    }

    private let listening = "The fox beacons about once a minute. Ping for a fresh reading."

    @ViewBuilder private var instrument: some View {
        let tracker = solo.tracker
        let samples = tracker?.samples ?? []
        let score = tracker?.latest?.score ?? 0
        FoxTargetCard(network: .meshtastic, fox: foxName,
                      detail: solo.fox.flatMap { radio.session.nodes[$0]?.longName } ?? solo.fox?.id,
                      codeLabel: "Mode", code: "SOLO", copyable: false)
        FoxSignalPanel(network: .meshtastic, samples: samples, best: tracker?.best, listening: listening)
            .hapticTicker(score: score, active: ticks && solo.isActive && fresh && phase == .active)
        if solo.access == .denied || solo.access == .restricted {
            LocationNotice(access: solo.access)   // the bearing needs it
        }
        FoxInstrumentRow {
            FoxBearingRadar(bearing: solo.signalBearing, heading: heading.degrees, tint: MeshNetwork.meshtastic.color,
                            pulse: samples.count, live: fresh, noBearing: "walk for a bearing")
        } readouts: {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                FoxReadoutGrid(cells: cells(now: ctx.date)) {
                    FoxWideCell.fixes(solo.fixes, bearing: solo.signalBearing)
                }
            }
        }
        FoxInstructionLine(instruction)
        if radio.source != .bluetooth {
            MetaLine("Pings need a real node over Bluetooth.")
                .padding(.top, 4)
        }
    }

    private func cells(now: Date) -> [FoxCell] {
        let tracker = solo.tracker
        let unit = FoxReadout.unit(for: tracker?.latest)
        let best = tracker?.best.flatMap { FoxReadout.value($0, unit) }
        let hops = solo.fox.flatMap { radio.session.nodes[$0]?.hopsAway }
        return [
            FoxCell(label: "Elapsed", value: solo.started.map { FoxReadout.clock(now.timeIntervalSince($0)) } ?? "--",
                    sub: "\(Geo.format(solo.walked)) walked"),
            FoxCell(label: "Pings", value: "\(solo.pings)", sub: "\(tracker?.samples.count ?? 0) readings"),
            FoxCell(label: "Best", value: best.map { FoxReadout.format($0, unit: unit) } ?? "--", unit: best == nil ? nil : unit.short),
            FoxCell(label: "Hops", value: hops.map(String.init) ?? "--",
                    sub: hops.map { $0 == 0 ? "direct" : "relayed" }),
        ]
    }

    private var instruction: (lead: String, rest: String) {
        let samples = solo.tracker?.samples ?? []
        let unit = FoxReadout.unit(for: samples.last)
        return FoxReadout.instruction(hasReading: !samples.isEmpty,
                                      warmth: FoxReadout.warmth(change: FoxReadout.change(samples, unit: unit), unit: unit),
                                      bearing: solo.signalBearing, listening: listening)
    }

    private var keys: some View {
        FoxKeyBar {
            PingKey(lastPing: solo.lastPing, cooldown: SoloHunt.pingCooldown, enabled: solo.canPing) { solo.ping() }
            StatusKey("Found it", symbol: "flag.checkered") { solo.finish() }
            TicksKey()
            StatusKey("End", symbol: "xmark") { confirmEnd = true }
                .confirmationDialog("End this hunt?", isPresented: $confirmEnd, titleVisibility: .visible) {
                    Button("End without a find", role: .destructive) {
                        solo.reset()
                        dismiss()
                    }
                }
        }
    }

    private func result(_ seconds: TimeInterval) -> some View {
        var lines = ["\(Int(seconds / 60)) min \(Int(seconds) % 60) s · \(Geo.format(solo.walked)) walked · \(solo.pings) pings"]
        if let best = solo.tracker?.best?.rssi {
            lines.append("Best reading \(FoxReadout.format(Double(best), unit: .rssi)) dBm from \(solo.tracker?.samples.count ?? 0) readings")
        }
        return VStack(spacing: Theme.Space.stack) {
            ResultCard(title: "FOUND IT", subtitle: foxName, lines: lines)
            Button("Hunt again") {
                solo.reset()
                dismiss()   // back to the list to pick the next fox
            }
                .buttonStyle(.fieldPrimary)
        }
    }
}
