import SwiftUI
import WildcatRadioCore

/// The Meshtastic tab: your own node (connect, status, readouts), its radio
/// settings, who it hears, its channels, and the tools around it.
struct RadioView: View {
    @Environment(Radio.self) private var radio
    @Environment(PacketFeed.self) private var feed
    @State private var route: MeshtasticRoute?
    @State private var cache = MeshtasticCache.load()
    #if DEBUG
    @State private var openedDebugRoute = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Theme.Space.stack) {
                        if radio.isReady {
                            ConnectedModules(route: $route)
                        } else {
                            DisconnectedModules(cache: cache)
                        }
                        // No node yet: practice is the next thing to try, so it comes before Manage.
                        if !radio.isReady { PracticeCard() }
                        ManageModule(number: manageNumber, route: $route)
                        if radio.isReady && radio.source != .practice { PracticeCard(replacing: .meshtastic) }
                    }
                    .padding(.horizontal, Theme.Space.edge)
                    .padding(.top, 8)
                    .padding(.bottom, Theme.Space.xl)
                }
            }
            // The title and live strip stay put (AB nav + ticker); rows scroll under them.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle(network: .meshtastic)
                        .padding(.horizontal, Theme.Space.edge)
                        .padding(.bottom, 8)
                    PacketTicker(events: feed.events(for: .meshtastic), live: radio.isReady)
                }
                .background(Theme.bg.ignoresSafeArea(edges: .top))
            }
            .screen()
            .navigationTitle("Meshtastic")
            .navigationBarTitleDisplayMode(.inline)
            .hidesNavigationTitle()
            .toolbar { TabToolbar(guide: "meshtastic") }
            .navigationDestination(item: $route) { $0.destination }
            .onChange(of: radio.isReady) { _, _ in cache = MeshtasticCache.load() }
            .onAppear {
                cache = MeshtasticCache.load()
                #if DEBUG
                // Developer-only: -Open map|nodes|settings|bridge|den|log pushes that screen once (for screenshots;
                // den and log live in the app menu, these routes are only for this).
                if !openedDebugRoute, let open = UserDefaults.standard.string(forKey: "Open") {
                    openedDebugRoute = true
                    route = [MeshtasticRoute.nodes, .map, .settings, .bridge, .den, .log].first { "\($0)" == open }
                }
                #endif
            }
        }
    }

    /// Manage's module number: after the connected modules, or after what the finder shows.
    private var manageNumber: Int {
        if radio.isReady { return 5 }
        return (cache == nil ? 2 : 4) + (DisconnectedModules.showsFound(radio) ? 1 : 0)
    }
}

/// Where the Meshtastic tab's keys and links go.
enum MeshtasticRoute: Hashable, Identifiable {
    case nodes, map, settings, bridge, den, log, guide(String)

    var id: Self { self }

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .nodes: NodesView()
        case .map: MeshMapView()
        case .settings: NodeSettingsView()
        case .bridge: BridgeView()
        case .den: DenView()
        case .log: LogView()
        case .guide(let id):
            if let c = Guide.chapter(id) { GuideChapterView(chapter: c) } else { GuideView() }
        }
    }
}

// MARK: - Shell pieces

/// A network tab's title (AB nav): the network's glyph in its colour and the name.
/// The system title is hidden so a wide radio pill never squeezes it to "Meshtas…".
struct TabTitle: View {
    let network: MeshNetwork
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 27

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: network.symbol)
                .font(.system(size: size * 0.7, weight: .regular))
                .foregroundStyle(network.color)
            Text(network.name)
                .font(.system(size: size, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Keeps the navigation title (back buttons, accessibility) but doesn't draw it in the bar.
    @ViewBuilder func hidesNavigationTitle() -> some View {
        if #available(iOS 18.0, *) {
            toolbar(removing: .title)
        } else {
            toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
        }
    }
}

// MARK: - Connected

