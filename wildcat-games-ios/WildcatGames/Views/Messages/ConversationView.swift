import SwiftUI
import WildcatRadioCore

/// A Meshtastic channel or direct conversation (AB 03-chat).
struct ConversationView: View {
    @Environment(MeshBridge.self) private var bridge
    @Environment(MessageStore.self) private var store
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    let conversation: Conversation
    @State private var text = ""
    @State private var replyTo: ChatMessage?
    @State private var failed = false
    @State private var safetyAction: SafetyAction?
    @State private var expanded: UUID?

    static let reactions = ["👍", "❤️", "😂", "😮", "🎉", "🙏"]

    var body: some View {
        let messages = store.messages(in: conversation)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty {
                        EmptyState(symbol: "bubble.left.and.bubble.right", title: "Say hello",
                                   text: "Each message is one radio packet, 200 bytes at most. Short and sweet travels furthest.")
                            .padding(.top, 40)
                    }
                    ForEach(messages) { m in
                        MessageBubble(line: line(m), expanded: expanded == m.id,
                                      onRetry: { retry(m) })
                            .id(m.id)
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contextMenu { menu(m) }
                    }
                }
                .padding(.horizontal, Theme.Space.edge)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                store.markRead(conversation)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ChatStrip(cells: stripCells)
                .padding(.horizontal, Theme.Space.edge)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .background(Theme.bg)
        }
        .screen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if radio.isReady, !channelGone {
                composer
            } else {
                // Saved chats: read-only until a node is back (or has this channel again).
                NeedsRadioNotice(.meshtastic, why: channelGone
                                 ? "This channel isn't on your node any more. Its saved chat stays readable here."
                                 : "These are saved chats\(store.historyLabel.map { " from \($0)" } ?? ""). Connect your Meshtastic node to send.")
                    .padding(.horizontal, Theme.Space.edge)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .safetyPrompts($safetyAction)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitle(title: title, network: .meshtastic, via: radio.isReady ? myName : nil, connected: radio.isReady)
            }
        }
        .onAppear {
            store.open = conversation
            store.markRead(conversation)
        }
        .onDisappear { if store.open == conversation { store.open = nil } }
    }

    @ViewBuilder
    private func menu(_ m: ChatMessage) -> some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left") { replyTo = m }
        Menu("React") {
            ForEach(Self.reactions, id: \.self) { e in Button(e) { store.react(e, to: m) } }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = line(m).text }
        Button(expanded == m.id ? "Hide raw packet" : "Show raw packet", systemImage: "doc.plaintext") {
            withAnimation(Theme.Motion.snappy) { expanded = expanded == m.id ? nil : m.id }
        }
        if m.outgoing, case .failed = m.status {
            Button("Send again", systemImage: "arrow.clockwise") { retry(m) }
        }
        if let f = flagged(m) { SafetyMenuItems(flagged: f, action: $safetyAction) }
    }

    // MARK: Names

    /// The channel on the radio (slot and name), live or as last saved; nil for direct chats.
    private var entry: MessageStore.ChannelEntry? { store.entry(for: conversation) }

    /// The slot this channel sits in on the connected radio (nil: not connected, or not on it).
    private var slot: Int? { store.slot(of: conversation) }

    /// Connected, but this channel isn't on the radio (any more): its saved chat is read-only.
    private var channelGone: Bool {
        guard case .channel = conversation else { return false }
        return radio.isReady && slot == nil
    }

    private var channelName: String {
        guard case .channel = conversation else { return "" }
        if let n = entry?.name, !n.isEmpty { return n }
        if entry?.slot == 0 || entry?.primary == true, radio.isReady, let lora = radio.session.lora {
            return FrequencySlot.presetName(lora.preset, usePreset: lora.usePreset)
        }
        if let s = entry?.slot { return s == 0 ? "Primary" : "Channel \(s)" }
        return entry?.primary == true ? "Primary" : "Channel"
    }

    private var title: String {
        switch conversation {
        case .channel: return "# " + channelName
        case .direct(let id): return name(id)
        }
    }

    private var myName: String? { radio.session.myNode.map { radio.session.label(for: $0) } }

    private func name(_ id: String) -> String {
        guard let n = NodeNum(id: id) else { return id }
        return radio.session.nodes[n]?.longName ?? radio.session.label(for: n)
    }

    private func sender(_ m: ChatMessage) -> String {
        guard let n = NodeNum(id: m.from) else { return m.from }
        if m.outgoing { return "You" }
        return radio.session.nodes[n]?.longName ?? radio.session.label(for: n)
    }

    /// "!a3f9c21e" to its short name; names stay as they are.
    private func nodeLabel(_ s: String?) -> String? {
        guard let s else { return nil }
        guard let n = NodeNum(id: s) else { return s }
        return radio.session.nodes[n] != nil ? radio.session.label(for: n) : s
    }

    // MARK: Message -> line

    private func line(_ m: ChatMessage) -> ChatLine {
        // Lines the bridge posted (ours or anyone's) read as arrivals from the other network.
        let parsed = BridgeOrigin.parse(m.text)
        let origin = m.bridged ?? parsed?.origin
        var l = ChatLine(id: m.id, network: .meshtastic, time: m.time, text: origin != nil ? (parsed?.text ?? m.text) : m.text)
        l.mine = m.outgoing && origin == nil
        l.direct = { if case .direct = conversation { return true } else { return false } }()
        if let origin {
            l.bridged = origin
            l.sender = origin.senderName.isEmpty ? origin.network.title : origin.senderName
            l.senderID = origin.senderID
            l.bridgeVia = nodeLabel(origin.via) ?? (m.outgoing ? myName : nodeLabel(m.from))
        } else if !m.outgoing {
            l.sender = sender(m)
            l.senderID = m.from
        }
        if let q = m.replyTo.flatMap({ store.message(packetID: $0) }) {
            l.quote = ChatLine.Quote(sender: sender(q), text: BridgeOrigin.parse(q.text)?.text ?? q.text)
        }
        l.reactions = m.reactions.keys.sorted().map { ($0, m.reactions[$0]?.count ?? 0) }
        switch m.status {
        case .received: l.status = .received
        case .sending: l.status = .sending
        case .sent: l.status = .sent
        case .delivered: l.status = .delivered
        case .failed(let why): l.status = .failed(why)
        }
        if !m.outgoing {
            l.snr = m.snr
            l.rssi = m.rssi
            l.hops = m.hops
            l.hopStart = m.hopStart
            l.hopLimit = m.hopLimit
            l.relayNode = m.relayNode
            l.viaMQTT = m.viaMQTT
        }
        l.size = m.size
        l.airtimeMs = m.airtimeMs
        l.roundTripMs = m.roundTripMs
        l.kind = "TEXT"
        l.radioName = nodeLabel(m.radio) ?? myName
        l.raw = m.raw
        return l
    }

    // MARK: Readouts

    private var stripCells: [(label: String, value: String)] {
        let s = radio.session
        let preset = s.lora.map { FrequencySlot.presetName($0.preset, usePreset: $0.usePreset) }
        let slot = s.lora.flatMap { FrequencySlot.effective(lora: $0, primaryName: s.channels[0]?.name ?? "") }
        let metrics = s.myNode.flatMap { s.nodes[$0]?.metrics }
        let heard = s.nodes.values.filter { $0.num != s.myNode && ($0.lastHeard.map { Date().timeIntervalSince($0) < 3600 } ?? false) }.count
        let place: String
        switch conversation {
        case .channel: place = (slot ?? entry?.slot).map { "ch \($0)" } ?? "saved"
        case .direct: place = "direct"
        }
        // Only what the node has told us (practice and a half-loaded node know less).
        let cells: [(label: String, value: String?)] = [
            ("Nodes 1h", "\(heard)"),
            ("Chat", place),
            ("Preset", preset),
            ("Slot", slot.map(String.init)),
            ("Ch util", metrics?.channelUtilization.map { ChatMeta.number($0, digits: 1) + "%" }),
        ]
        let known = cells.compactMap { c in c.value.map { (label: c.label, value: $0) } }
        // Four fit; the chat's place goes once the radio settings are known.
        return known.count > 4 ? known.filter { $0.label != "Chat" } : known
    }

    // MARK: Safety

    /// Someone else's message (or a line bridged from the other network) that can be blocked or reported.
    private func flagged(_ m: ChatMessage) -> Flagged? {
        let place: String
        switch conversation {
        case .channel: place = title
        case .direct: place = "direct message"
        }
        if let b = Blocklist.bridgedSender(m.text) {
            return Flagged(sender: .named(b.name, on: b.network, radio: radio, meshcore: meshcore), network: "Meshtastic",
                           place: place, text: MeshBridge.parse(m.text)?.text ?? m.text, time: m.time,
                           bridgedFrom: b.network == .meshtastic ? "Meshtastic" : "MeshCore")
        }
        guard !m.outgoing else { return nil }
        let sender = NodeNum(id: m.from).flatMap { radio.session.nodes[$0] }.map(BlockedSender.node)
            ?? BlockedSender(network: .meshtastic, key: m.from, names: [])
        return Flagged(sender: sender, network: "Meshtastic", place: place, text: m.text, time: m.time)
    }

    // MARK: Sending

    private var airtime: Int? {
        let bytes = MeshCodec.headerSize + MeshCodec.textDataSize(text, replyID: replyTo?.packetID)
        return radio.session.lora?.airtime(bytes: bytes)
    }

    private var bridgeNote: String? {
        guard case .channel = conversation, bridge.enabled, let slot, bridge.meshtasticChannel == slot,
              let mc = bridge.meshcoreChannel else { return nil }
        let name = meshcore.session.channels[mc]?.name ?? "MeshCore"
        return bridge.isLive ? "Also crosses the bridge to MeshCore #\(name)" : "Bridge to MeshCore #\(name) is off"
    }

    private var composer: some View {
        let target: String
        switch conversation {
        case .channel: target = channelName
        case .direct(let id): target = name(id)
        }
        return ChatComposer(network: .meshtastic, target: target, through: myName,
                            direct: { if case .direct = conversation { return true } else { return false } }(),
                            text: $text, limit: 200, airtimeMs: airtime, note: bridgeNote,
                            error: failed ? "Not sent: your Meshtastic node didn't take it. Try again." : nil,
                            reply: replyTo.map { ChatLine.Quote(sender: sender($0), text: line($0).text) },
                            onCancelReply: { replyTo = nil }, canSend: radio.isReady) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if store.send(t, in: conversation, replyTo: replyTo?.packetID) {
                if case .channel = conversation, let slot { bridge.sentFromHere(meshtastic: slot, text: t) }
                Haptics.thud()
                text = ""
                replyTo = nil
                failed = false
            } else {
                Haptics.error()
                failed = true
            }
        }
    }

    private func retry(_ m: ChatMessage) {
        // Not bridged again: the first try already crossed (the bridge doesn't wait for acks).
        if store.retry(m) {
            Haptics.thud()
            failed = false
        } else {
            Haptics.error()
            failed = true
        }
    }
}
