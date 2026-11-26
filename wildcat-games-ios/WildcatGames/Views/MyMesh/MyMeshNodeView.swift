import SwiftUI
import WildcatRadioCore

/// Everything we know about one owned radio, in plain language, with the
/// actions the app already has for it.
struct MyMeshNodeView: View {
    @Environment(MyMeshStore.self) private var store
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var confirmRemove = false
    @State private var go: Action?

    var body: some View {
        if let n = store.node(id) {
            let connected = store.isConnected(n)
            let network = OwnedNodeCard.network(n.network)
            let statusNo = 2
            let radioNo = n.repeater == nil ? 2 : 3
            let factsNo = radioNo + (n.radio == nil ? 0 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    header(n, connected: connected)
                    actions(n, connected: connected)
                    ModuleHeader(1, "Role")
                    ExplainerPanel("What it does", text: n.roleExplanation)
                    if let s = n.repeater {
                        ModuleHeader(statusNo, "Latest status") {
                            if let at = s.at { Text(OwnedNode.ago(at)).font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary) }
                        }
                        repeaterStatus(s)
                    }
                    if let r = n.radio {
                        ModuleHeader(radioNo, "Radio", detail: network.name)
                        radioCard(r)
                    }
                    ModuleHeader(factsNo, "Facts") {
                        Text("hold to copy").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    }
                    KeyValueGrid(facts(n), keyWidth: 104)
                    if n.origin != .practice {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label("Remove from My Mesh", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.field(.destructive, .regular))
                    }
                }
                .padding(Theme.Space.edge)
                .padding(.bottom, Theme.Space.xl)
            }
            .screen()
            .navigationTitle(n.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $go) { a in destination(a) }
            .confirmationDialog("Remove \(n.name) from My Mesh?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { store.remove(n.id); dismiss() }
            } message: {
                Text("Nothing changes on the radio. It comes back the next time this phone connects to it.")
            }
        } else {
            Text("This radio isn't in My Mesh any more.").foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).screen()
        }
    }

    private func header(_ n: OwnedNode, connected: Bool) -> some View {
        let network = OwnedNodeCard.network(n.network)
        return HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: OwnedNodeCard.symbol(n), tint: network.color, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(n.name).font(.system(.title, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).minimumScaleFactor(0.6)
                HStack(spacing: 6) {
                    Tag(n.roleTitle)
                    NetworkTag(network)
                    if n.origin == .practice { Tag("Practice", color: Theme.textTertiary) }
                }
                HStack(spacing: 7) {
                    StatusLED(color: Theme.ok, on: connected || store.isOnline(n), size: 7)
                    Text(connected ? "Connected to this phone" : "Heard " + OwnedNode.ago(n.lastHeard))
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    if let b = n.batteryShort {
                        Text("·").foregroundStyle(Theme.textQuaternary)
                        Text("batt " + b).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: Actions

    /// The companion's contact for a repeater or room server, when the connected node knows it.
    private func contact(_ n: OwnedNode) -> MeshCore.Contact? {
        guard n.network == .meshcore, meshcore.state.isReady, let p = MyMeshStore.bytes(hex: n.nodeID) else { return nil }
        return meshcore.session.contact(prefix: p)
    }

    private enum Action: Hashable {
        case connect(UUID), admin(Data, room: Bool), trace(Data), traceMeshtastic(NodeNum), settings(OwnedNode.Network)
    }

    /// Only the actions the app can do for this radio right now.
    private func availableActions(_ n: OwnedNode, connected: Bool) -> [Action] {
        var out: [Action] = []
        if !connected, n.origin != .practice, n.connectsToPhone, let bt = n.bluetoothID { out.append(.connect(bt)) }
        if n.isMeshCoreInfrastructure, let c = contact(n) {
            out.append(.trace(c.publicKey))
            out.append(.admin(c.publicKey, room: c.kind == .room))
        }
        if !connected, n.network == .meshtastic, radio.source == .bluetooth, radio.isReady,
           let num = NodeNum(id: n.nodeID), radio.session.nodes[num] != nil {
            out.append(.traceMeshtastic(num))
        }
        if connected, n.network == .meshcore || radio.source == .bluetooth { out.append(.settings(n.network)) }
        return out
    }

    @ViewBuilder private func actions(_ n: OwnedNode, connected: Bool) -> some View {
        let list = availableActions(n, connected: connected)
        if !list.isEmpty {
            StatusKeyRow {
                ForEach(Array(list.enumerated()), id: \.element) { i, a in
                    key(a, n, primary: i == 0)
                }
            }
        }
    }

    private func key(_ a: Action, _ n: OwnedNode, primary: Bool) -> some View {
        let trace = "point.topleft.down.to.point.bottomright.curvepath"
        switch a {
        case .connect(let bt):
            return StatusKey("Connect", symbol: "dot.radiowaves.left.and.right", primary: primary) { connect(n, bt) }
        case .admin(_, let room):
            return StatusKey(room ? "Room admin" : "Admin", symbol: "key", primary: primary) { go = a }
        case .trace, .traceMeshtastic:
            return StatusKey("Trace", symbol: trace, primary: primary) { go = a }
        case .settings:
            return StatusKey("Settings", symbol: "slider.horizontal.3", primary: primary) { go = a }
        }
    }

    @ViewBuilder private func destination(_ a: Action) -> some View {
        switch a {
        case .connect: EmptyView()
        case .admin(let key, _): MeshCoreRepeaterView(key: key)
        case .trace(let key): MeshCoreTraceView(key: key)
        case .traceMeshtastic(let num): NodeDetailView(num: num)
        case .settings(let network):
            if network == .meshcore { MeshCoreSettingsView() } else { NodeSettingsView() }
        }
    }

    private func connect(_ n: OwnedNode, _ bt: UUID) {
        switch n.network {
        case .meshtastic:
            radio.useBluetooth()
            radio.bluetooth().connect(bt)
        case .meshcore:
            meshcore.connect(bt)
        }
    }

    // MARK: Panels

    private func repeaterStatus(_ s: OwnedNode.RepeaterSnapshot) -> some View {
        let battery = s.batteryMillivolts.flatMap { MeshCoreFormat.batteryPercent(millivolts: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            InstrumentPanel {
                ReadoutRow {
                    ReadoutCell("Up", value: s.uptimeSeconds.map { MeshCoreFormat.duration(UInt32(clamping: $0)) } ?? "—", size: .large)
                    CellDivider()
                    ReadoutCell("Battery", value: s.batteryMillivolts.map(MeshCoreFormat.volts) ?? "—",
                                unit: s.batteryMillivolts == nil ? nil : "V", size: .large) {
                        if let battery {
                            HStack(spacing: 7) {
                                SegmentMeter(value: Double(battery) / 100, segments: 10, tint: battery < 20 ? Theme.alert : Theme.ok)
                                Text("\(battery)%").font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Relayed", value: s.packetsRelayed.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                    CellDivider()
                    ReadoutCell("Heard", value: s.packetsHeard.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                    CellDivider()
                    ReadoutCell("Noise", value: s.noiseFloor.map { MeshCoreFormat.minus("\($0)") } ?? "—",
                                unit: s.noiseFloor == nil ? nil : "dBm",
                                sub: s.noiseFloor.map { $0 <= -105 ? "quiet" : $0 <= -95 ? "some noise" : "noisy" })
                }
            }
            Text("Noise is the background hiss the repeater hears. Lower (more negative) is better; around −110 dBm is quiet.")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func radioCard(_ r: OwnedNode.RadioSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if r.frequencyMHz != nil || r.spreadingFactor != nil {
                RadioChips(frequency: r.frequencyMHz, bandwidth: r.bandwidthKHz, spreadingFactor: r.spreadingFactor,
                           codingRate: r.codingRate, txPower: r.txPowerDBm)
            }
            let named = [r.region, r.preset, r.slot.map { "slot \($0)" }].compactMap { $0 }
            if !named.isEmpty {
                Text(named.joined(separator: " · ")).font(Theme.Fonts.data).foregroundStyle(Theme.textPrimary)
            }
            if r.summary.isEmpty {
                Text("Not known yet").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            if let ch = r.channels, !ch.isEmpty {
                Text("Channels: " + ch.joined(separator: ", ")).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
            }
            if r.inferred == true {
                Text("Copied from your companion when you logged in: a repeater has to use the same settings to be heard.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func facts(_ n: OwnedNode) -> [KeyValueItem] {
        var items = [
            KeyValueItem(key: "network", value: n.networkName),
            KeyValueItem(key: "id", value: n.network == .meshcore ? String(n.nodeID.prefix(8)) : n.nodeID),
            KeyValueItem(key: "role", value: n.roleTitle),
        ]
        if let h = n.hardware { items.append(KeyValueItem(key: "hardware", value: h)) }
        if let f = n.firmware { items.append(KeyValueItem(key: "firmware", value: f)) }
        items.append(KeyValueItem(key: "battery", value: n.batteryText ?? "unknown"))
        items.append(KeyValueItem(key: "location", value: n.sharesLocation.map { $0 ? "shared" : "not shared" } ?? "unknown"))
        items.append(KeyValueItem(key: "connected", value: n.lastConnected.map { OwnedNode.ago($0) } ?? "never from this phone"))
        items.append(KeyValueItem(key: "heard", value: OwnedNode.ago(n.lastHeard)))
        items.append(KeyValueItem(key: "added", value: Self.how(n.origin), note: n.added.formatted(date: .abbreviated, time: .omitted)))
        return items
    }

    static func how(_ o: OwnedNode.Origin) -> String {
        switch o {
        case .connected: return "Connected"
        case .admin: return "Admin login"
        case .manual: return "Marked as yours"
        case .practice: return "Practice"
        }
    }
}