private struct ConnectedModules: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MeshBridge.self) private var bridge
    @Binding var route: MeshtasticRoute?
    @State private var confirmDisconnect = false

    var body: some View {
        let s = radio.session
        let practice = radio.source == .practice
        ModuleHeader(1, "This radio", action: practice ? "End practice" : "Disconnect",
                     symbol: practice ? "xmark" : "antenna.radiowaves.left.and.right.slash") {
            confirmDisconnect = true
        }
        // The keys sit close under the panel, the same stack as the MeshCore status card.
        VStack(alignment: .leading, spacing: 8) {
            NodeCard()
            StatusKeyRow {
                StatusKey("Link", sub: practice ? "Sim" : "BLE", led: .on) { confirmDisconnect = true }
                StatusKey("Setup", sub: s.needsRegion ? "Region!" : practice ? "Sim" : "Node",
                          led: s.needsRegion ? .warn : .none) { if !practice { route = .settings } }
                    .disabled(practice)
                StatusKey("Bridge", sub: "⇄ MC", led: bridge.isLive ? .on : .off) { route = .bridge }
                StatusKey("GPS", sub: gpsWord, led: gpsOn ? .on : .off) { if !practice { route = .settings } }
            }
        }
        RadioModule(route: $route)
        HeardModule(route: $route)
        ChannelsModule()
            .confirmationDialog(practice ? "End the practice mesh?" : "Disconnect from your node?",
                                isPresented: $confirmDisconnect, titleVisibility: .visible) {
                if practice {
                    Button("End practice", role: .destructive) { PracticeMode.end(radio, meshcore) }
                } else {
                    Button("Disconnect", role: .destructive) { radio.link?.disconnect() }
                }
            } message: {
                Text(practice ? "The pretend Meshtastic and MeshCore nodes and the fox go away. Real radios stay connected."
                     : "Your node keeps running; Wildcat just stops listening to it.")
            }
    }

    private var myPosition: Bool {
        radio.session.myNode.flatMap { radio.session.nodes[$0]?.position } != nil
    }

    private var gpsOn: Bool { radio.session.position?.fixed == true || myPosition }

    private var gpsWord: String {
        if radio.source == .practice { return "Phone" }
        if radio.session.position?.fixed == true { return "Fixed" }
        if radio.session.position?.gpsMode == .notPresent { return "None" }
        return myPosition ? "On" : "Off"
    }
}

/// The node card: who you are, a plain sentence, and the readouts (the same
/// masthead as the MeshCore status card).
private struct NodeCard: View {
    @Environment(Radio.self) private var radio

