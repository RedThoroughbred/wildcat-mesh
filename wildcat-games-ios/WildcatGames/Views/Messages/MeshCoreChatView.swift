import SwiftUI
import WildcatRadioCore

/// A MeshCore channel or direct conversation (AB 03-chat).
struct MeshCoreChatView: View {
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshBridge.self) private var bridge
    @Environment(MeshCoreStore.self) private var store
    @Environment(Radio.self) private var radio
    let origin: MeshCore.Message.Origin
    @State private var draft = ""
    @State private var safetyAction: SafetyAction?
    @State private var expanded: UUID?

    private var chats: [MeshCoreSession.Chat] { store.visibleChats.filter { $0.origin == origin } }

    private var isChannel: Bool { if case .channel = origin { return true } else { return false } }

    var body: some View {
        let chats = chats
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if chats.isEmpty {
                        EmptyState(symbol: "bubble.left.and.bubble.right", title: "Say hello",
                                   text: "Each message is one radio packet, \(MeshCore.maxTextBytes) bytes at most. Repeaters carry it along the mesh.")
                            .padding(.top, 40)
                    }
                    ForEach(chats) { c in
                        let l = line(c)
                        MessageBubble(line: l, expanded: expanded == c.id,
                                      onRetry: link.state.isReady && !isChannel ? { retry(c) } : nil)
                            .id(c.id)
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = l.text }
                                Button(expanded == c.id ? "Hide raw packet" : "Show raw packet", systemImage: "doc.plaintext") {
                                    withAnimation(Theme.Motion.snappy) { expanded = expanded == c.id ? nil : c.id }
                                }
                                if l.mine {
                                    Button("Send again", systemImage: "arrow.clockwise") {
                                        if l.status.isFailed { retry(c) } else { send(c.text) }
                                    }
                                    .disabled(!link.state.isReady)
                                }
                                if let f = flagged(c) { SafetyMenuItems(flagged: f, action: $safetyAction) }
                            }
                    }
                }
                .padding(.horizontal, Theme.Space.edge)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chats.count) { _, _ in if let last = chats.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            .scrollDismissesKeyboard(.interactively)
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
            if link.state.isReady {
                composer
            } else {
                // Saved chats: read-only until the node is back.
                NeedsRadioNotice(.meshcore, why: "These are saved chats. Connect your MeshCore node to send.")
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
                ChatTitle(title: title, network: .meshcore, via: link.state.isReady ? myName : store.offlineName,
                          connected: link.state.isReady)
            }
        }
        .onAppear { store.openChat = origin; store.markRead(origin); MessageStore.requestNotifications() }
        .onDisappear { if store.openChat == origin { store.openChat = nil }; store.markRead(origin) }
        .onChange(of: chats.count) { _, _ in store.markRead(origin); store.scheduleSave() }
    }

    /// The connected node's session, or the last one's save while disconnected.
    private var session: MeshCoreSession { store.source }

    private var title: String { (isChannel ? "# " : "") + session.label(origin) }

    private var myName: String? { link.state.isReady ? link.session.me?.name : store.offlineName }

    // MARK: Chat -> line

    /// Channel messages carry the sender's name inside the text: "NAME: text".
    private func split(_ c: MeshCoreSession.Chat) -> (sender: String?, text: String) {
        guard let name = c.channelSender, let r = c.text.range(of: ": ") else { return (nil, c.text) }
        return (name, String(c.text[r.upperBound...]))
    }

    private func line(_ c: MeshCoreSession.Chat) -> ChatLine {
        // Lines the bridge posted (ours or anyone's) read as arrivals from the other network.
        let parsed = BridgeOrigin.parse(c.text)
        let bridged = c.bridged ?? parsed?.origin
        let received = c.direction == .received
        var l = ChatLine(id: c.id, network: .meshcore, time: received ? (c.receivedAt ?? c.at) : c.at, text: c.text)
        l.mine = !received && bridged == nil
        l.direct = !isChannel
        if let bridged {
            l.bridged = bridged
            l.text = parsed?.text ?? c.text
            l.sender = bridged.senderName.isEmpty ? bridged.network.title : bridged.senderName
            l.senderID = bridged.senderID
            l.bridgeVia = viaName(bridged.via) ?? (received ? split(c).sender : myName)
        } else if received {
            switch c.origin {
            case .channel:
                let (name, text) = split(c)
                l.sender = name
                l.text = text
                l.senderID = name.flatMap { n in session.contacts.values.first { $0.name == n } }.map { ChatMeta.hex($0.publicKey.prefix(4)) }
            case .contact(let p):
                if let a = c.author, !a.isEmpty, let author = session.author(of: c) {
                    // A room server post: who wrote it (the room only passes it on).
                    l.sender = author
                    l.senderID = ChatMeta.hex(a.prefix(4))
                } else {
                    l.sender = session.label(c.origin)
                    l.senderID = ChatMeta.hex(p.prefix(4))
                }
            }
        }
        if received {
            l.snr = c.snr
            l.rssi = c.rssi
            l.hops = c.hops ?? (c.path.map(\.count))
            l.path = c.path
            l.status = .received
        } else {
            l.flood = c.flood ?? (isChannel ? true : nil)
            l.status = status(c)
        }
        l.size = c.size
        l.airtimeMs = c.airtimeMs
        l.roundTripMs = c.roundTripMs
        l.packetHash = c.packetHash
        l.kind = isChannel ? "GRP_TXT" : "TXT"
        l.radioName = myName
        l.raw = c.raw
        return l
    }

    /// Our own message: repeaters heard (channel), or how delivery stands (direct:
    /// sending, tries, on air, delivered or failed).
    private func status(_ c: MeshCoreSession.Chat) -> ChatLine.Status {
        if isChannel {
            if let n = c.heardBy, n > 0 { return .heardBy(n) }
            return Date().timeIntervalSince(c.at) > MeshCoreEchoWatch.window ? .unheard : .sent
        }
        return ChatMeta.meshcoreDirectStatus(c)
    }

    private func retry(_ c: MeshCoreSession.Chat) {
        if store.retry(c) { Haptics.thud() } else { Haptics.error() }
    }

    /// A MeshCore key prefix in hex to a contact's name; names stay as they are.
    private func viaName(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("!"), let n = NodeNum(id: s) { return radio.session.nodes[n] != nil ? radio.session.label(for: n) : s }
        if s.count >= 8, s.allSatisfy(\.isHexDigit),
           let c = session.contacts.values.first(where: { ChatMeta.hex($0.publicKey).hasPrefix(s.lowercased()) }) {
            return c.name
        }
        return s
    }

    // MARK: Readouts

    private var stripCells: [(label: String, value: String)] {
        let s = session
        let mode: String
        switch origin {
        case .channel: mode = "flood"
        case .contact(let p):
            if let n = s.contact(prefix: p)?.pathLength { mode = n == 0 ? "direct" : "route · \(n)" } else { mode = "flood" }
        }
        return [
            ("Heard", "\(s.heardPackets)"),
            ("Mode", mode),
            ("SF / BW", s.me.map { "\($0.spreadingFactor) / \(ChatMeta.number($0.bandwidth, digits: 2))" } ?? "—"),
            ("MHz", s.me.map { ChatMeta.number($0.frequency, digits: 3) } ?? "—"),
        ]
    }

    // MARK: Safety

    /// Someone else's message (or a line bridged from Meshtastic) that can be blocked or reported.
    private func flagged(_ c: MeshCoreSession.Chat) -> Flagged? {
        let place: String
        switch origin {
        case .channel: place = "#" + session.label(origin)
        case .contact: place = "direct message"
        }
        if let b = Blocklist.bridgedSender(c.text) {
            return Flagged(sender: .named(b.name, on: b.network, radio: radio, meshcore: link), network: "MeshCore", place: place,
                           text: c.text, time: c.at, bridgedFrom: b.network == .meshtastic ? "Meshtastic" : "MeshCore")
        }
        guard c.direction == .received else { return nil }
        let sender: BlockedSender
        switch c.origin {
        case .contact(let p):
            // A room server post is blocked by its author, not the room.
            let who = c.author.flatMap { $0.isEmpty ? nil : $0 } ?? p
            let known = session.contact(prefix: who)
            let name = c.author == nil ? nil : session.author(of: c)
            sender = known.map(BlockedSender.contact)
                ?? BlockedSender(network: .meshcore, key: MeshCoreStore.hex(who),
                                 names: [name].compactMap { $0 }.filter { $0 != MeshCoreStore.hex(who) })
        case .channel:
            guard let name = Blocklist.channelSender(c.text) else { return nil }
            sender = .named(name, on: .meshcore, radio: radio, meshcore: link)
        }
        return Flagged(sender: sender, network: "MeshCore", place: place, text: c.text, time: c.at)
    }

    // MARK: Sending

    private var bridgeNote: String? {
        guard case .channel(let i) = origin, bridge.enabled, bridge.meshcoreChannel == i, let mt = bridge.meshtasticChannel else { return nil }
        let n = radio.session.channels[mt]?.name ?? ""
        let name = n.isEmpty ? "Primary" : n
        return bridge.isLive ? "Also crosses the bridge to Meshtastic #\(name)" : "Bridge to Meshtastic #\(name) is off"
    }

    private var composer: some View {
        let bytes = ChatMeta.meshcoreSize(text: draft, senderName: myName, channel: isChannel)
        return ChatComposer(network: .meshcore, target: link.session.label(origin), through: myName, direct: !isChannel,
                            text: $draft, limit: MeshCore.maxTextBytes, airtimeMs: link.session.airtime(bytes: bytes),
                            note: bridgeNote,
                            canSend: link.state.isReady) {
            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            send(t)
            Haptics.thud()
            draft = ""
        }
    }

    private func send(_ t: String) {
        switch origin {
        case .channel(let i):
            link.send(text: t, channel: i)
            bridge.sentFromHere(meshcore: i, text: t)
        case .contact(let p):
            if let c = link.session.contact(prefix: p) { link.send(text: t, to: c) }
        }
    }
}
