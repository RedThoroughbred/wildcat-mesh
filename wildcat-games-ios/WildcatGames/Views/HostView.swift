import SwiftUI

/// Host a Fox Hunt on the Den: pick the fox, set its code, start, watch.
struct HostView: View {
    @Environment(GamesStore.self) private var games
    @Environment(DenStore.self) private var den
    @State private var fox = ""
    @State private var code = ""
    @State private var mode = "code"
    @State private var channel = "WGHUNT"
    @State private var error: String?
    @State private var busy = false
    @ScaledMetric(relativeTo: .title) private var codeSize: CGFloat = 26

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    ToastBanner(text: error, kind: .danger)
                }
                if games.reachable == false {
                    Notice(text: games.error ?? "The games server isn't reachable.")
                        .panel()
                }
                if let s = games.state, s.hunt.phase != "ended" {
                    running(s)
                } else {
                    if let s = games.state { finished(s) }
                    form
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("Host a hunt")
        .task { if den.nodes.isEmpty { await den.refresh() } }
        .onAppear { games.startPolling() }
        .onDisappear { games.stopPolling() }
    }

    // MARK: New hunt

    private var foxChoices: [Den.Node] {
        den.nodes.filter { $0.id != den.myID && $0.isRF }
            .sorted { ($0.last_heard ?? 0) > ($1.last_heard ?? 0) }
    }

    @ViewBuilder private var form: some View {
        ModuleHeader(1, "New hunt", detail: "on the Den")
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Fox node")
                Picker("Fox node", selection: $fox) {
                    Text("Pick the fox").tag("")
                    ForEach(foxChoices) { n in
                        Text("\(n.name) · \(n.long_name ?? n.id) · \(DenFormat.ago(n.lastHeard))").tag(n.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fieldInput()
                Text("Nodes the Den has heard over the air, most recent first. Power the fox up near the Den once so it shows here.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Code written on the fox")
                TextField("4417", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(size: codeSize, weight: .bold, design: .monospaced))
                    .fieldInput()
                    .onChange(of: code) { _, v in
                        let d = String(v.filter(\.isNumber).prefix(4))
                        if d != v { code = d }
                    }
                Text("It never leaves the Den; hunters prove the find by typing it.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Win by")
                FieldSegmented(options: [("code", "Code"), ("either", "Code or signal"), ("signal", "Signal")], selection: $mode)
            }
            VStack(alignment: .leading, spacing: 6) {
                CardLabel("Channel")
                TextField("WGHUNT", text: $channel).textInputAutocapitalization(.characters).fieldInput()
            }
            Button {
                act { try await games.create(fox: fox, code: code, mode: mode, channel: channel) }
            } label: {
                Text("Create hunt")
            }
            .buttonStyle(.fieldPrimary)
            .disabled(fox.isEmpty || code.count != 4 || busy || games.reachable != true)
        }
        .panel()
    }

    // MARK: Running hunt

    @ViewBuilder private func running(_ s: GamesStore.HuntState) -> some View {
        let active = s.hunters.filter { $0.left != true }
        ModuleHeader(1, "Your hunt") {
            HStack(spacing: 5) {
                StatusLED(color: Theme.ok, on: games.isLive, size: 6)
                Text((s.hunt.phase ?? "").capitalized)
            }
        }
        FoxTargetCard(network: .meshtastic, fox: s.hunt.fox_name ?? "?", detail: s.hunt.fox, code: s.hunt.code ?? "FOX")
        InstrumentPanel {
            ReadoutRow {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ReadoutCell("Elapsed", value: s.hunt.started_at.map { FoxReadout.clock(ctx.date.timeIntervalSince1970 - $0) } ?? "--",
                                sub: s.hunt.started_at == nil ? "not started" : nil)
                }
                CellDivider()
                ReadoutCell("Hunters", value: "\(active.count)")
                CellDivider()
                ReadoutCell("Found", value: "\(s.hunters.filter { $0.found != nil }.count)")
            }
        }
        MetaLine("Hunters join from Play → Fox Hunt, or with WG JOIN \(s.hunt.code ?? "") on \(s.hunt.channel_name ?? "WGHUNT").",
                 raw: "mode \(s.hunt.mode ?? "code") · channel \(s.hunt.channel_name ?? "WGHUNT")")
            .padding(.vertical, 4)
        HStack(spacing: 10) {
            if s.hunt.phase == "lobby" {
                Button("Start the hunt") { act { try await games.start() } }
                    .buttonStyle(.field(.primary, .regular))
            }
            Button("End hunt", role: .destructive) { act { try await games.end() } }
                .buttonStyle(.field(.destructive, .regular))
        }
        .disabled(busy)
        ModuleHeader(2, "Hunters", detail: "\(active.count)")
            .padding(.top, 8)
        if s.hunters.isEmpty {
            Text("Nobody has joined yet.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
        } else {
            FieldGroup {
                ForEach(Array(s.hunters.enumerated()), id: \.element.id) { i, h in
                    if i > 0 { FieldDivider() }
                    HunterRow(hunter: h)
                }
            }
        }
    }

    @ViewBuilder private func finished(_ s: GamesStore.HuntState) -> some View {
        ModuleHeader(nil, "Last hunt", detail: s.hunt.code)
        let finders = s.hunters.filter { $0.found != nil }
        if finders.isEmpty {
            Text("Nobody found the fox.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
        } else {
            FieldGroup {
                ForEach(Array(finders.enumerated()), id: \.element.id) { i, h in
                    if i > 0 { FieldDivider() }
                    HunterRow(hunter: h)
                }
            }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await work()
                error = nil
            } catch {
                self.error = DenStore.describe(error)
            }
        }
    }
}

private struct HunterRow: View {
    let hunter: GamesStore.Hunter

    private var trendColor: Color {
        switch hunter.trend {
        case "WARMER", "HOT": return Theme.ok
        case "COLDER": return Theme.alert
        default: return Theme.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let f = hunter.found {
                Text("#\(f.place ?? 0)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.ok)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ok.opacity(0.3), lineWidth: 1))
            } else {
                IconTile(symbol: "person")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(hunter.name ?? hunter.id).font(Theme.Fonts.heading)
                    .foregroundStyle(hunter.left == true ? Theme.textTertiary : Theme.textPrimary)
                HStack(spacing: 6) {
                    if hunter.found == nil { Tag(hunter.trend ?? "–", color: trendColor == Theme.textTertiary ? Theme.textSecondary : trendColor) }
                    Text(hunter.id).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let f = hunter.found {
                Text("+\(f.points ?? 0) · \(f.clock ?? "")").font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textPrimary)
            } else if let b = hunter.best {
                Text(b.rssi.map { "best \(FoxReadout.format($0, unit: .rssi)) dBm" }
                     ?? b.snr.map { "best \(FoxReadout.format($0, unit: .snr)) dB" } ?? "")
                    .font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .opacity(hunter.left == true ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}