    var body: some View {
        let s = radio.session
        let me = s.myNode
        let info = me.flatMap { s.nodes[$0] }
        let others = s.nodes.values.filter { $0.num != me && !$0.isIgnored }
        let direct = others.filter { $0.hopsAway == 0 && !$0.viaMQTT }.count
        let metrics = info?.metrics
        let practice = radio.source == .practice
        let sentence = MeshtasticSummary.sentence(heard: others.count, direct: direct, channelUse: metrics?.channelUtilization,
                                                  needsRegion: s.needsRegion, practice: practice)
        InstrumentPanel {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: MeshNetwork.meshtastic.symbol, tint: Theme.meshtastic, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(info?.longName ?? me.map { s.label(for: $0) } ?? "Your node")
                            .font(.system(.title2, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Tag(roleTitle(s.device?.role.rawValue ?? info?.role))
                    }
                    HStack(spacing: 6) {
                        StatusLED(color: Theme.ok, size: 7)
                        Text(practice ? "Practice · on this phone" : "Connected · BLE")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        if let id = me?.id {
                            Text("·").foregroundStyle(Theme.textQuaternary)
                            Text(id).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                        }
                        if let fw = s.firmware {
                            Text("fw \(fw)").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            (Text(sentence.lead).foregroundStyle(Theme.textSecondary)
             + Text(sentence.emphasis).foregroundStyle(Theme.textPrimary).fontWeight(.semibold)
             + Text(sentence.tail).foregroundStyle(Theme.textSecondary))
                .font(Theme.Fonts.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            PanelDivider()
            ReadoutRow {
                battery(metrics)
                CellDivider()
                channel(metrics)
            }
            PanelDivider()
            ReadoutRow {
                let best = MeshtasticSummary.bestSNR(Array(s.nodes.values), excluding: me)
                ReadoutCell("Best SNR", value: best.map { MeshtasticSummary.number($0) } ?? "—", unit: best == nil ? nil : "dB")
                CellDivider()
                let up = metrics?.uptime.map(MeshtasticSummary.uptime)
                ReadoutCell("Uptime", value: up?.value ?? "—", unit: up?.unit)
                CellDivider()
                ReadoutCell("Heard", value: "\(others.count)", unit: "nodes")
            }
        }
    }

    @ViewBuilder private func battery(_ m: DeviceMetrics?) -> some View {
        if let m, m.isPowered {
            ReadoutCell("Battery", value: m.voltage.map { String(format: "%.2f", $0) } ?? "USB", unit: m.voltage == nil ? nil : "V",
                        size: .large) {
                Text("Plugged in").font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
            }
        } else if let m, m.voltage != nil || m.batteryLevel != nil {
            ReadoutCell("Battery", value: m.voltage.map { String(format: "%.2f", $0) } ?? "\(m.batteryLevel ?? 0)",
                        unit: m.voltage == nil ? "%" : "V", size: .large) {
                if let b = m.batteryLevel {
                    HStack(spacing: 7) {
                        SegmentMeter(value: Double(b) / 100, segments: 10, tint: b <= 20 ? Theme.alert : Theme.ok)
                        Text("\(b)%").font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        } else {
            ReadoutCell("Battery", value: "—", size: .large) {
                Text("No report yet").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func channel(_ m: DeviceMetrics?) -> some View {
        let u = m?.channelUtilization
        return ReadoutCell("Channel use", value: u.map { String(format: "%.1f", $0) } ?? "—", unit: u == nil ? nil : "%",
                           size: .large) {
            HStack(spacing: 7) {
                SegmentMeter(value: min(1, (u ?? 0) / MeshtasticSummary.crowded), segments: 8,
                             tint: (u ?? 0) >= MeshtasticSummary.busy ? Theme.alert : Theme.meshtastic, size: .xs)
                Text(MeshtasticSummary.channelWord(u) + (m?.airUtilTx.map { String(format: " · TX %.1f%%", $0) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(u == nil ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

func roleTitle(_ role: Int?) -> String {
    role.flatMap(DeviceRole.init(rawValue:))?.title ?? "Client"
}

/// "02 RADIO": region, preset, frequency slot, hops, power.
private struct RadioModule: View {
    @Environment(Radio.self) private var radio
    @Binding var route: MeshtasticRoute?

    var body: some View {
        let s = radio.session
        let practice = radio.source == .practice
        ModuleHeader(2, "Radio", action: "What's this?", symbol: "questionmark.circle") { route = .guide("channels") }
        Button {
            if !practice { route = .settings }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    MeshtasticRadioChips(session: s, practice: practice)
                    Text(line(s))
                        .font(Theme.Fonts.detail)
                        .foregroundStyle(s.needsRegion ? Theme.alert : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                // The practice radio has no settings screen, so no disclosure mark.
                if !practice { Chevron() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(.inset)
        }
        .buttonStyle(.rowPress)
        .disabled(practice)
    }

    private func line(_ s: MeshSession) -> String {
        if radio.source == .practice { return "Practice: a pretend radio. Nothing goes on the air." }
        guard let l = s.lora else { return "Reading the node's settings…" }
        if l.region == .unset { return "No region set: this node won't transmit until you pick one." }
        let region = l.region.title.components(separatedBy: " (").first ?? l.region.title
        return "\(region) · every node nearby needs the same region and preset" + (l.txEnabled ? "" : " · transmit is off")
    }
}

/// The node's LoRa settings as mono chips ("915 MHz", "LongFast", "slot 20", "3 hops",
/// "22 dBm"): the chips the MeshCore tab draws for its radio, on the tab and in settings.
struct MeshtasticRadioChips: View {
    let session: MeshSession
    var practice: Bool = false

    var body: some View {
        FlowRow(spacing: 5) {
            ForEach(Array(chips.enumerated()), id: \.offset) { $0.element }
        }
    }

    private var chips: [RadioChip] {
        guard let l = session.lora else { return practice ? [RadioChip("SIM"), RadioChip("No RF")] : [RadioChip("Loading…")] }
        var out: [RadioChip] = []
        if l.region.title.contains("("), let band = l.region.title.split(separator: "(").last?.dropLast() {
            // "915 MHz": the number, then its unit.
            let parts = band.split(separator: " ", maxSplits: 1).map(String.init)
            out.append(RadioChip(parts.first ?? String(band), unit: parts.count > 1 ? parts[1] : nil))
        }
        out.append(RadioChip(l.preset.title.replacingOccurrences(of: " (default)", with: "")))
        if let slot = FrequencySlot.effective(lora: l, primaryName: session.channels[0]?.name ?? "") {
            out.append(RadioChip("\(slot)", lead: "slot"))
        }
        out.append(RadioChip("\(l.hopLimit)", unit: "hops"))
        out.append(RadioChip(l.txPower == 0 ? "max" : "\(l.txPower)", unit: "dBm"))
        return out
    }
}

/// "03 HEARD NEARBY": the most recent few nodes, then all nodes and the map.
private struct HeardModule: View {
    @Environment(Radio.self) private var radio
    @Environment(MyMeshStore.self) private var myMesh
    @Binding var route: MeshtasticRoute?

    var body: some View {
        let s = radio.session
        let nodes = s.nodes.values
            .filter { $0.num != s.myNode && !$0.isIgnored }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
        let shown = Array(nodes.prefix(5))
        ModuleHeader(3, "Heard nearby", detail: "\(nodes.count)")
        if shown.isEmpty {
            EmptyState(symbol: "person.2.wave.2", title: "Nobody heard yet",
                       text: "Nodes appear here as their packets arrive.")
                .panel(.inset)
            FieldGroup { maps }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.num) { i, n in
                    if i > 0 { FieldDivider() }
                    NavRow { NodeDetailView(num: n.num) } label: {
                        HeardRow(node: n, mine: myMesh.contains(OwnedNode.id(.meshtastic, n.num.id)))
                    }
                }
                if nodes.count > shown.count {
                    FieldDivider(inset: 0)
                    Button { route = .nodes } label: {
                        HStack {
                            Text("All \(nodes.count) nodes").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
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
        let placed = radio.session.nodes.values.filter { $0.position != nil && !$0.isIgnored }.count
        Button { route = .map } label: {
            FieldRow(symbol: "map", title: "Map", subtitle: "Tap a node for bearing and distance", detail: "\(placed) placed")
        }
        .buttonStyle(.rowPress)
        FieldDivider()
        BothNetworksMapRow()
    }
}

/// A heard node (AB `.r` with `.sig`, the MeshCore node row's twin): glyph, name and
/// tags, a plain line, and the signal.
struct HeardRow: View {
    let symbol: String
    let name: String
    let role: String?
    var mine: Bool = false
    var favorite: Bool = false
    let line: String
    /// Only for nodes heard directly: SNR is then this link's signal.
    var snr: Double? = nil
    var dim: Bool = false
    /// A router or repeater: its glyph is drawn in amber, as MeshCore's repeaters are in blue.
    var infrastructure: Bool = false
    var chevron: Bool = false
    /// Row padding; off when the caller pads (older list layouts).
    var padded: Bool = true

    init(symbol: String, name: String, role: String?, mine: Bool = false, favorite: Bool = false, line: String,
         snr: Double? = nil, dim: Bool = false, infrastructure: Bool = false, chevron: Bool = false) {
        self.symbol = symbol
        self.name = name
        self.role = role
        self.mine = mine
        self.favorite = favorite
        self.line = line
        self.snr = snr
        self.dim = dim
        self.infrastructure = infrastructure
        self.chevron = chevron
    }

    init(node n: NodeInfo, mine: Bool = false, chevron: Bool = false, now: Date = Date()) {
        let direct = n.hopsAway == 0 && !n.viaMQTT
        let snr = direct ? n.snr.map(Double.init) : nil
        let grade = snr.map { SignalGrade.grade(snr: $0, rssi: nil).word + " signal" }
        self.init(symbol: MeshtasticSummary.symbol(role: n.role, viaMQTT: n.viaMQTT),
                  name: n.longName ?? n.shortName ?? n.num.id,
                  role: n.role.flatMap(DeviceRole.init(rawValue:)).map(\.title), mine: mine, favorite: n.isFavorite,
                  line: [MeshtasticSummary.path(hops: n.hopsAway, viaMQTT: n.viaMQTT), grade,
                         MeshtasticSummary.ago(n.lastHeard, now: now)].compactMap { $0 }.joined(separator: " · "),
                  snr: snr, infrastructure: MeshtasticSummary.isInfrastructure(role: n.role), chevron: chevron)
    }

    init(cached n: MeshtasticCache.Node, now: Date = Date()) {
        self.init(symbol: MeshtasticSummary.symbol(role: n.role, viaMQTT: n.viaMQTT),
                  name: n.longName ?? n.shortName ?? NodeNum(n.num).id,
                  role: n.role.flatMap(DeviceRole.init(rawValue:)).map(\.title),
                  line: [MeshtasticSummary.path(hops: n.hopsAway, viaMQTT: n.viaMQTT),
                         MeshtasticSummary.ago(n.lastHeard, now: now)].compactMap { $0 }.joined(separator: " · "),
                  snr: n.hopsAway == 0 && !n.viaMQTT ? n.snr : nil, dim: true,
                  infrastructure: MeshtasticSummary.isInfrastructure(role: n.role))
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: infrastructure && !dim ? Theme.meshtastic : nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(name)
                        .font(Theme.Fonts.heading)
                        .foregroundStyle(dim ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if favorite {
                        Image(systemName: "star").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            .accessibilityLabel("Favourite")
                    }
                    if let role, role != "Client" { Tag(role) }
                    if mine { Tag("Mine", color: Theme.textTertiary) }
                }
                Text(line)
                    .font(Theme.Fonts.detail)
                    .foregroundStyle(dim ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                SegmentMeter(lit: snr.map { SignalGrade.bars(snr: $0, rssi: nil) } ?? 0, of: 5,
                             tint: dim ? Theme.textTertiary : Theme.meshtastic)
                Text(snr.map(MeshtasticSummary.db) ?? "—")
                    .font(Theme.Fonts.raw)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if chevron { Chevron() }
        }
        .padding(.horizontal, padded ? Theme.Space.rowH : 0)
        .padding(.vertical, padded ? Theme.Space.rowV : 0)
        .frame(minHeight: padded ? 56 : nil)
        .contentShape(Rectangle())
        .opacity(dim ? 0.75 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// "04 CHATS": the node's channels and its direct threads. Each row opens its chat, shows the
/// last line and what's unread, as the MeshCore tab's Chats does. WGHUNT is marked.
private struct ChannelsModule: View {
    @Environment(Radio.self) private var radio
    @Environment(MessageStore.self) private var store
    @Environment(Safety.self) private var safety

    var body: some View {
        let channels = radio.session.channels.values.sorted { $0.index < $1.index }
        let unread = store.totalUnread
        ModuleHeader(4, "Chats", detail: unread > 0 ? "\(unread) new" : "\(channels.count) of 8 channels")
        VStack(alignment: .leading, spacing: 0) {
            if channels.isEmpty {
                Text("No channels yet.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).padding(14)
            }
            ForEach(Array(channels.enumerated()), id: \.element.index) { i, c in
                if i > 0 { FieldDivider() }
                let keyKind = c.settings.map { ChannelSettings(raw: $0).keyKind }
                if let chat = store.conversation(slot: c.index) {
                    NavRow { ConversationView(conversation: chat) } label: {
                        MeshtasticChannelRow(index: c.index, name: c.name, keyKind: keyKind, chevron: true,
                                             last: lastLine(chat), badge: badge(chat))
                    }
                } else {
                    MeshtasticChannelRow(index: c.index, name: c.name, keyKind: keyKind)
                }
            }
            ForEach(store.directThreads, id: \.self) { id in
                let chat = Conversation.direct(id)
                FieldDivider()
                NavRow { ConversationView(conversation: chat) } label: {
                    FieldRow(symbol: "person", title: name(of: id), subtitle: lastLine(chat) ?? "Direct message",
                             detail: badge(chat))
                }
            }
            if radio.session.channelIndex(named: HuntModel.huntChannelName) == nil, !channels.isEmpty {
                Notice(text: ChannelList.missingHuntText).padding(10)
            }
        }
        .panel(.inset)
    }

    private func name(of id: String) -> String {
        guard let n = NodeNum(id: id) else { return id }
        return radio.session.nodes[n]?.longName ?? radio.session.label(for: n)
    }

    private func badge(_ c: Conversation) -> String? {
        let n = store.unread(in: c)
        return n == 0 ? nil : "\(n) new"
    }

    /// The newest message that may be shown (not a blocked sender's), through the word filter.
    private func lastLine(_ c: Conversation) -> String? {
        guard let m = store.last(in: c) else { return nil }
        if m.outgoing { return "You: " + m.text }
        let bridged = BridgeOrigin.parse(m.text)
        let text = safety.shown(bridged?.text ?? m.text)
        if let who = (m.bridged ?? bridged?.origin)?.senderName { return who + ": " + text }
        if case .channel = c { return name(of: m.from) + ": " + text }
        return text
    }
}

/// Channel rows (live or cached): the same rows as the MeshCore tab's chats and channels.
private struct ChannelList: View {
    let channels: [MeshtasticCache.Channel]
    var keyKinds: [Int: String] = [:]
    var missingHunt: Bool
    var dim: Bool

    static let missingHuntText = "No WGHUNT channel on this node. Import the hunt link or QR from your host in Node settings. Until then, moves go out on the primary channel."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if channels.isEmpty {
                Text("No channels yet.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).padding(14)
            }
            ForEach(Array(channels.enumerated()), id: \.element.index) { i, c in
                if i > 0 { FieldDivider() }
                MeshtasticChannelRow(index: c.index, name: c.name, keyKind: keyKinds[c.index], dim: dim)
            }
            if missingHunt && !channels.isEmpty && !dim {
                Notice(text: Self.missingHuntText)
                    .padding(10)
            }
        }
        .panel(.inset)
    }
}

/// A Meshtastic channel as a list row (AB `.r`, as the MeshCore tab lists its chats and
/// channels): glyph, name and tag, what its key means, and its slot.
struct MeshtasticChannelRow: View {
    let index: Int
    let name: String
    /// `ChannelSettings.keyKind` ("default", "private", "none"); nil when unknown (a cached channel).
    var keyKind: String? = nil
    var dim: Bool = false
    var chevron: Bool = false
    /// Row padding; off inside a Form, which pads its rows.
    var padded: Bool = true
    /// What to call a channel with no name.
    var emptyName: String = "Primary"
    /// The chat's last line, shown in place of what the key means.
    var last: String? = nil
    /// "2 new", shown in place of the slot.
    var badge: String? = nil

    private var hunt: Bool { name.uppercased() == HuntModel.huntChannelName }

    private var subtitle: String {
        switch keyKind {
        case "default": return "Default key · public: everyone on Meshtastic"
        case "private": return "Private key · only radios with it can read it"
        case "none": return "No key · sent in the clear"
        default: return hunt ? "Hunt moves travel here" : index == 0 ? "The primary channel" : "A private channel"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: index == 0 ? "globe" : "lock")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(name.isEmpty ? emptyName : name)
                        .font(Theme.Fonts.heading)
                        .foregroundStyle(dim ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if hunt {
                        Chip("Hunt", small: true)
                    } else if index == 0 {
                        Tag("Primary")
                    }
                }
                Text(last ?? subtitle)
                    .font(Theme.Fonts.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(last == nil ? 2 : 1)
            }
            Spacer(minLength: 8)
            Text(badge ?? "slot \(index)")
                .font(Theme.Fonts.dataSmall)
                .foregroundStyle(badge == nil ? Theme.textTertiary : MeshNetwork.meshtastic.color)
                .lineLimit(1)
            if chevron { Chevron() }
        }
        .padding(.horizontal, padded ? Theme.Space.rowH : 0)
        .padding(.vertical, padded ? Theme.Space.rowV : 0)
        .frame(minHeight: padded ? 52 : nil)
        .contentShape(Rectangle())
        .opacity(dim ? 0.75 : 1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Not connected

private struct DisconnectedModules: View {
    @Environment(Radio.self) private var radio
    let cache: MeshtasticCache?

    /// The node being connected to, and whether its settings are already loading.
    private var busy: (name: String, configuring: Bool)? {
        switch radio.link?.state {
        case .connecting(let n)?: return (n, false)
        case .configuring(let n)?: return (n, true)
        default: return nil
        }
    }

    /// Whether the "Found nearby" module shows (it has a number, so Manage's shifts).
    static func showsFound(_ radio: Radio) -> Bool {
        switch radio.link?.state {
        case .connecting?, .configuring?: return false
        default: return !(radio.link?.discovered.isEmpty ?? true)
        }
    }

    private var looking: Bool { radio.link?.state == .scanning || radio.pending.isWaiting }

    var body: some View {
        let link = radio.link
        let found = busy == nil ? (link?.discovered ?? []) : []
        ModuleHeader(1, "This radio", detail: cache == nil ? nil : "last used")
        if let busy {
            InstrumentPanel {
                HStack(spacing: 14) {
                    IconTile(symbol: MeshNetwork.meshtastic.symbol, tint: Theme.meshtastic, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(busy.name).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).tint(Theme.meshtastic)
                            Text(busy.configuring ? "Loading its settings and channels…" : "Connecting over Bluetooth…")
                                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                PanelDivider()
                Text("The first connection may ask for the node's PIN (shown on its screen, or 123456).")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Button("Cancel") { radio.link?.disconnect() }
                .buttonStyle(.field(.quiet, .regular))
                .frame(maxWidth: .infinity)
        } else {
            if let cache { LastNodeCard(cache: cache) }
            FinderCard(hasLast: link?.lastNodeID != nil || cache != nil)
            StatusKeyRow {
                StatusKey("Link", sub: "Off", led: .off)
                StatusKey("Bluetooth", sub: bluetoothWord, led: bluetoothLED)
                StatusKey("Scan", sub: looking ? "On" : "Idle", led: looking ? .network(.meshtastic) : .off) {
                    if !looking { radio.findNode() }
                }
            }
            if !found.isEmpty {
                ModuleHeader(2, "Found nearby", detail: "\(found.count)")
                VStack(spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { FieldDivider() }
                        Button { link?.connect(d.id) } label: { DiscoveredRow(name: d.name, rssi: d.rssi) }
                            .buttonStyle(.rowPress)
                    }
                }
                .panel(.inset)
            }
            Text("Close the Meshtastic app first: a node talks to one phone app at a time. The first connection may ask for the node's PIN.")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let cache {
            let next = found.isEmpty ? 2 : 3
            ModuleHeader(next, "Channels", detail: "last known")
            ChannelList(channels: cache.channels, missingHunt: false, dim: true)
            ModuleHeader(next + 1, "Recently heard", detail: "\(cache.heard.count)")
            VStack(spacing: 0) {
                if cache.heard.isEmpty {
                    Text("Nobody heard last time.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(cache.heard.prefix(5).enumerated()), id: \.element.id) { i, n in
                    if i > 0 { FieldDivider() }
                    HeardRow(cached: n)
                }
            }
            .panel(.inset)
        }
    }

    private var bluetoothWord: String {
        switch radio.link?.state {
        case nil: return "Not used yet"
        case .poweredOff?: return "Off"
        case .unauthorized?: return "Not allowed"
        default: return "On"
        }
    }

    private var bluetoothLED: StatusKey.LED {
        switch radio.link?.state {
        case nil: return .off
        case .poweredOff?, .unauthorized?: return .warn
        default: return .on
        }
    }
}

/// Find a node: the centred hero the MeshCore tab uses, with the finder's buttons inside.
private struct FinderCard: View {
    @Environment(Radio.self) private var radio
    /// A node to reconnect to (the link remembers one, or the cache does).
    let hasLast: Bool

    var body: some View {
        let link = radio.link
        let scanning = link?.state == .scanning
        let looking = scanning || radio.pending.isWaiting
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 1).frame(width: 96, height: 96)
                Circle().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4])).frame(width: 68, height: 68)
                Image(systemName: looking ? "dot.radiowaves.left.and.right" : MeshNetwork.meshtastic.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.meshtastic)
                    .symbolEffect(.variableColor.iterative, isActive: looking)
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(scanning ? "Looking for Meshtastic nodes…" : looking ? "Waiting for Bluetooth…" : "No Meshtastic radio connected")
                    .font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Connect your own Meshtastic node over Bluetooth to chat, hunt and see who it hears. No node yet? Try the practice mesh below.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link, case .failed(let message) = link.state { ToastBanner(text: message, kind: .danger) }
            if link?.state == .poweredOff || link?.state == .unauthorized {
                BluetoothNotice(allowed: link?.state == .poweredOff)
            }
            VStack(spacing: 8) {
                Button {
                    if looking { radio.stopFinding() } else { radio.findNode() }
                } label: {
                    Label(looking ? "Stop" : "Find my node", systemImage: looking ? "stop" : "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.fieldPrimary)
                if hasLast && !looking {
                    Button { radio.reconnectLast() } label: {
                        Label("Reconnect the last one", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.field(.secondary, .regular))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .instrumentPanel()
    }
}

/// A node the scan found (the MeshCore finder's row): glyph, name, how to connect, its signal.
private struct DiscoveredRow: View {
    let name: String
    let rssi: Int

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: MeshNetwork.meshtastic.symbol, tint: Theme.meshtastic)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("Meshtastic · Bluetooth · tap to connect").font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                SegmentMeter(lit: SignalGrade.bars(snr: nil, rssi: rssi), of: 5, tint: Theme.meshtastic)
                Text(MeshtasticSummary.signed(Double(rssi), digits: 0) + " dBm")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .contentShape(Rectangle())
    }
}

/// The node used last time, dimmed, with when it was last connected.
private struct LastNodeCard: View {
    let cache: MeshtasticCache

    var body: some View {
        InstrumentPanel {
            HStack(spacing: 12) {
                IconTile(symbol: MeshNetwork.meshtastic.symbol, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(cache.longName ?? cache.shortName ?? cache.nodeNum.id)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Tag(roleTitle(cache.role))
                    }
                    HStack(spacing: 6) {
                        StatusLED(color: Theme.ok, on: false, size: 6)
                        Text("Not connected · last \(MeshtasticSummary.ago(cache.saved))")
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
                ReadoutCell("Battery", value: cache.batteryVolts.map { String(format: "%.2f", $0) } ?? "—",
                            unit: cache.batteryVolts == nil ? nil : "V", tint: Theme.textSecondary)
                CellDivider()
                ReadoutCell("Heard", value: "\(cache.heard.count)", unit: "nodes", tint: Theme.textSecondary)
                CellDivider()
                ReadoutCell("Channels", value: "\(cache.channels.count)", unit: "of 8", tint: Theme.textSecondary)
            }
            PanelDivider()
            Text([cache.nodeNum.id, cache.hardware, cache.firmware.map { "fw \($0)" },
                  cache.region?.components(separatedBy: " (").first]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.Fonts.raw)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
    }
}

// MARK: - Manage

/// "05 MANAGE": this network's own things (the same skeleton as the MeshCore tab's Manage).
/// App-wide items (Den, guide, safety, about, log) live in the app menu.
private struct ManageModule: View {
    @Environment(Radio.self) private var radio
    let number: Int
    @Binding var route: MeshtasticRoute?

    var body: some View {
        let s = radio.session
        ModuleHeader(number, "Manage")
        FieldGroup {
            MyMeshRow()
            FieldDivider()
            NavRow { SoloHuntSetup() } label: {
                FieldRow(symbol: "scope", title: "Solo hunt", subtitle: "Hunt any node your radio hears, by its signal")
            }
            if radio.isReady {
                // Every node heard, as the MeshCore tab lists its contacts here.
                FieldDivider()
                Button { route = .nodes } label: {
                    FieldRow(symbol: "person.2", title: "Nodes",
                             detail: "\(s.nodes.values.filter { $0.num != s.myNode && !$0.isIgnored }.count)")
                }
                .buttonStyle(.rowPress)
            }
            if !radio.isReady {
                // Connected, it sits under the heard list with this network's map.
                FieldDivider()
                BothNetworksMapRow()
            }
            if radio.isReady && radio.source == .bluetooth {
                FieldDivider()
                Button { route = .settings } label: {
                    FieldRow(symbol: s.needsRegion ? "wand.and.stars" : "slider.horizontal.3",
                             tint: s.needsRegion ? Theme.alert : nil,
                             title: s.needsRegion ? "Set up this node" : "Node settings",
                             subtitle: s.needsRegion ? "No region yet: it won't transmit" : "Name, radio, role, channels")
                }
                .buttonStyle(.rowPress)
            }
            FieldDivider()
            BridgeRow()
            FieldDivider()
            RNodeRow()
        }
    }
}
