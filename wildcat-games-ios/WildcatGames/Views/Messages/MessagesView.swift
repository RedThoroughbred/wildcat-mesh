import SwiftUI
import WildcatRadioCore

/// Where a row in Messages leads.
enum ChatRoute: Hashable {
    case meshtastic(Conversation)
    case meshcore(MeshCore.Message.Origin)
    /// A Reticulum (beta) conversation, by the other end's LXMF address.
    case reticulum(String)
    case people
}

/// One conversation in the Messages list, whichever network.
struct MessageThread: Identifiable {
    enum Filter: String, CaseIterable, Identifiable {
        case all, meshcore, meshtastic, reticulum, direct
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .meshcore: return "MeshCore"
            case .meshtastic: return "Meshtastic"
            case .reticulum: return "Reticulum"
            case .direct: return "Direct"
            }
        }
        var network: MeshNetwork? { self == .meshcore ? .meshcore : self == .meshtastic ? .meshtastic : nil }
        /// The chip's dot: the network's colour.
        var dot: Color? { self == .reticulum ? ReticulumStyle.color : network?.color }
    }

    struct TagInfo {
        let text: String
        var color: Color = Theme.textSecondary
    }

    let id: String
    let route: ChatRoute
    let network: MeshNetwork
    let title: String
    var tag: TagInfo?
    var symbol = "number"
    /// The glyph takes the network colour (channels); direct messages stay grey.
    var tinted = true
    var direct = false
    /// The last line: who said it (bold) and what.
    var sender: String?
    /// "[MT]" after a bridged sender, in that network's colour.
    var senderNetwork: MeshNetwork?
    var preview: String?
    var mine = false
    var status: ChatLine.Status = .received
    var time: Date?
    var unread = 0
    /// Signal of the last message heard (0-5 bars).
    var bars = 0
    var raw: String?

    /// The threads a chip and a search leave showing.
    static func filtered(_ threads: [MessageThread], by filter: Filter, query: String) -> [MessageThread] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return threads.filter { t in
            switch filter {
            case .all: break
            case .direct: if !t.direct { return false }
            case .meshcore, .meshtastic: if t.network != filter.network { return false }
            case .reticulum: return false
            }
            guard !q.isEmpty else { return true }
            return [t.title, t.sender, t.preview].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    /// The Reticulum conversations a chip and a search leave showing. They are all person to person, so
    /// Direct keeps them. `title` and `text` are what the row shows (after the word filter).
    static func filtered(_ conversations: [Reticulum.Conversation], by filter: Filter, query: String,
                         title: (Reticulum.Conversation) -> String,
                         text: (Reticulum.Conversation) -> String) -> [Reticulum.Conversation] {
        guard filter == .all || filter == .reticulum || filter == .direct else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return conversations }
        return conversations.filter { title($0).lowercased().contains(q) || text($0).lowercased().contains(q) }
    }
}

