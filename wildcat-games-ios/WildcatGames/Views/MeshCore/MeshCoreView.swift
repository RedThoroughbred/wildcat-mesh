import SwiftUI
import WildcatRadioCore

/// The MeshCore tab: find a companion node and connect, then an instrument
/// panel for it, who it hears, its chats, and everything to manage. Same skeleton
/// as the Meshtastic tab: title, packet ticker, radio pill, guide and app menu;
/// This radio, Radio, Heard nearby, Chats, Manage.
struct MeshCoreView: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshCoreStore.self) private var store
    @Environment(PacketFeed.self) private var feed
    @Environment(MyMeshStore.self) private var myMesh
    /// A find or reconnect waiting for Bluetooth to come up.
    @State private var pending = PendingScan()
    @State private var go: Destination?
    @State private var confirmSwitch = false
    @State private var showRadioHelp = false
    @AppStorage("meshcore.heardSort") private var sort = MeshCoreFormat.Sort.signal

    enum Destination: Hashable { case bridge, settings, contacts, setup }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                switch link.state {
                case .ready: ready
                case .connecting(let n), .syncing(let n): connecting(n)
                default: finder
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: link.state.isReady)
        }
        // Pull down to ask the node for its contacts again.
        .refreshable { if link.state.isReady { link.enqueue(.getContacts) } }
        // The title and live strip stay put (AB nav + ticker), as on the Meshtastic tab.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TabTitle(network: .meshcore)
                    .padding(.horizontal, Theme.Space.edge)
                    .padding(.bottom, 8)
                PacketTicker(events: feed.events(for: .meshcore), live: link.state.isReady)
            }
            .background(Theme.bg.ignoresSafeArea(edges: .top))
        }
        .screen()
        .navigationTitle("MeshCore")
        .navigationBarTitleDisplayMode(.inline)
        .hidesNavigationTitle()
        .toolbar { TabToolbar(guide: "meshcore") }
        .navigationDestination(item: $go) { d in
            switch d {
            case .bridge: BridgeView()
            case .settings: MeshCoreSettingsView()
            case .contacts: MeshCoreContactsView()
            case .setup: MeshCoreSetupView()
            }
        }
        .confirmationDialog(link.isDemo ? "End practice?" : "Switch radio?", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button(link.isDemo ? "End practice and find a node" : "Disconnect and find another") { disconnect(); find() }
            Button(link.isDemo ? "End practice" : "Disconnect", role: .destructive) { disconnect() }
        } message: {
            Text(link.isDemo ? "This ends practice on both networks." : "This disconnects \(link.session.me?.name ?? "this node"). Its chats stay on this phone.")
        }
        .onDisappear {
            pending.cancel()
            // Only when scanning: touching Bluetooth otherwise could bring up its prompt.
            if link.state == .scanning { link.stopScan() }
        }
    }

    /// Disconnects; in practice, ends practice on both networks (as the Meshtastic tab does).
    private func disconnect() {
        if link.isDemo { PracticeMode.end(radio, link) } else { link.disconnect() }
    }

    // MARK: Not connected

    /// The last MeshCore node this phone connected to (real ones only).
    private var lastNode: OwnedNode? {
        myMesh.saved.filter { $0.network == .meshcore && $0.lastConnected != nil && $0.origin != .practice }
            .max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }
    }

    private var finder: some View {
        let last = lastNode
        let saved = store.isOffline ? store.source : nil
        return VStack(alignment: .leading, spacing: Theme.Space.stack) {
            ModuleHeader(1, "This radio", detail: last == nil && saved == nil ? nil : "last used")
            if last != nil || saved != nil {
                MeshCoreLastNodeCard(node: last, saved: saved, name: store.offlineName)
            }
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Theme.hairline, lineWidth: 1).frame(width: 96, height: 96)
                    Circle().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4])).frame(width: 68, height: 68)
                    Image(systemName: looking ? "dot.radiowaves.left.and.right" : MeshNetwork.meshcore.symbol)
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.meshcore)
                        .symbolEffect(.variableColor.iterative, isActive: looking)
                }
                .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(looking ? "Looking for MeshCore nodes…" : "No MeshCore radio connected")
                        .font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Connect a node running MeshCore's Companion (Bluetooth) firmware. Close the MeshCore app first (on your phone and your Mac): a node talks to one app at a time.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let why) = link.state { ToastBanner(text: why, kind: .danger) }
                if link.state == .poweredOff || link.state == .unauthorized {
                    BluetoothNotice(allowed: link.state == .poweredOff)
                }
                VStack(spacing: 8) {
                    Button { if !looking { find() } } label: {
                        Label(link.state == .scanning ? "Scanning…" : pending.isWaiting ? "Waiting for Bluetooth…" : "Find MeshCore nodes",
                              systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.fieldPrimary)
                    if link.lastNodeID != nil {
                        Button { reconnect() } label: {
                            Label("Reconnect the last one", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.field(.secondary, .regular))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .instrumentPanel()
            StatusKeyRow {
                StatusKey("Link", sub: "Off", led: .off)
                StatusKey("Bluetooth", sub: bluetoothWord, led: bluetoothLED)
                StatusKey("Scan", sub: looking ? "On" : "Idle", led: looking ? .network(.meshcore) : .off) { if !looking { find() } }
            }
            if !link.discovered.isEmpty {
                ModuleHeader(2, "Found nearby", detail: "\(link.discovered.count)")
                VStack(spacing: 0) {
                    ForEach(Array(link.discovered.sorted { $0.rssi > $1.rssi }.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { FieldDivider() }
                        Button { link.connect(d.id) } label: { discoveredRow(d) }
                            .buttonStyle(.rowPress)
                    }
                }
                .panel(.inset)
            }
            Text("Repeaters and room servers don't appear here: they have no phone Bluetooth. They show up in Contacts once your node hears their advert.")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            let next = link.discovered.isEmpty ? 2 : 3
            if let saved {
                savedChats(saved, number: next)
            }
            // No node yet: practice is the next thing to try, so it comes before Manage (as on Meshtastic).
            PracticeCard()
            ModuleHeader(next + (saved == nil ? 0 : 1), "Manage")
            FieldGroup {
                MyMeshRow()
                FieldDivider()
                BothNetworksMapRow()
                FieldDivider()
                BridgeRow()
                FieldDivider()
                RNodeRow()
            }
        }
    }

    /// The last node's chats, read-only until it's connected again.
    @ViewBuilder private func savedChats(_ s: MeshCoreSession, number: Int) -> some View {
        let origins = savedOrigins(s)
        ModuleHeader(number, "Saved chats", detail: "read-only")
        VStack(spacing: 0) {
            if origins.isEmpty {
                Text("No chats saved from it yet.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(origins.enumerated()), id: \.element) { i, o in
                if i > 0 { FieldDivider() }
                NavRow { MeshCoreChatView(origin: o) } label: {
                    FieldRow(symbol: symbol(o), title: s.label(o), subtitle: last(o), detail: badge(o))
                }
            }
        }
        .panel(.inset)
        .opacity(0.85)
    }

    /// Saved channels with chats, then direct threads, newest first.
    private func savedOrigins(_ s: MeshCoreSession) -> [MeshCore.Message.Origin] {
        var channels = Set(s.channels.keys)
        for c in store.visibleChats { if case .channel(let i) = c.origin { channels.insert(i) } }
        return channels.sorted().map { MeshCore.Message.Origin.channel($0) } + directs
    }

    private func symbol(_ o: MeshCore.Message.Origin) -> String {
        switch o {
        case .channel(let i): return i == 0 ? "globe" : "lock"
        case .contact: return "person"
        }
    }

    private func discoveredRow(_ d: MeshCoreLink.Discovered) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: MeshNetwork.meshcore.symbol, tint: Theme.meshcore)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("Companion · Bluetooth · tap to connect").font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                SegmentMeter(lit: SignalGrade.bars(snr: nil, rssi: d.rssi), of: 5, tint: Theme.meshcore)
                Text(MeshCoreFormat.minus("\(d.rssi) dBm")).font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .contentShape(Rectangle())
    }

    private func connecting(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            ModuleHeader(1, "This radio")
            InstrumentPanel {
                HStack(spacing: 14) {
                    IconTile(symbol: MeshNetwork.meshcore.symbol, tint: Theme.meshcore, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).tint(Theme.meshcore)
                            Text(link.state == .connecting(name) ? "Connecting over Bluetooth…" : "Syncing contacts and channels…")
                                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                PanelDivider()
                Text("If iOS asks for a PIN, it's usually 123456 on nodes without a screen.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Button("Cancel") { link.disconnect() }
                .buttonStyle(.field(.quiet, .regular))
                .frame(maxWidth: .infinity)
        }
    }

    private var looking: Bool { link.state == .scanning || pending.isWaiting }

    private var bluetoothWord: String {
        switch link.bluetooth {
        case .notStarted: return "Not used yet"
        case .starting: return "Starting"
        case .on: return "On"
        case .off: return "Off"
        case .unauthorized: return "Not allowed"
        case .unsupported: return "None"
        }
    }

    private var bluetoothLED: StatusKey.LED {
        switch link.bluetooth {
        case .on: return .on
        case .off, .unauthorized, .unsupported: return .warn
        default: return .off
        }
    }

    /// Scans now, or once Bluetooth is on (a first tap may be waiting on its prompt).
    private func find() {
        let link = link
        pending.start {
            switch link.state {
            case .unauthorized, .scanning, .connecting, .syncing, .ready: return true
            default: link.scan(); return link.state == .scanning
            }
        }
    }

    private func reconnect() {
        let link = link
        pending.start {
            if link.state == .unauthorized { return true }
            let before = link.state
            link.reconnectLast()
            return link.state != before
        }
    }

    // MARK: Connected

    @ViewBuilder private var ready: some View {
        let s = link.session
        ModuleHeader(1, "This radio", action: link.isDemo ? "End practice" : "Switch",
                     symbol: link.isDemo ? "xmark" : "arrow.left.arrow.right") { confirmSwitch = true }
        MeshCoreStatusCard(go: $go)

        if let me = s.me {
            ModuleHeader(2, "Radio", action: showRadioHelp ? "Hide" : "What's this?", symbol: "questionmark.circle") {
                withAnimation(Theme.Motion.snappy) { showRadioHelp.toggle() }
            }
            NavRow { MeshCoreSettingsView() } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        RadioChips(frequency: me.frequency, bandwidth: me.bandwidth, spreadingFactor: me.spreadingFactor,
                                   codingRate: me.codingRate, txPower: me.txPower)
                        Text(MeshCoreFormat.presetName(frequency: me.frequency, bandwidth: me.bandwidth,
                                                       spreadingFactor: me.spreadingFactor, codingRate: me.codingRate)
                             .map { "\($0) · what most MeshCore nodes nearby use" } ?? "Custom settings · only radios set the same can hear it")
                            .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Chevron()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(.inset)
            }
            if showRadioHelp {
                ExplainerPanel("What are these numbers?",
                               text: "The frequency is the channel. Bandwidth (BW), spreading factor (SF) and coding rate (CR) trade speed for range. Every radio you want to hear must match all four. dBm is how loud yours transmits.")
                    .transition(.opacity)
            }
        }

        heardNearby

        ModuleHeader(4, "Chats", detail: store.totalUnread > 0 ? "\(store.totalUnread) new" : nil)
        VStack(spacing: 0) {
            let channels = s.channels.values.sorted { $0.index < $1.index }
            ForEach(Array(channels.enumerated()), id: \.element.index) { i, c in
                if i > 0 { FieldDivider() }
                NavRow { MeshCoreChatView(origin: .channel(c.index)) } label: {
                    FieldRow(symbol: c.index == 0 ? "globe" : "lock", title: s.label(.channel(c.index)),
                             subtitle: last(.channel(c.index)) ?? (c.index == 0 ? "Everyone on MeshCore" : "Private channel"),
                             detail: badge(.channel(c.index)))
                }
            }
            ForEach(directs, id: \.self) { o in
                FieldDivider()
                NavRow { MeshCoreChatView(origin: o) } label: {
                    FieldRow(symbol: "person", title: s.label(o), subtitle: last(o), detail: badge(o))
                }
            }
        }
        .panel(.inset)

        // Games (the repeater hunt) live on Play, for both networks.
        ModuleHeader(5, "Manage")
        FieldGroup {
            MyMeshRow()
            FieldDivider()
            NavRow { MeshCoreHuntView() } label: {
                FieldRow(symbol: "dot.radiowaves.left.and.right", title: "Repeater hunt", subtitle: "Find a real repeater by its signal alone")
            }
            FieldDivider()
            NavRow { MeshCoreContactsView() } label: {
                FieldRow(symbol: "person.2", title: "Contacts", detail: "\(s.contacts.count)")
            }
            FieldDivider()
            NavRow { MeshCoreChannelsView() } label: {
                FieldRow(symbol: "number", title: "Channels", subtitle: "Create, join, share",
                         detail: "\(s.channels.count) of \(s.device?.maxChannels ?? 8)")
            }
            if MeshCoreSetupCheck.needsSetup(s.me) {
                FieldDivider()
                Button { go = .setup } label: {
                    FieldRow(symbol: "wand.and.stars", tint: Theme.alert, title: "Set up this node",
                             subtitle: MeshCoreSetupCheck.line(s.me))
                }
                .buttonStyle(.rowPress)
            }
            FieldDivider()
            NavRow { MeshCoreSettingsView() } label: {
                FieldRow(symbol: "slider.horizontal.3", title: "Node settings", subtitle: "Name, radio, power, position, PIN")
            }
            FieldDivider()
            BridgeRow()
            FieldDivider()
            RNodeRow()
        }
    }

    /// The nodes this radio hears, best first, one tap from their page.
    @ViewBuilder private var heardNearby: some View {
        let all = Array(link.session.contacts.values)
        let recent = MeshCoreFormat.heardRecently(all)
        let list = MeshCoreFormat.sorted(recent.isEmpty ? all : recent, by: sort) { feed.signal(meshcore: $0) }
        let shown = Array(list.prefix(5))
        ModuleHeader(3, "Heard nearby", detail: "\(recent.count)") { MeshCoreSortMenu(sort: $sort) }
        if shown.isEmpty {
            EmptyState(symbol: "person.2.wave.2", title: "Nobody heard yet",
                       text: "Nodes show up here when your radio hears their advert. Send yours so they add you too.",
                       actionTitle: "Send advert", action: { link.advertise(); Haptics.success() })
                .panel(.inset)
            FieldGroup { maps }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.publicKey) { i, c in
                    if i > 0 { FieldDivider() }
                    NavRow { MeshCoreContactDetail(key: c.publicKey) } label: {
                        MeshCoreNodeRow(contact: c, signal: feed.signal(meshcore: c.publicKey), mine: MeshCoreFormat.isMine(c, in: myMesh))
                    }
                }
                if all.count > shown.count {
                    FieldDivider(inset: 0)
                    Button { go = .contacts } label: {
                        HStack {
                            Text("All \(all.count) contacts").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Chevron()
                        }
                        .padding(.horizontal, Theme.Space.rowH)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.rowPress)
                }
                FieldDivider(inset: 0)
                maps
            }
            .panel(.inset)
        }
    }

    /// Maps sit under the heard list on both network tabs: this network's, then both together.
    @ViewBuilder private var maps: some View {
        NavRow { MeshCoreMapView(bothNetworks: false) } label: {
            FieldRow(symbol: "map", title: "Map", subtitle: "Tap a node for bearing and distance",
                     detail: "\(link.session.contacts.values.filter { $0.position != nil }.count) placed")
        }
        FieldDivider()
        BothNetworksMapRow()
    }

    private var directs: [MeshCore.Message.Origin] { store.directs }

    private func badge(_ o: MeshCore.Message.Origin) -> String? {
        let n = store.unread(o)
        return n == 0 ? nil : "\(n) new"
    }

    private func last(_ o: MeshCore.Message.Origin) -> String? { store.lastLine(o) }
}

