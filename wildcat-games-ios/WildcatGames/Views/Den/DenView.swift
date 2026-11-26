import SwiftUI

/// The Den at a glance: is it up, what does it hear, and ways in.
struct DenView: View {
    @Environment(DenStore.self) private var den
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                if !den.isPaired {
                    unpaired
                } else if let error = den.error {
                    ToastBanner(text: error, kind: .danger)
                }
                ModuleHeader(1, "Base station", action: "Settings", symbol: "gearshape") { showSettings = true }
                header
                ModuleHeader(2, "Inside")
                links
                servicesCard
                if let updated = den.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .font(Theme.Fonts.raw)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("Den")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await den.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { GuideButton(chapter: "den") }
        }
        .sheet(isPresented: $showSettings) { DenSettingsView() }
        .onAppear { den.startPolling() }
        .onDisappear { den.stopPolling() }
    }

    private var unpaired: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Emblem(symbol: "house.lodge", size: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text("A Den is optional").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    NetworkTag(.meshtastic)
                }
            }
            Text("Every game works with just phones and nodes. A Den adds an always-on base station: a Pi or computer with a node plugged in, running the Wildcat Den software. It keeps history, maps coverage and can referee hunts. Enter its address (over Tailscale or your home network) to pair it; its history, maps and hunts then show up here.")
                .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Enter Den address") { showSettings = true }
                .buttonStyle(.fieldPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.hero)
    }

    /// Name and state, then the numbers (AB node card).
    private var header: some View {
        let c = den.about?.counts
        let cls = den.signal?.summary?.classes
        let state = den.isReachable ? (den.health?.meshd.map { "Online · radio \($0)" } ?? "Online")
            : den.isLoading ? "Connecting…" : den.isPaired ? "Offline" : "Not paired"
        return InstrumentPanel {
            HStack(spacing: 12) {
                IconTile(symbol: "house.lodge", tint: den.isReachable ? Theme.meshtastic : nil, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(den.about?.name ?? "The Den")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        NetworkTag(.meshtastic)
                    }
                    HStack(spacing: 6) {
                        StatusLED(color: den.isReachable ? Theme.ok : Theme.alert, on: den.isReachable || den.isLoading, size: 6)
                        Text(state).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if den.isLoading { ProgressView().controlSize(.small).tint(Theme.textSecondary) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 10)
            if let me = den.denNode {
                Text([me.long_name ?? me.name, me.battery.map { $0 > 100 ? "plugged in" : "\($0)%" },
                      me.voltage.map { String(format: "%.2f V", $0) },
                      den.services?.uptime.map { "up " + DenFormat.duration($0) },
                      "\(den.health?.packets_seen ?? 0) packets seen"].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Fonts.raw)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            PanelDivider()
            ReadoutRow {
                ReadoutCell("Nodes", value: c?.nodes.map(String.init) ?? "—")
                CellDivider()
                ReadoutCell("Over RF", value: c?.rf.map(String.init) ?? "—")
                CellDivider()
                ReadoutCell("Last hour", value: c?.heard_1h.map(String.init) ?? "—")
            }
            PanelDivider()
            ReadoutRow {
                ReadoutCell("Strong", value: cls?.strong.map(String.init) ?? "—", tint: cls?.strong == nil ? Theme.textPrimary : Theme.ok)
                CellDivider()
                ReadoutCell("Weak", value: cls?.weak.map(String.init) ?? "—", tint: (cls?.weak ?? 0) > 0 ? Theme.alert : Theme.textPrimary)
                CellDivider()
                let avg = den.signal?.summary?.avg_snr
                ReadoutCell("Avg SNR", value: avg.map { MeshtasticSummary.signed($0) } ?? "—", unit: avg == nil ? nil : "dB")
            }
        }
    }

    private var links: some View {
        VStack(spacing: 0) {
            NavRow { DenChatView() } label: {
                FieldRow(symbol: "bubble.left.and.bubble.right", title: "Messages", subtitle: "What the Den heard this week",
                         detail: "\(den.chat.count)")
            }
            FieldDivider()
            NavRow { DenNodesView() } label: {
                FieldRow(symbol: "point.3.connected.trianglepath.dotted", title: "Nodes", subtitle: "Everyone the Den knows",
                         detail: "\(den.nodes.count)")
            }
            FieldDivider()
            NavRow { CoverageView() } label: {
                FieldRow(symbol: "figure.walk", title: "Coverage", subtitle: "Walks, drives and dead spots")
            }
            FieldDivider()
            NavRow { DenMapView() } label: {
                FieldRow(symbol: "map", title: "Map", detail: "\(den.nodes.filter(\.hasPosition).count) placed")
            }
        }
        .panel(.inset)
    }

    /// What's running. The live signals (bus, radio, this web API) win over
    /// the unit status: the Observatory asks systemd for "wildcat-*" units,
    /// while the Pi runs them as "den-meshd" / "den-observatory".
    @ViewBuilder private var servicesCard: some View {
        if let units = den.services?.units, !units.isEmpty {
            ModuleHeader(3, "Services", detail: "\(units.count)")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(units.keys.sorted().enumerated()), id: \.element) { i, name in
                    let status = Self.status(name, unit: units[name], den: den)
                    if i > 0 { FieldDivider(inset: 0) }
                    HStack(spacing: 10) {
                        StatusLED(color: status.color, on: status.color != Theme.textTertiary, size: 6)
                        Text(name.replacingOccurrences(of: "wildcat-", with: "")).font(Theme.Fonts.data).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(status.text).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                if let radio = den.services?.meshd?.radio {
                    FieldDivider(inset: 0)
                    Text(radio).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(.inset)
        }
    }

    static func status(_ name: String, unit: Den.Services.Unit?, den: DenStore) -> (text: String, color: Color) {
        if unit?.ActiveState == "active" { return (unit?.SubState ?? "running", Theme.ok) }
        let live: Bool?
        switch name {
        case "wildcat-meshd": live = den.health?.meshd == "connected"
        case "wildcat-observatory": live = den.isReachable
        case "mosquitto": live = den.health?.bus
        default: live = nil
        }
        switch live {
        case true?: return ("running", Theme.ok)
        case false?: return ("stopped", Theme.alert)
        case nil: return ("off", Theme.textTertiary)
        }
    }
}

enum DenFormat {
    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 48 { return "\(h)h \(m % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }

    /// "12s", "5m", "3h", "4d" ago.
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
