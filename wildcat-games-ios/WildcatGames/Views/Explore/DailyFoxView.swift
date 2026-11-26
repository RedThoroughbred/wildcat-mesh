import MapKit
import SwiftUI
import WildcatRadioCore

/// Hunting today's fox: the Fox Hunt instrument with your node's readings
/// of it, the direction your own readings point, pings and hints.
struct DailyFoxView: View {
    @Environment(ExploreModel.self) private var explore
    @Environment(Heading.self) private var heading
    @Environment(Radio.self) private var radio
    @Environment(\.scenePhase) private var phase
    @AppStorage(TicksKey.storageKey) private var ticks = true
    @State private var hint: String?
    @State private var confirmGiveUp = false

    private var running: DailyFoxRun? { explore.todayRun.flatMap { $0.isOver ? nil : $0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let run = explore.todayRun {
                    if run.isOver { result(run) } else { hunting(run) }
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 4)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: hint)
        }
        .screen()
        .safeAreaInset(edge: .bottom) {
            if running != nil { keys }
        }
        .toolbar(running != nil ? .hidden : .automatic, for: .tabBar)
        .navigationTitle("Daily Fox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                FoxNavTitle(title: "Daily Fox", network: .meshtastic, via: radio.huntVia, connected: radio.isReady)
            }
            ToolbarItem(placement: .topBarTrailing) { GuideButton(chapter: "explore") }
        }
        .onAppear { explore.begin(); heading.start() }
        .onDisappear { explore.end(); heading.stop() }
        .sensoryFeedback(trigger: explore.tracker?.trend ?? .none) { _, new in
            switch new {
            case .warmer: return .increase
            case .colder: return .decrease
            default: return nil
            }
        }
    }

    private var fresh: Bool {
        guard let t = explore.tracker?.latest?.time else { return false }
        return Date().timeIntervalSince(t) < 180
    }

    private let listening = "Listening for the fox. Repeaters beacon every few minutes; a ping asks for a reading now."

    @ViewBuilder private func hunting(_ run: DailyFoxRun) -> some View {
        let tracker = explore.tracker
        let samples = tracker?.samples ?? []
        let score = tracker?.latest?.score ?? 0
        FoxTargetCard(network: .meshtastic, fox: run.foxName, detail: run.foxID,
                      codeLabel: "Daily fox", code: run.day, copyable: false)
        if radio.source != .bluetooth || !radio.isReady {
            NeedsRadioNotice(.meshtastic, why: "Your node hears the fox.")
        }
        FoxSignalPanel(network: .meshtastic, samples: samples, best: tracker?.best, listening: listening)
            .hapticTicker(score: score, active: ticks && fresh && phase == .active)
        LocationNotice(access: explore.access) { explore.askLocation() }
        FoxInstrumentRow {
            FoxBearingRadar(bearing: explore.signalBearing, heading: heading.degrees, tint: MeshNetwork.meshtastic.color,
                            pulse: samples.count, live: fresh, noBearing: "walk for a bearing")
        } readouts: {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                FoxReadoutGrid(cells: cells(run, now: ctx.date)) {
                    FoxWideCell.fixes(explore.located.count, bearing: explore.signalBearing)
                }
            }
        }
        if let hint {
            ToastBanner(text: hint, kind: .info)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        FoxInstructionLine(instruction)
        MetaLine("Ping asks the fox to answer (a traceroute): a fresh reading, but it costs airtime, so one per 30 s. A hint costs 150 points.",
                 raw: "\(samples.count) readings · \(tracker?.relayedCount ?? 0) from traffic it relayed")
            .padding(.top, 4)
    }

    private func cells(_ run: DailyFoxRun, now: Date) -> [FoxCell] {
        let tracker = explore.tracker
        let unit = FoxReadout.unit(for: tracker?.latest)
        let best = tracker?.best.flatMap { FoxReadout.value($0, unit) }
        let hops = NodeNum(id: run.foxID).flatMap { radio.session.nodes[$0]?.hopsAway }
        return [
            FoxCell(label: "Elapsed", value: FoxReadout.clock(now.timeIntervalSince(run.started)),
                    sub: "\(Geo.format(run.walked)) walked"),
            FoxCell(label: "Pings", value: "\(run.pings)", sub: "\(run.hints) hint\(run.hints == 1 ? "" : "s")"),
            FoxCell(label: "Best", value: best.map { FoxReadout.format($0, unit: unit) } ?? "--", unit: best == nil ? nil : unit.short),
            FoxCell(label: "Hops", value: hops.map(String.init) ?? "--",
                    sub: hops.map { $0 == 0 ? "direct" : "relayed" }),
        ]
    }

    private var instruction: (lead: String, rest: String) {
        let samples = explore.tracker?.samples ?? []
        let unit = FoxReadout.unit(for: samples.last)
        return FoxReadout.instruction(hasReading: !samples.isEmpty,
                                      warmth: FoxReadout.warmth(change: FoxReadout.change(samples, unit: unit), unit: unit),
                                      bearing: explore.signalBearing,
                                      listening: "Walk around a little: after a few readings spread over 15 m, the radar shows where it gets stronger.")
    }

    private var keys: some View {
        FoxKeyBar {
            PingKey(lastPing: explore.lastPing, cooldown: ExploreModel.pingCooldown, enabled: explore.canPing) { explore.ping() }
            StatusKey("Hint", sub: "−150", symbol: "lightbulb") { hint = explore.hint() }
            TicksKey()
            StatusKey("Give up", symbol: "xmark") { confirmGiveUp = true }
                .confirmationDialog("Give up today's fox?", isPresented: $confirmGiveUp, titleVisibility: .visible) {
                    Button("Reveal it", role: .destructive) { explore.giveUp() }
                }
        }
    }

    private func result(_ run: DailyFoxRun) -> some View {
        let streak = DailyFox.streak(explore.runs, today: explore.today)
        var lines: [String] = []
        if let f = run.found {
            lines.append("\(run.score) points · \(Int(f.timeIntervalSince(run.started) / 60)) min · \(Geo.format(run.walked)) walked")
        }
        lines.append("Streak: \(streak) day\(streak == 1 ? "" : "s")")
        return VStack(alignment: .leading, spacing: 8) {
            ResultCard(title: run.found != nil ? "FOUND IT" : "REVEALED", subtitle: run.foxName,
                       tint: run.found != nil ? Theme.ok : Theme.textPrimary, celebrate: run.found != nil, lines: lines)
            ModuleHeader(1, "Where it was", detail: run.foxName)
                .padding(.top, 6)
            Map(initialPosition: .region(MKCoordinateRegion(center: run.foxPosition.coordinate,
                                                            latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                // The found radius, dashed like the range rings on the map.
                MapCircle(center: run.foxPosition.coordinate, radius: DailyFox.foundRadius)
                    .foregroundStyle(Theme.meshtastic.opacity(0.08))
                    .stroke(Theme.meshtastic.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Annotation(run.foxName, coordinate: run.foxPosition.coordinate) {
                    MapNodeDot(color: Theme.meshtastic)
                }
                UserAnnotation()
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            MetaLine("The ring is \(Int(DailyFox.foundRadius)) m: standing inside it counts as a find.")
        }
    }
}

/// A node on a map (AB/04): a dot in its network's colour with a dark rim.
struct MapNodeDot: View {
    var color: Color
    var size: CGFloat = 11

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
            .accessibilityHidden(true)
    }
}