/// The connected MeshCore node as an instrument panel (AB MeshCore tab):
/// who it is, one plain sentence, readouts, and the status keys.
struct MeshCoreStatusCard: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var link
    @Environment(PacketFeed.self) private var feed
    @Environment(MeshBridge.self) private var bridge
    var go: Binding<MeshCoreView.Destination?> = .constant(nil)
    @State private var advertAt: Date?
    @State private var confirmDisconnect = false

    /// "Wildcat Bag" -> "WB": MeshCore has no short names.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let s = words.count > 1 ? String(words.prefix(3).compactMap(\.first)) : String(name.prefix(4))
        return s.isEmpty ? "MC" : s.uppercased()
    }

    var body: some View {
        let s = link.session
        VStack(alignment: .leading, spacing: 8) {
            InstrumentPanel {
                if let me = s.me {
                    head(me)
                    summary
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    PanelDivider()
                    readouts
                }
            }
            keys
        }
        .confirmationDialog(link.isDemo ? "End the practice node?" : "Disconnect \(s.me?.name ?? "this node")?",
                            isPresented: $confirmDisconnect, titleVisibility: .visible) {
            if link.isDemo {
                Button("End practice", role: .destructive) { PracticeMode.end(radio, link) }
            } else {
                Button("Disconnect", role: .destructive) { link.disconnect() }
            }
        } message: {
            Text(link.isDemo ? "The pretend Meshtastic and MeshCore nodes go away. Real radios stay connected."
                 : "Its chats stay on this phone. Reconnect from this tab.")
        }
    }

    private func head(_ me: MeshCore.SelfInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: MeshNetwork.meshcore.symbol, tint: Theme.meshcore, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(me.name).font(.system(.title2, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Tag("Companion")
                }
                HStack(spacing: 6) {
                    StatusLED(color: Theme.ok, size: 7)
                    Text(link.isDemo ? "Practice · pretend node" : "Connected · BLE")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    Text("·").foregroundStyle(Theme.textQuaternary)
                    Text(MeshCoreFormat.hex(me.publicKey.prefix(4)))
                        .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    if let v = link.session.device?.version {
                        Text(v).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var heard: [MeshCore.Contact] { MeshCoreFormat.heardRecently(Array(link.session.contacts.values)) }

    private var summary: some View {
        let h = heard
        let parts = MeshCoreFormat.summary(heard: h.count, repeaters: h.filter { MeshCoreFormat.isInfrastructure($0.kind) }.count,
                                           batteryMillivolts: link.session.batteryMillivolts)
        return (Text(parts.lead).foregroundStyle(Theme.textSecondary)
                + Text(parts.bold).foregroundStyle(Theme.textPrimary).fontWeight(.semibold)
                + Text(parts.rest).foregroundStyle(Theme.textSecondary))
            .font(Theme.Fonts.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var readouts: some View {
        let s = link.session
        let events = feed.events(for: .meshcore)
        let bins = MeshCoreFormat.activity(events.map(\.time), now: Date(), minutes: 12)
        let lastTen = bins.suffix(10).reduce(0, +)
        let battery = s.batteryMillivolts.flatMap { MeshCoreFormat.batteryPercent(millivolts: $0) }
        let best = s.contacts.values.compactMap { feed.signal(meshcore: $0.publicKey)?.snr }.max()
        return VStack(spacing: 0) {
            ReadoutRow {
                ReadoutCell("Battery", value: s.batteryMillivolts.map(MeshCoreFormat.volts) ?? "—",
                            unit: s.batteryMillivolts == nil ? nil : "V", size: .large) {
                    HStack(spacing: 7) {
                        SegmentMeter(value: Double(battery ?? 0) / 100, segments: 10, tint: (battery ?? 100) < 15 ? Theme.alert : Theme.ok)
                        Text(battery.map { "\($0)%" } ?? "not reported").font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                    }
                }
                CellDivider()
                ReadoutCell("Packets · heard", value: "\(s.heardPackets)", size: .large) {
                    HStack(spacing: 7) {
                        Sparkline(values: bins, tint: Theme.meshcore, style: .bars(highlight: nil))
                            .frame(width: 52, height: 11)
                        Text(lastTen < 10 ? "Quiet channel" : lastTen < 60 ? "Steady traffic" : "Busy channel")
                            .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            PanelDivider()
            ReadoutRow {
                ReadoutCell("Nodes", value: "\(heard.count)", sub: "in the last day")
                CellDivider()
                ReadoutCell("Best SNR", value: best.map { MeshCoreFormat.number($0) } ?? "—", unit: best == nil ? nil : "dB")
                CellDivider()
                TimelineView(.periodic(from: .now, by: 5)) { t in
                    let ago = s.lastHeard.map { MeshCoreFormat.ago($0, now: t.date, short: true) }
                    ReadoutCell("Last heard", value: ago ?? "—", sub: ago == nil ? "nothing yet" : ago == "now" ? "a packet" : "ago")
                }
            }
        }
    }

    private var keys: some View {
        let me = link.session.me
        let sharesPosition = me.map { $0.position != nil && $0.advertLocationPolicy != 0 } ?? false
        let bridged = bridge.enabled && bridge.isLive
        return TimelineView(.periodic(from: .now, by: 1)) { t in
            let sent = advertAt.map { t.date.timeIntervalSince($0) < 3 } ?? false
            StatusKeyRow {
                StatusKey("Link", sub: link.isDemo ? "Practice" : "BLE", led: .on) { confirmDisconnect = true }
                StatusKey("Setup", sub: MeshCoreSetupCheck.keyWord(me),
                          led: MeshCoreSetupCheck.needsSetup(me) ? .warn : .none) { go.wrappedValue = .setup }
                StatusKey("Bridge", sub: bridged ? "⇄ MT" : bridge.enabled ? "Waiting" : "Off",
                          led: bridged ? .on : bridge.enabled ? .warn : .off) { go.wrappedValue = .bridge }
                StatusKey("GPS", sub: sharesPosition ? "Shared" : me?.position != nil ? "Private" : "Off",
                          led: sharesPosition ? .on : .off) { go.wrappedValue = .settings }
                StatusKey("Advert", sub: sent ? "Sent" : "Send", led: sent ? .network(.meshcore) : .off) {
                    link.advertise()
                    advertAt = Date()
                    Haptics.success()
                }
            }
        }
    }
}

/// The MeshCore node used last time, dimmed, while nothing is connected (as the
/// Meshtastic tab shows its last node): name, when, and what its save holds.
struct MeshCoreLastNodeCard: View {
    /// From My Mesh: radio, battery and firmware as last seen.
    let node: OwnedNode?
    /// The node's saved chats and contacts.
    let saved: MeshCoreSession?
    /// Its name in the save.
    var name: String?

    var body: some View {
        InstrumentPanel {
            HStack(spacing: 12) {
                IconTile(symbol: MeshNetwork.meshcore.symbol, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(node?.name ?? name ?? "MeshCore node")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Tag("Companion")
                    }
                    HStack(spacing: 6) {
                        StatusLED(color: Theme.ok, on: false, size: 6)
                        Text("Not connected" + (node?.lastConnected.map { " · last \(MeshCoreFormat.ago($0))" } ?? ""))
                            .font(Theme.Fonts.detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 10)
            PanelDivider()
            ReadoutRow {
                ReadoutCell("Battery", value: node?.batteryVolts.map { String(format: "%.2f", $0) } ?? "—",
                            unit: node?.batteryVolts == nil ? nil : "V", tint: Theme.textSecondary)
                CellDivider()
                ReadoutCell("Contacts", value: saved.map { "\($0.contacts.count)" } ?? "—", tint: Theme.textSecondary)
                CellDivider()
                ReadoutCell("Chats", value: saved.map { "\(Set($0.conversationChats.map(\.origin)).count)" } ?? "—",
                            sub: "saved", tint: Theme.textSecondary)
            }
            if let line = rawLine {
                PanelDivider()
                Text(line)
                    .font(Theme.Fonts.raw)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "a1b2c3d4 · 910.525 MHz · SF7 · fw v1.17.1"
    private var rawLine: String? {
        guard let node else { return nil }
        let r = node.radio
        let parts: [String?] = [node.nodeID.isEmpty ? nil : String(node.nodeID.prefix(8)),
                                r?.frequencyMHz.map { String(format: "%.3f MHz", $0) },
                                r?.spreadingFactor.map { "SF\($0)" },
                                node.firmware.map { "fw \($0)" }]
        let s = parts.compactMap { $0 }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }
}
