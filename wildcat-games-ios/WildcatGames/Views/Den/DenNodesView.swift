import SwiftUI

/// Every node the Den knows, newest first, searchable.
struct DenNodesView: View {
    @Environment(DenStore.self) private var den
    @State private var query = ""
    @State private var rfOnly = true

    private var rows: [Den.Node] {
        den.nodes
            .filter { !rfOnly || $0.isRF }
            .filter {
                query.isEmpty || [$0.short_name, $0.long_name, $0.id, $0.hw].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { ($0.last_heard ?? 0) > ($1.last_heard ?? 0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.stack) {
                FieldSegmented(options: [(true, "Heard over RF"), (false, "All")], selection: $rfOnly)
                ModuleHeader(1, "Heard by the Den", detail: "\(rows.count)") { NetworkTag(.meshtastic) }
                if rows.isEmpty {
                    EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No nodes here",
                               text: query.isEmpty ? "The Den hasn't heard anyone this way yet." : "Nothing matches \(query).")
                        .panel()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, n in
                            if i > 0 { FieldDivider(inset: 0) }
                            NavRow { DenNodeDetail(node: n) } label: {
                                DenNodeRow(node: n, signal: signal(n.id))
                                    .padding(.horizontal, Theme.Space.rowH)
                                    .padding(.vertical, Theme.Space.rowV)
                            }
                        }
                    }
                    .panel(.inset)
                }
            }
            .padding(Theme.Space.edge)
        }
        .screen()
        .searchable(text: $query, prompt: "Name, ID or hardware")
        .navigationTitle("Den nodes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await den.refresh() }
    }

    private func signal(_ id: String) -> Den.Signal.Row? { den.signal?.nodes.first { $0.id == id } }
}

/// A Den node row (AB `.r`): glyph, name, a plain line, and the signal the Den hears it at.
struct DenNodeRow: View {
    let node: Den.Node
    let signal: Den.Signal.Row?

    private var symbol: String {
        let r = node.role?.uppercased() ?? ""
        if r.contains("ROUTER") || r.contains("REPEATER") { return "antenna.radiowaves.left.and.right" }
        return node.isRF ? "person" : "globe"
    }

    var body: some View {
        let snr = signal?.snr ?? node.snr
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: node.isRF ? Theme.meshtastic : nil, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.long_name ?? node.id).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let r = node.role, r.uppercased() != "CLIENT" { Tag(r) }
                }
                Text([node.hops_away.map { $0 == 0 ? "Direct" : "\($0) hop\($0 == 1 ? "" : "s")" }, node.isRF ? nil : "internet",
                      node.hw, MeshtasticSummary.ago(node.lastHeard)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Fonts.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let snr {
                VStack(alignment: .trailing, spacing: 4) {
                    SegmentMeter(lit: SignalGrade.bars(snr: snr, rssi: nil), of: 5,
                                 tint: signal?.cls == "weak" ? Theme.alert : Theme.meshtastic)
                    Text(MeshtasticSummary.signed(snr) + " dB")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DenNodeDetail: View {
    @Environment(DenStore.self) private var den
    let node: Den.Node
    @State private var showCompose = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(symbol: node.isRF ? "person" : "globe", tint: node.isRF ? Theme.meshtastic : nil, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.long_name ?? node.id)
                            .font(.system(.title, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        HStack(spacing: 6) {
                            if let r = node.role { Tag(r) }
                            NetworkTag(.meshtastic)
                            Text(node.id).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            StatusLED(color: Theme.ok, on: node.lastHeard.map { Date().timeIntervalSince($0) < 7200 } ?? false, size: 6)
                            Text("Heard \(MeshtasticSummary.ago(node.lastHeard)) by the Den\(node.isRF ? "" : ", over the internet")")
                                .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    showCompose = true
                } label: {
                    Label("Message through the Den", systemImage: "paperplane")
                }
                .buttonStyle(.fieldPrimary)
                ModuleHeader(1, "Link")
                ReadoutRow {
                    ReadoutCell("SNR", value: node.snr.map { MeshtasticSummary.signed($0) } ?? "—", unit: node.snr == nil ? nil : "dB")
                    CellDivider()
                    ReadoutCell("Hops", value: node.hops_away.map(String.init) ?? "—", sub: node.isRF ? "over RF" : "internet")
                    CellDivider()
                    ReadoutCell("Batt", value: node.voltage.map { String(format: "%.2f", $0) } ?? node.battery.map { $0 > 100 ? "USB" : "\($0)" } ?? "—",
                                unit: node.voltage != nil ? "V" : node.battery.map { $0 > 100 ? "" : "%" })
                }
                .instrumentPanel()
                ModuleHeader(2, "Raw", action: "Copy all", symbol: "doc.on.doc") {
                    UIPasteboard.general.string = KeyValueGrid.text(items)
                    Haptics.success()
                }
                KeyValueGrid(items)
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCompose) { DenComposeSheet(to: node.id, toName: node.name) }
    }

    private var items: [KeyValueItem] {
        var out = [KeyValueItem(key: "id", value: node.id)]
        out.append(KeyValueItem(key: "names", value: [node.short_name, node.long_name].compactMap { $0 }.joined(separator: " · ")))
        if let hw = node.hw { out.append(KeyValueItem(key: "hw", value: hw)) }
        if let r = node.role { out.append(KeyValueItem(key: "role", value: r)) }
        out.append(KeyValueItem(key: "via", value: node.isRF ? "radio" : "internet",
                                note: node.isRF ? "\(node.rf_count ?? 0) pkts" : "\(node.mqtt_count ?? 0) mqtt"))
        if let h = node.lastHeard {
            out.append(KeyValueItem(key: "heard", value: h.formatted(date: .omitted, time: .standard), note: DenFormat.ago(h)))
        }
        if let s = node.snr { out.append(KeyValueItem(key: "snr", value: MeshtasticSummary.signed(s, digits: 2) + " dB")) }
        if let b = node.battery { out.append(KeyValueItem(key: "battery", value: b > 100 ? "plugged in" : "\(b)%",
                                                          note: node.voltage.map { String(format: "%.2f V", $0) })) }
        if let p = node.position, let la = p.lat, let lo = p.lon, node.hasPosition {
            out.append(KeyValueItem(key: "pos", value: String(format: "%.4f, %.4f", la, lo).replacingOccurrences(of: "-", with: "−")))
        }
        return out
    }
}