/// Chats on both networks, grouped by the radio they travel through (AB 02-messages).
struct MessagesView: View {
    @Environment(MessageStore.self) private var store
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MeshCoreStore.self) private var mcStore
    @Environment(MeshBridge.self) private var bridge
    @Environment(MyMeshStore.self) private var myMesh
    @Environment(Safety.self) private var safety
    @State private var pickRecipient = false
    @State private var path: [ChatRoute] = []
    @State private var query = ""
    @State private var filter: MessageThread.Filter = .all
    @AppStorage("messages.networkHintDismissed") private var hintDismissed = false
    #if DEBUG
    @State private var showSamples = false
    #endif

    /// A network's chats and the radio they go through.
    private struct RadioGroup: Identifiable {
        let network: MeshNetwork
        var via: String?
        var connected: Bool
        var lastSeen: Date?
        var bars = 0
        var signal: String?
        var threads: [MessageThread]
        var note: String?
        /// Other radios of this network with saved chats (shown while disconnected).
        var others: [(node: String, name: String?)] = []
        var id: MeshNetwork { network }
    }
    @State private var showOtherRadios = false

    var body: some View {
        NavigationStack(path: $path) {
            let groups = self.groups
            let all = groups.flatMap(\.threads)
            let reticulum = ReticulumModel.shared
            let rnsAll = reticulum.conversations
            let rns = MessageThread.filtered(rnsAll, by: filter, query: query,
                                             title: { reticulum.title(for: $0.peer) }, text: { reticulum.shown($0.last) })
            let nothing = groups.isEmpty && rnsAll.isEmpty
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !nothing {
                        HStack(spacing: 8) {
                            search
                            newMessage
                        }
                        .padding(.horizontal, Theme.Space.edge)
                        chips(total: all.count + rnsAll.count)
                            .padding(.top, 10)
                    }
                    if !hintDismissed && !nothing {
                        hint
                            .padding(.horizontal, Theme.Space.edge)
                            .padding(.top, 10)
                    }
                    if nothing {
                        Notice(text: "Connect your node on the Meshtastic or MeshCore tab to send and receive. No radio yet? Try Practice on the Play tab.",
                               symbol: "antenna.radiowaves.left.and.right")
                            .padding(.horizontal, Theme.Space.edge)
                            .padding(.top, 14)
                    }
                    ForEach(groups) { g in
                        let shown = MessageThread.filtered(g.threads, by: filter, query: query)
                        if filter != .reticulum, filter.network == nil || filter.network == g.network, !shown.isEmpty || (query.isEmpty && filter != .direct) {
                            header(g)
                            if let note = g.note, query.isEmpty {
                                Text(note).font(.footnote).foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, Theme.Space.edge).padding(.bottom, 8)
                            }
                            if !g.others.isEmpty, query.isEmpty { otherRadios(g.others) }
                            ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 60) }
                                NavigationLink(value: t.route) { ThreadRow(thread: t) }
                                    .buttonStyle(.rowPress)
                            }
                        }
                    }
                    if !rns.isEmpty || (filter == .reticulum && query.isEmpty && !rnsAll.isEmpty) {
                        reticulumHeader(reticulum)
                        ForEach(Array(rns.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 60) }
                            NavigationLink(value: ChatRoute.reticulum(c.peer)) {
                                ReticulumConversationRow(conversation: c, model: reticulum)
                            }
                            .buttonStyle(.rowPress)
                        }
                    }
                    if !nothing, MessageThread.filtered(all, by: filter, query: query).isEmpty, rns.isEmpty {
                        Text(query.isEmpty ? "No \(filter == .direct ? "direct" : filter.title) chats yet." : "Nothing matches \u{201C}\(query)\u{201D}.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .screen()
            .navigationTitle("Messages")
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .meshtastic(let c): ConversationView(conversation: c)
                case .meshcore(let o): MeshCoreChatView(origin: o)
                case .reticulum(let peer): ReticulumChatView(peer: peer, model: ReticulumModel.shared)
                case .people: PeopleView()
                }
            }
            .toolbar {
                // The same toolbar as every tab (pill, guide, menu); New message sits by the search.
                TabToolbar(guide: "messages")
            }
            .sheet(isPresented: $pickRecipient) {
                RecipientPicker { route in
                    pickRecipient = false
                    path = [route]
                }
            }
            #if DEBUG
            // Developer-only: launch with -ChatSamples to see every bubble state without radios.
            .sheet(isPresented: $showSamples) { NavigationStack { ChatSamplesView() } }
            .onAppear { if ProcessInfo.processInfo.arguments.contains("-ChatSamples") { showSamples = true } }
            #endif
        }
    }

    // MARK: Top

    private var newMessage: some View {
        let can = radio.isReady || meshcore.state.isReady
        return Button { pickRecipient = true } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(can ? Theme.textPrimary : Theme.textQuaternary)
                .frame(width: 38, height: 38)
                .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.rowPress)
        .disabled(!can)
        .accessibilityLabel("New message")
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.textTertiary)
            TextField("", text: $query, prompt: Text("Search chats").foregroundStyle(Theme.textTertiary))
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func chips(total: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MessageThread.Filter.allCases) { f in
                    FilterChip(title: f.title, count: f == .all ? total : nil, dot: f.dot, on: filter == f) {
                        withAnimation(Theme.Motion.snappy) { filter = f }
                    }
                }
                NavigationLink(value: ChatRoute.people) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.2").font(.system(size: 12))
                        Text("People")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(.rowPress)
                .accessibilityHint("Everyone on Meshtastic and MeshCore")
            }
            .padding(.horizontal, Theme.Space.edge)
        }
    }

    private var hint: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(Theme.textTertiary).padding(.top, 1)
            (Text("Chats are grouped by the radio they travel through. ")
             + Text("Blue").foregroundStyle(Theme.meshcore) + Text(" is MeshCore, ")
             + Text("amber").foregroundStyle(Theme.meshtastic) + Text(" is Meshtastic, ")
             + Text("purple").foregroundStyle(ReticulumStyle.color) + Text(" is Reticulum."))
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { withAnimation(Theme.Motion.snappy) { hintDismissed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss hint")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    private func header(_ g: RadioGroup) -> some View {
        HStack(spacing: 8) {
            NetworkTag(g.network, via: g.via, style: .header, connected: g.connected)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if g.connected {
                    if g.bars > 0 { SegmentMeter(lit: g.bars, of: 5, tint: g.network.color, size: .xs) }
                    if let s = g.signal { Text(s) }
                } else {
                    Text(g.lastSeen.map { "NOT CONNECTED · " + PacketTicker.age($0, now: Date()) } ?? "NOT CONNECTED")
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Reticulum (beta) conversations: the same header shape as a radio's, in Reticulum's colour.
    private func reticulumHeader(_ model: ReticulumModel) -> some View {
        let on = model.phase == .running && model.anyLinkOnline
        return HStack(spacing: 8) {
            StatusLED(color: ReticulumStyle.color, on: on, size: 8)
            Text("RETICULUM")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(on ? ReticulumStyle.color : Theme.textTertiary)
                .fixedSize()
            Tag("beta")
            Spacer(minLength: 8)
            Text(on ? "ON AIR" : "NOT RUNNING")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reticulum, beta, \(on ? "on air" : "not running")")
        .accessibilityAddTraits(.isHeader)
    }

    /// Earlier radios' saved chats, one line each; tapping one shows it (read-only).
    private func otherRadios(_ others: [(node: String, name: String?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Theme.Motion.snappy) { showOtherRadios.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showOtherRadios ? 90 : 0))
                    Text("Other radios (\(others.count))")
                }
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Other radios, \(others.count)")
            .accessibilityAddTraits(showOtherRadios ? .isSelected : [])
            if showOtherRadios {
                ForEach(others, id: \.node) { o in
                    Button { store.show(saved: o.node) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 12))
                            Text(o.name ?? (o.node == MeshtasticHistory.unknownNode ? "Earlier radio" : o.node)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("Saved chats").font(.caption)
                        }
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 15)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.bottom, 8)
    }

    // MARK: Groups

    /// Connected radios first (MeshCore, then Meshtastic), then ones seen before.
    private var groups: [RadioGroup] {
        let list = [meshcoreGroup, meshtasticGroup].compactMap { $0 }
        return list.filter(\.connected) + list.filter { !$0.connected }
    }

    /// The last node of this network that was connected to this phone.
    private func lastConnected(_ n: OwnedNode.Network) -> OwnedNode? {
        myMesh.saved.filter { $0.network == n && $0.lastConnected != nil }.max { $0.lastConnected! < $1.lastConnected! }
    }

    private var meshcoreGroup: RadioGroup? {
        let connected = meshcore.state.isReady
        let saved = lastConnected(.meshcore)
        guard connected || mcStore.isOffline || saved != nil else { return nil }
        // Connected: the node's channels and chats. Not connected: the last node's saved ones.
        let s = mcStore.source
        var threads: [MessageThread] = []
        if connected || mcStore.isOffline {
            var channels = Set(s.channels.keys)
            if !connected {
                // Saved chats on a channel whose name wasn't kept still get a row.
                for c in mcStore.visibleChats { if case .channel(let i) = c.origin { channels.insert(i) } }
            }
            for i in channels.sorted() { threads.append(meshcoreThread(.channel(i))) }
            for o in mcStore.directs { threads.append(meshcoreThread(o)) }
        }
        guard connected else {
            return RadioGroup(network: .meshcore, via: mcStore.offlineName ?? saved?.name, connected: false,
                              lastSeen: saved?.lastConnected, threads: threads,
                              note: threads.isEmpty ? "Connect your MeshCore node to see its chats."
                                  : "Saved chats, read-only. Connect your MeshCore node to send.")
        }
        let last = mcStore.visibleChats.last { $0.direction == .received && ($0.rssi != nil || $0.snr != nil) }
        return RadioGroup(network: .meshcore, via: s.me?.name ?? "MeshCore node", connected: true,
                     bars: last.map { SignalGrade.bars(snr: $0.snr, rssi: $0.rssi) } ?? 0,
                     signal: last.flatMap { c in c.rssi.map(ChatMeta.dBm) ?? c.snr.map { "SNR " + ChatMeta.number($0) + " dB" } },
                     threads: threads)
    }

    private func meshcoreThread(_ o: MeshCore.Message.Origin) -> MessageThread {
        let s = mcStore.source
        let last = mcStore.visibleChats.last { $0.origin == o }
        var t = MessageThread(id: "mc:" + MeshCoreStore.key(o), route: .meshcore(o), network: .meshcore, title: s.label(o))
        t.unread = mcStore.unread(o)
        switch o {
        case .channel(let i):
            if HuntModel.huntChannelName == s.channels[i]?.name.uppercased() { t.symbol = "scope" }
            if bridge.enabled, bridge.meshcoreChannel == i, let mt = bridge.meshtasticChannel {
                t.symbol = "arrow.left.arrow.right"
                t.tag = .init(text: "⇄ " + meshtasticName(mt), color: Theme.meshtastic)
            }
        case .contact:
            t.direct = true
            t.tinted = false
            t.symbol = "person"
            t.tag = .init(text: "DM")
        }
        guard let last else { t.preview = "No messages yet"; return t }
        t.time = last.receivedAt ?? last.at
        let origin = last.bridged ?? BridgeOrigin.parse(last.text)?.origin
        if let origin {
            t.sender = origin.senderName
            t.senderNetwork = origin.network == .meshtastic ? .meshtastic : .meshcore
            t.preview = BridgeOrigin.parse(last.text)?.text ?? last.text
        } else if last.direction == .sent {
            t.mine = true
            t.sender = "You"
            t.preview = last.text
            if case .channel = o {
                t.status = (last.heardBy ?? 0) > 0 ? .heardBy(last.heardBy ?? 0) : .sent
            } else {
                t.status = ChatMeta.meshcoreDirectStatus(last)
            }
        } else if let name = last.channelSender, let r = last.text.range(of: ": ") {
            t.sender = name
            t.preview = safety.shown(String(last.text[r.upperBound...]))
        } else if let author = s.author(of: last) {
            // A room server post: who wrote it.
            t.sender = author
            t.preview = safety.shown(last.text)
        } else {
            t.preview = safety.shown(last.text)
        }
        // The raw line: channel, hops, signal of the last message heard.
        var parts: [String] = []
        if case .channel(let i) = o { parts.append("ch \(i)") } else { parts.append(last.direction == .sent ? (last.flood == false ? "direct route" : "flood") : "direct") }
        if bridge.enabled, bridge.meshcoreChannel.map({ o == .channel($0) }) == true {
            parts = [bridge.isLive ? "bridged both ways · \(radioName ?? "Meshtastic") ⇄ \(s.me?.name ?? "MeshCore")" : "bridge off"]
        } else if last.direction == .received {
            if let h = last.hops ?? last.path?.count { parts.append(ChatMeta.hops(h)) }
            if let snr = last.snr { parts.append("SNR \(ChatMeta.number(snr)) dB") }
            t.bars = SignalGrade.bars(snr: last.snr, rssi: last.rssi)
        } else if let rt = last.roundTripMs, last.confirmed {
            parts.append("delivered \(ChatMeta.duration(ms: rt))")
        } else if case .contact = o {
            // How a direct message is doing (the glyph after the preview says it too).
            switch ChatMeta.meshcoreDirectStatus(last) {
            case .retrying(let n): parts.append("sending · try \(n)")
            case .awaiting(let n, _) where n > 1: parts.append("try \(n)")
            case .undelivered: parts.append("not delivered")
            default: break
            }
        } else if let n = last.heardBy, n > 0 {
            parts.append("heard by \(n)")
        }
        t.raw = parts.joined(separator: " · ")
        return t
    }

    private var radioName: String? { radio.session.myNode.map { radio.session.label(for: $0) } }

    private func meshtasticName(_ i: Int) -> String {
        let n = radio.session.channels[i]?.name ?? ""
        if !n.isEmpty { return n }
        if i == 0, let lora = radio.session.lora { return FrequencySlot.presetName(lora.preset, usePreset: lora.usePreset) }
        return i == 0 ? "Primary" : "Channel \(i)"
    }

    /// Connected: the radio's channels and chats. Not connected: the last radio's saved
    /// ones, read-only, with that radio named (each radio keeps its own history).
    private var meshtasticGroup: RadioGroup? {
        let saved = lastConnected(.meshtastic)
        guard radio.isReady || store.historyNode != nil || saved != nil else { return nil }
        var threads = store.channelEntries.map { meshtasticThread($0.conversation) }
        threads += store.directThreads.map { meshtasticThread(.direct($0)) }
        let last = store.messages.last { !$0.outgoing && ($0.rssi != nil || $0.snr != nil) && !store.isHidden($0) }
        let bars = radio.isReady ? last.map { SignalGrade.bars(snr: $0.snr, rssi: $0.rssi) } ?? 0 : 0
        let label = store.historyLabel ?? saved?.shortName ?? saved?.name
        let note: String?
        if radio.isReady {
            note = nil
        } else if threads.isEmpty {
            note = "Connect your Meshtastic node to see its chats."
        } else {
            note = "Saved chats · \(label ?? "Meshtastic"), read-only. Connect your Meshtastic node to send."
        }
        return RadioGroup(network: .meshtastic, via: radio.isReady ? radioName : label,
                     connected: radio.isReady, lastSeen: radio.isReady ? nil : saved?.lastConnected,
                     bars: bars, signal: last.flatMap { m in m.rssi.map(ChatMeta.dBm) ?? m.snr.map { "SNR " + ChatMeta.number($0) + " dB" } },
                     threads: threads, note: note, others: radio.isReady ? [] : store.otherHistories)
    }

    /// A channel's name for a row or title: its name, the preset for an unnamed primary, else its slot.
    private func meshtasticName(_ e: MessageStore.ChannelEntry?) -> String {
        if let n = e?.name, !n.isEmpty { return n }
        if e?.slot == 0 || e?.primary == true, let lora = radio.session.lora, radio.isReady {
            return FrequencySlot.presetName(lora.preset, usePreset: lora.usePreset)
        }
        if let slot = e?.slot { return slot == 0 ? "Primary" : "Channel \(slot)" }
        return e?.primary == true ? "Primary" : "Channel"
    }

    private func meshtasticThread(_ c: Conversation) -> MessageThread {
        var t: MessageThread
        let entry = store.entry(for: c)
        switch c {
        case .channel:
            t = MessageThread(id: "mt:" + c.key, route: .meshtastic(c), network: .meshtastic, title: meshtasticName(entry))
            if entry?.primary == true { t.tag = .init(text: "Primary") }
            if entry?.name.uppercased() == HuntModel.huntChannelName { t.symbol = "scope" }
            if bridge.enabled, let slot = entry?.slot, bridge.meshtasticChannel == slot, let mc = bridge.meshcoreChannel {
                t.symbol = "arrow.left.arrow.right"
                t.tag = .init(text: "⇄ " + (meshcore.session.channels[mc]?.name ?? "MeshCore"), color: Theme.meshcore)
            }
            // Saved chat on a channel the connected radio doesn't have (any more).
            if store.isLive, entry?.slot == nil { t.tag = .init(text: "Not on node") }
        case .direct(let id):
            let n = NodeNum(id: id)
            let title = n.flatMap { radio.session.nodes[$0]?.longName } ?? n.map { radio.session.label(for: $0) } ?? id
            t = MessageThread(id: "mt:" + c.key, route: .meshtastic(c), network: .meshtastic, title: title)
            t.direct = true
            t.tinted = false
            t.symbol = "person"
            t.tag = .init(text: "DM")
        }
        t.unread = store.unread(in: c)
        guard let last = store.last(in: c) else { t.preview = "No messages yet"; return t }
        t.time = last.time
        let origin = last.bridged ?? BridgeOrigin.parse(last.text)?.origin
        if let origin {
            t.sender = origin.senderName
            t.senderNetwork = origin.network == .meshtastic ? .meshtastic : .meshcore
            t.preview = safety.shown(BridgeOrigin.parse(last.text)?.text ?? last.text)
        } else if last.outgoing {
            t.mine = true
            t.sender = "You"
            t.preview = last.text
            switch last.status {
            case .sending: t.status = .sending
            case .sent: t.status = .sent
            case .delivered: t.status = .delivered
            case .failed(let w): t.status = .failed(w)
            case .received: t.status = .received
            }
        } else {
            if case .channel = c, let n = NodeNum(id: last.from) {
                t.sender = radio.session.nodes[n]?.longName ?? radio.session.label(for: n)
            }
            t.preview = safety.shown(last.text)
        }
        var parts: [String] = []
        if case .channel = c { parts.append(entry?.slot.map { "ch \($0)" } ?? "saved") } else { parts.append("direct") }
        if bridge.enabled, case .channel = c, let slot = entry?.slot, bridge.meshtasticChannel == slot {
            parts = [bridge.isLive ? "bridged both ways · \(radioName ?? "Meshtastic") ⇄ \(meshcore.session.me?.name ?? "MeshCore")" : "bridge off"]
        } else if !last.outgoing {
            if let h = last.hops { parts.append(ChatMeta.hops(h)) }
            if last.viaMQTT { parts.append("MQTT") } else if let snr = last.snr { parts.append("SNR \(ChatMeta.number(snr)) dB") }
            t.bars = SignalGrade.bars(snr: last.snr, rssi: last.rssi)
        } else if last.status == .delivered, let rt = last.roundTripMs {
            parts.append("delivered \(ChatMeta.duration(ms: rt))")
        } else if case .failed = last.status {
            parts.append("not sent")
        }
        t.raw = parts.joined(separator: " · ")
        return t
    }
}

// MARK: - Rows

/// A filter chip (AB `.f`): white when on, outlined otherwise, with a network dot or a count.
private struct FilterChip: View {
    let title: String
    var count: Int?
    var dot: Color?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title).fontWeight(on ? .semibold : .regular)
                if let count {
                    Text("\(count)").font(.system(size: 11, design: .monospaced)).opacity(0.6)
                }
            }
            .font(.footnote)
            .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(on ? Theme.accent : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Theme.accent : Theme.hairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One conversation in the list: glyph, title and tag, time, last line with
/// unread badge, and the raw line (channel, hops, SNR) under it.
private struct ThreadRow: View {
    let thread: MessageThread

    private var color: Color { thread.network.color }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: thread.symbol, tint: thread.tinted ? color : nil, size: 32)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(thread.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let tag = thread.tag { Tag(tag.text, color: tag.color) }
                    Spacer(minLength: 6)
                    if let time = thread.time {
                        Text(time, format: Calendar.current.isDateInToday(time) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    preview
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if thread.unread > 0 {
                        Text("\(thread.unread)")
                            .font(.system(.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(thread.network == .meshcore ? Color(hex: 0x001428) : Color(hex: 0x241800))
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(color, in: Capsule())
                    } else if thread.mine {
                        StatusGlyph(status: thread.status)
                    }
                }
                if let raw = thread.raw, !raw.isEmpty {
                    HStack(spacing: 5) {
                        if thread.bars > 0 { SegmentMeter(lit: thread.bars, of: 5, tint: color, size: .xs) }
                        Text(raw).lineLimit(1)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, 11)
        .overlay(alignment: .leading) {
            if thread.unread > 0 {
                UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2).fill(color)
                    .frame(width: 2)
                    .padding(.vertical, 14)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.title), \(thread.network.name)\(thread.direct ? ", direct" : "")\(thread.unread > 0 ? ", \(thread.unread) unread" : "")")
    }

    private var preview: Text {
        guard let text = thread.preview else { return Text("") }
        guard let sender = thread.sender, !sender.isEmpty else { return Text(text) }
        var t = Text(sender).foregroundStyle(Theme.textPrimary).fontWeight(.medium)
        if let n = thread.senderNetwork { t = t + Text(" [\(n.short)]").foregroundStyle(n.color) }
        return t + Text(": ") + Text(text)
    }
}

// MARK: - New message

/// Pick someone to message on either network, searchable.
private struct RecipientPicker: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(Safety.self) private var safety
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onPick: (ChatRoute) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.stack) {
                    if nodes.isEmpty && contacts.isEmpty {
                        EmptyState(symbol: "person.2.wave.2", title: "Nobody to message",
                                   text: query.isEmpty ? "Your nodes haven't heard anyone yet." : "Nothing matches \(query).")
                            .panel()
                    }
                    if !contacts.isEmpty {
                        NetworkTag(.meshcore, via: meshcore.session.me?.name, style: .header).padding(.top, 4)
                        FieldGroup {
                            ForEach(Array(contacts.enumerated()), id: \.element.publicKey) { i, c in
                                if i > 0 { FieldDivider(inset: 56) }
                                Button { onPick(.meshcore(.contact(c.prefix))) } label: {
                                    FieldRow(symbol: "person", title: c.name, detail: ChatMeta.hex(c.publicKey.prefix(4)), chevron: false)
                                }
                                .buttonStyle(.rowPress)
                            }
                        }
                    }
                    if !nodes.isEmpty {
                        NetworkTag(.meshtastic, via: radio.session.myNode.map { radio.session.label(for: $0) }, style: .header).padding(.top, 4)
                        FieldGroup {
                            ForEach(Array(nodes.enumerated()), id: \.element.num) { i, n in
                                if i > 0 { FieldDivider(inset: 56) }
                                Button { onPick(.meshtastic(.direct(n.num.id))) } label: {
                                    FieldRow(symbol: "person", title: n.longName ?? n.num.id, subtitle: n.shortName,
                                             detail: n.num.id, chevron: false)
                                }
                                .buttonStyle(.rowPress)
                            }
                        }
                    }
                }
                .padding(Theme.Space.edge)
            }
            .screen()
            .searchable(text: $query)
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
    }

    private func matches(_ names: [String?]) -> Bool {
        query.isEmpty || names.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var nodes: [NodeInfo] {
        guard radio.isReady else { return [] }
        return radio.session.nodes.values
            .filter { $0.num != radio.session.myNode && !safety.hides(meshtasticNode: $0.num.id) }
            .filter { matches([$0.shortName, $0.longName, $0.num.id]) }
            .sorted { ($0.longName ?? $0.num.id) < ($1.longName ?? $1.num.id) }
    }

    private var contacts: [MeshCore.Contact] {
        guard meshcore.state.isReady else { return [] }
        return meshcore.session.contacts.values
            .filter { $0.kind == .chat && !safety.hides($0) && matches([$0.name]) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
