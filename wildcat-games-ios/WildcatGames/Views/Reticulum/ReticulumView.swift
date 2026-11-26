import SwiftUI
import WildcatRadioCore

/// Reticulum (beta), the third network: this phone's address, starting and stopping the stack
/// on the RNode, conversations, and the people heard announcing. Same skeleton as the network
/// tabs: This phone, Radio, Conversations, People heard, then what the beta can't do yet.
struct ReticulumView: View {
    @Environment(RNodeLink.self) private var link
    @Environment(Safety.self) private var safety
    @Environment(\.tabRouter) private var router
    @Environment(\.openURL) private var openURL
    @Bindable var model: ReticulumModel = .shared
    @State private var copied = false
    @State private var showCompose = false
    @State private var showLimits = false
    @State private var confirmStop = false
    @State private var chat: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                thisPhone
                radioModule
                conversations
                people
                Button { router?.showRNode() } label: {
                    FieldRow(symbol: RNodeStyle.symbol, title: "RNode console",
                             subtitle: "The modem itself: what it is, its radio, signal and what it hears")
                }
                .buttonStyle(.rowPress)
                .panel(.inset)
                beta
                #if DEBUG
                ReticulumDeveloperPanel(model: model)
                #endif
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: model.phase)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: ReticulumStyle.symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(ReticulumStyle.color)
                Text("Reticulum")
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Tag("beta", color: ReticulumStyle.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.bottom, 8)
            .background(Theme.bg.ignoresSafeArea(edges: .top))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .screen()
        .navigationTitle("Reticulum (beta)")
        .navigationBarTitleDisplayMode(.inline)
        .hidesNavigationTitle()
        .toolbar { TabToolbar(guide: "reticulum") }
        .tint(ReticulumStyle.color)
        .navigationDestination(item: $chat) { ReticulumChatView(peer: $0, model: model) }
        .sheet(isPresented: $showCompose) {
            ReticulumComposeSheet { chat = $0 }
        }
        .confirmationDialog("Stop Reticulum?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { model.stop() }
        } message: {
            Text("The RNode's radio turns off and the RNode console gets it back. Messages still on their way are marked not delivered. Start again any time.")
        }
        .onAppear {
            model.safety = safety
            if let c = model.sampleChat { chat = c }
        }
    }

    // MARK: This phone

    private var thisPhone: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRunning {
                ModuleHeader(1, "This phone", action: "Stop", symbol: "stop.fill") { confirmStop = true }
                    .accessibilityIdentifier("reticulum.stop")
            } else {
                ModuleHeader(1, "This phone")
            }
            InstrumentPanel {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        IconTile(symbol: ReticulumStyle.symbol, tint: model.isRunning ? ReticulumStyle.color : nil, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                StatusLED(color: model.isRunning ? (model.anyLinkOnline ? Theme.ok : Theme.warn) : Theme.textQuaternary,
                                          on: model.phase != .idle, size: 8)
                                Text(statusWord).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .accessibilityIdentifier("reticulum.phase")
                                if model.phase.isBusy { ProgressView().controlSize(.small).tint(ReticulumStyle.color) }
                            }
                            Text(statusLine).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    if let address = model.address {
                        PanelDivider()
                        Button {
                            UIPasteboard.general.string = address
                            copied = true
                            Haptics.tick()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    CardLabel("Your address")
                                    Text("<\(address)>")
                                        .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                        .accessibilityIdentifier("reticulum.address")
                                }
                                Spacer(minLength: 6)
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(Theme.Fonts.footnote).foregroundStyle(copied ? Theme.ok : Theme.textTertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Copies your Reticulum address")
                    }
                }
            }
            if model.isRunning {
                StatusKeyRow {
                    if model.radio != nil {
                        StatusKey("Radio", sub: model.radioOnline ? "Up" : "Down", led: model.radioOnline ? .on : .warn)
                    }
                    if model.internet != nil {
                        StatusKey("Internet", sub: model.internetOnline ? "Up" : "Down", led: model.internetOnline ? .on : .warn)
                    }
                    StatusKey("Announce", sub: announceWord, symbol: "dot.radiowaves.left.and.right", primary: true) {
                        model.announce()
                        Haptics.tick()
                    }
                    StatusKey("Heard", sub: "\(model.heard.count)", led: model.heard.isEmpty ? .off : .custom(ReticulumStyle.color))
                }
                Text("Announce tells everyone your links reach your address and name, so they can write to you and their replies find a path. On the radio it is one short packet.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusWord: String {
        switch model.phase {
        case .running:
            if model.radioOnline { return "On air" }
            if model.internetOnline { return "Online" }
            return model.radio != nil ? "Radio coming up…" : "Connecting…"
        case .idle: return "Off"
        default: return model.phase.word
        }
    }

    private var statusLine: String {
        switch model.phase {
        case .running:
            let name = model.announcedName ?? model.displayName
            let ways = [model.radio != nil ? rnodeName : nil, model.internet != nil ? "the internet link" : nil].compactMap { $0 }
            return "As “\(name)” through \(ways.joined(separator: " and "))."
        case .launching, .starting:
            return "The Reticulum stack takes a few seconds to start."
        case .stopped:
            return "Stopped. Your address and conversations are kept."
        case .idle:
            return model.address == nil && model.conversations.isEmpty
                ? "Encrypted messages through an RNode or an internet link, with Sideband, MeshChat and other LXMF apps."
                : "Not running. Your conversations are kept."
        }
    }

    private var rnodeName: String {
        if case .ready(let n) = link.state { return n }
        return link.lastNodeName ?? "the RNode"
    }

    private var announceWord: String {
        guard let at = model.lastAnnounce else { return "Tap to send" }
        return "Sent " + at.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Radio and start

    @ViewBuilder private var radioModule: some View {
        if !model.isRunning {
            ModuleHeader(2, "Links", detail: "how Reticulum reaches people")
            rnodeCard
            internetCard
            startCard
        } else {
            ModuleHeader(2, "Links")
            if let radio = model.radio {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel("Radio · \(rnodeName)")
                    RadioChips(frequency: Double(radio.frequencyHz) / 1e6, bandwidth: Double(radio.bandwidthHz) / 1e3,
                               spreadingFactor: radio.spreadingFactor, codingRate: radio.codingRate, txPower: radio.txPower)
                    Text(model.radioOnline ? "Reticulum is driving the RNode. Stop it to change the radio or use the console."
                                           : "Waiting for the RNode: is it in range and switched on? Reticulum retries every few seconds.")
                        .font(Theme.Fonts.footnote).foregroundStyle(model.radioOnline ? Theme.textSecondary : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(.inset)
            }
            if let net = model.internet {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel("Internet link")
                    Text(net.line).font(Theme.Fonts.data).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityIdentifier("reticulum.internetRunning")
                    Text(model.internetOnline ? "Connected. It works while Wildcat is open; iOS closes it in the background."
                                              : "Not connected yet. Check the address and that this phone is online; Reticulum keeps trying.")
                        .font(Theme.Fonts.footnote).foregroundStyle(model.internetOnline ? Theme.textSecondary : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(.inset)
            }
        }
    }

    /// The RNode before a start: none, its planned settings (shown before anything transmits), or unset.
    private var rnodeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !link.state.isReady {
                Label("No RNode connected", systemImage: RNodeStyle.symbol)
                    .font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                Text("An RNode is a LoRa modem you pair over Bluetooth: it puts Reticulum on the air, with no internet needed. Connect one in the RNode console, or use an internet link below.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { router?.showRNode() } label: {
                    Label("Open the RNode console", systemImage: RNodeStyle.symbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(.field(.secondary, .regular))
            } else if let planned = model.plannedSettings(link) {
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel("\(rnodeName) will transmit on")
                    RadioChips(frequency: Double(planned.settings.frequencyHz) / 1e6, bandwidth: Double(planned.settings.bandwidthHz) / 1e3,
                               spreadingFactor: planned.settings.spreadingFactor, codingRate: planned.settings.codingRate,
                               txPower: planned.settings.txPower)
                        .accessibilityIdentifier("reticulum.plannedRadio")
                    Text(planned.source.note + " The other end must use exactly the same. Change them in the RNode console; use a frequency and power you're allowed to use where you are.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("The radio isn't set", systemImage: "slider.horizontal.3")
                    .font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                Text("Set the frequency, bandwidth, spreading factor, coding rate and TX power in the RNode console. Reticulum uses what is set there, and both ends must match.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { router?.showRNode() } label: {
                    Label("Set the radio in the RNode console", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.field(.secondary, .regular))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.inset)
    }

    /// The optional internet link: off until the person turns it on and types a node's address.
    private var internetCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $model.internetOn) {
                Label("Internet link", systemImage: "network").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
            }
            .accessibilityIdentifier("reticulum.internetOn")
            if model.internetOn {
                HStack(spacing: 8) {
                    TextField("node.example.org", text: $model.internetHost)
                        .fieldInput().keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("Node address")
                        .accessibilityIdentifier("reticulum.internetHost")
                    TextField(ReticulumModel.defaultInternetPort, text: $model.internetPort)
                        .fieldInput().keyboardType(.numberPad).frame(width: 84)
                        .accessibilityLabel("Port")
                        .accessibilityIdentifier("reticulum.internetPort")
                }
                if case .failure(let problem)? = model.typedInternetLink, !model.internetHost.isEmpty || problem != .noHost {
                    Text(problem.line).font(Theme.Fonts.footnote).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Type the address and port of a Reticulum node: your own computer, or a public one you choose. Wildcat comes with none. Whoever runs that node can see this phone's internet address; your messages stay encrypted end to end. It works while Wildcat is open.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { openURL(ReticulumBeta.findNodes) } label: {
                    Label("Where to find public nodes (reticulum.network)", systemImage: "arrow.up.right.square").font(Theme.Fonts.footnote)
                }
            } else {
                Text("Reach Reticulum over Wi-Fi or mobile data through a node you choose, with or without an RNode. Off unless you turn it on.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.inset)
    }

    /// Your name, then Start: enabled once at least one link can be used.
    private var startCard: some View {
        @Bindable var model = model
        let plan = model.startPlan(link)
        return VStack(alignment: .leading, spacing: 12) {
            LabeledField(title: "Your name on Reticulum", text: $model.displayName, prompt: ReticulumModel.defaultName)
            if let said = model.announcedName, said != model.displayName {
                Text("Reticulum is already set up as “\(said)” in this session. A new name takes effect after you close Wildcat and open it again.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = model.lastStartError ?? startBlocker(plan) {
                Notice(text: why).accessibilityIdentifier("reticulum.startError")
            }
            Button { model.start(link: link) } label: {
                Label(model.phase.isBusy ? "Starting…" : "Start Reticulum", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
            .disabled(!model.canStart || plan.failureReason != nil)
            .accessibilityIdentifier("reticulum.start")
            Text(startNote(plan))
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.inset)
    }

    /// Why Start is off, unless a card above already says it (no RNode, radio not set, a mistyped address).
    private func startBlocker(_ plan: Result<Reticulum.StartPlan, StartRefusal>) -> String? {
        guard let why = plan.failureReason else { return nil }
        if case .failure? = model.typedInternetLink { return nil }
        if !link.state.isReady { return model.internetOn ? why : nil }
        return model.plannedSettings(link) == nil ? nil : why
    }

    private func startNote(_ plan: Result<Reticulum.StartPlan, StartRefusal>) -> String {
        guard case .success(let p) = plan else {
            if case .failure? = model.typedInternetLink {
                return "Type the node's address and port above, or turn the internet link off, to start."
            }
            return "Connect an RNode or turn on the internet link to start."
        }
        switch (p.radio != nil, p.internet != nil) {
        case (true, true): return "Starting takes the RNode over from the console, turns its radio on and connects the internet link. Nothing is announced until you tap Announce. This phone never passes other people's traffic between the two."
        case (true, false): return "Starting takes the RNode over from the console, turns its radio on and announces nothing by itself: you choose when to announce."
        default: return "Starting connects to that node. Nothing is announced until you tap Announce. No radio is used."
        }
    }

    // MARK: Conversations

    private var conversations: some View {
        let list = model.conversations
        return VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(3, "Conversations", detail: list.isEmpty ? nil : "\(list.count)", action: "New", symbol: "square.and.pencil") {
                showCompose = true
            }
            if list.isEmpty {
                Text(model.isRunning ? "No conversations yet. Tap someone under People heard, or New to write to an address."
                                     : "No conversations yet.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .panel(.inset)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { FieldDivider(inset: 58) }
                        Button { chat = c.peer } label: { ReticulumConversationRow(conversation: c, model: model) }
                            .buttonStyle(.rowPress)
                            .contextMenu {
                                Button("Copy address", systemImage: "doc.on.doc") { UIPasteboard.general.string = c.peer }
                                Button("Delete conversation", systemImage: "trash", role: .destructive) { model.removeConversation(with: c.peer) }
                            }
                    }
                }
                .panel(.inset)
            }
        }
    }

    // MARK: People heard

    private var people: some View {
        let list = model.heard
        return VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(4, "People heard", detail: list.isEmpty ? nil : "\(list.count)")
            if list.isEmpty {
                Text(model.isRunning ? "Nobody yet. People show up here when their announce reaches your RNode: ask them to announce, or wait for their next one."
                                     : "People show up here when their announce reaches your RNode while Reticulum is running.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .panel(.inset)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.prefix(30).enumerated()), id: \.element.id) { i, p in
                        if i > 0 { FieldDivider(inset: 58) }
                        Button { chat = p.hash } label: { ReticulumPersonRow(person: p, model: model) }
                            .buttonStyle(.rowPress)
                            .contextMenu {
                                Button("Copy address", systemImage: "doc.on.doc") { UIPasteboard.general.string = p.hash }
                                Button("Block \(model.title(for: p.hash))", systemImage: "hand.raised", role: .destructive) {
                                    safety.block(.reticulum(p.hash, name: p.name))
                                }
                            }
                    }
                }
                .panel(.inset)
            }
        }
    }

    // MARK: Beta

    private var beta: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(5, "About this beta", action: showLimits ? "Hide" : "What works?", symbol: "questionmark.circle") {
                withAnimation(Theme.Motion.snappy) { showLimits.toggle() }
            }
            if showLimits {
                ExplainerPanel("Reticulum in Wildcat, so far",
                               text: "Wildcat runs the official Reticulum stack (RNS and LXMF by Mark Qvist, unmodified) and talks to your RNode over Bluetooth. Messages are end-to-end encrypted by Reticulum.") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(ReticulumBeta.limits, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("·").font(Theme.Fonts.dataBold).foregroundStyle(ReticulumStyle.color)
                                Text(line).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .transition(.opacity)
            } else {
                Text("Direct text messages over an RNode or an internet link, with the app open. Tap What works? for the limits.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// What the beta can't do yet, in plain lines (also the guide's).
enum ReticulumBeta {
    /// The Reticulum manual's section on finding nodes to connect to. Wildcat lists none itself.
    static let findNodes = URL(string: "https://reticulum.network/manual/gettingstartedfast.html#bootstrapping-connectivity")!
    static let limits = [
        "Text messages between two people. No group chats, attachments or voice.",
        "Keep Wildcat open while you expect messages. With the phone locked or the app closed, messages may not arrive.",
        "No stamps yet: people who only accept stamped messages can't be written to from this iPhone.",
        "No propagation nodes yet: a message only gets through while the other end is reachable.",
        "Two ways out: an RNode over Bluetooth, and an optional internet link to a node you choose. The internet link works only while Wildcat is open.",
        "This phone is an end point: it never relays other people's traffic, and never passes internet traffic onto the radio.",
        "Your Reticulum identity lives on this phone only. It is not in backups and does not move to a new phone.",
    ]
}

/// Reticulum's own look: the RNode's violet, its own glyph (cryptographic radio).
enum ReticulumStyle {
    static let color = Theme.rnode
    static let symbol = "key.radiowaves.forward"
}

// MARK: - Rows

struct ReticulumConversationRow: View {
    let conversation: Reticulum.Conversation
    let model: ReticulumModel

    var body: some View {
        let last = conversation.last
        HStack(spacing: 12) {
            IconTile(symbol: "person", tint: conversation.unread > 0 ? ReticulumStyle.color : nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.title(for: conversation.peer)).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if conversation.contact?.needsStamp == true { Tag("stamps") }
                }
                HStack(spacing: 5) {
                    if !last.incoming {
                        Image(systemName: ReticulumChatFormat.glyph(last.delivery))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ReticulumChatFormat.color(last.delivery))
                    }
                    Text((last.incoming ? "" : "You: ") + model.shown(last))
                        .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(ReticulumChatFormat.when(last.at)).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                if conversation.unread > 0 {
                    Text("\(conversation.unread)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                        .background(ReticulumStyle.color, in: Capsule())
                        .accessibilityLabel("\(conversation.unread) unread")
                }
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ReticulumPersonRow: View {
    let person: Reticulum.Contact
    let model: ReticulumModel

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "dot.radiowaves.left.and.right", tint: ReticulumStyle.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.title(for: person.hash)).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if person.needsStamp { Tag("stamps") }
                }
                Text("<\(Reticulum.shortAddress(person.hash))>")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(person.hops.map { $0 <= 1 ? "direct" : "\($0) hops" } ?? "—")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                Text(person.lastHeard.map { ReticulumChatFormat.when($0) } ?? "")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
            }
            Chevron()
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - New message

/// Write to an address someone gave you (they needn't have been heard yet).
struct ReticulumComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let open: (String) -> Void

    private var address: String? { Reticulum.address(text) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste the other person's Reticulum (LXMF) address: 32 letters and digits, as Sideband or MeshChat shows it.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("a1b2c3…", text: $text, axis: .vertical)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .fieldInput()
                    .accessibilityIdentifier("reticulum.newAddress")
                HStack(spacing: 8) {
                    Button { text = UIPasteboard.general.string ?? text } label: {
                        Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.field(.secondary, .regular))
                    Button {
                        if let address { dismiss(); open(address) }
                    } label: {
                        Label("Open chat", systemImage: "bubble.left").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.fieldPrimary)
                    .disabled(address == nil)
                }
                if !text.isEmpty, address == nil {
                    Text("That isn't a Reticulum address yet: it needs exactly 32 of 0–9 and a–f.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.warn)
                }
                Spacer()
            }
            .padding(Theme.Space.edge)
            .screen()
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.bg)
        .tint(ReticulumStyle.color)
    }
}

#if DEBUG
/// Developer builds only: the loopback TCP interface for the simulator test, the heartbeat for
/// the background test, the measurements and the stack's log.
struct ReticulumDeveloperPanel: View {
    @Bindable var model: ReticulumModel
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(6, "Developer", action: open ? "Hide" : "Show") { open.toggle() }
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("RNode over Bluetooth", isOn: $model.useRNode).foregroundStyle(Theme.textPrimary)
                    Toggle("Opportunistic (single packet, no link)", isOn: $model.opportunistic).foregroundStyle(Theme.textPrimary)
                    Toggle("Heartbeat every 5 s (background test)", isOn: $model.heartbeat).foregroundStyle(Theme.textPrimary)
                    if let v = model.versions { Text(v).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary) }
                    Text("identity: \(model.identityStore) · python \(model.pythonReadyMs.map { "\($0) ms" } ?? "—") · rns \(model.reticulumMs.map { "\($0) ms" } ?? "—") · memory \(model.memoryRunningMB.map { String(format: "%.0f MB", $0) } ?? "—")")
                        .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    ForEach(model.interfaces) { i in
                        Text("\(i.online ? "●" : "○") \(i.name) rx \(i.rxBytes) tx \(i.txBytes)").font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                    }
                    Text(model.log.suffix(40).joined(separator: "\n"))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .toggleStyle(FieldToggleStyle())
                .padding(14)
                .panel(.inset)
            }
        }
    }
}
#endif

extension Result where Failure == StartRefusal {
    /// The reason, when this is a failure.
    var failureReason: String? {
        if case .failure(let why) = self { return why.line }
        return nil
    }
}
