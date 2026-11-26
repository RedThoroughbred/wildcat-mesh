import MapKit
import SwiftUI
import WildcatRadioCore

// MARK: - Shared pieces

/// A MeshCore node's outlined glyph: blue for the mesh's infrastructure
/// (repeaters, room servers), grey for people and sensors.
struct MeshCoreGlyph: View {
    let kind: MeshCore.Contact.Kind
    var size: CGFloat = 30

    var body: some View {
        IconTile(symbol: MeshCoreFormat.symbol(kind), tint: MeshCoreFormat.isInfrastructure(kind) ? Theme.meshcore : nil, size: size)
    }
}

/// A heard node in a list (AB `.r` with `.sig`): glyph, name and role tags,
/// a plain line ("2 hops · weak signal · 42 s ago"), and the signal meter.
struct MeshCoreNodeRow: View {
    let contact: MeshCore.Contact
    var signal: PacketFeed.NodeSignal?
    var mine = false
    var chevron = false

    var body: some View {
        HStack(spacing: 12) {
            MeshCoreGlyph(kind: contact.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(MeshCoreFormat.name(contact))
                        .font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        .layoutPriority(1)
                    if contact.kind != .chat { Tag(MeshCoreFormat.kind(contact.kind)) }
                    if mine { Tag("Mine", color: Theme.textTertiary) }
                }
                TimelineView(.periodic(from: .now, by: 30)) { t in
                    Text(MeshCoreFormat.line(contact, signal: signal, now: t.date))
                        .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                SegmentMeter(lit: SignalGrade.bars(snr: signal?.snr, rssi: signal?.rssi), of: 5, tint: Theme.meshcore)
                Text(signal.map { MeshCoreFormat.db($0.snr) } ?? "—")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            if chevron { Chevron() }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The radio settings as mono chips ("910.525 MHz", "BW 62.5", "SF7").
struct RadioChips: View {
    let frequency: Double?
    let bandwidth: Double?
    let spreadingFactor: Int?
    let codingRate: Int?
    var txPower: Int? = nil

    var body: some View {
        FlowRow(spacing: 5) {
            if let frequency { RadioChip(String(format: "%.3f", frequency), unit: "MHz") }
            if let bandwidth { RadioChip(OwnedNode.trim(bandwidth), lead: "BW") }
            if let spreadingFactor { RadioChip("\(spreadingFactor)", lead: "SF") }
            if let codingRate { RadioChip("\(codingRate)", lead: "CR") }
            if let txPower { RadioChip(MeshCoreFormat.minus("\(txPower)"), unit: "dBm") }
        }
    }
}

/// Lays its children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A plain-English explainer box (AB `.explain`): a question, an answer, and
/// optionally a picture under a hairline.
struct ExplainerPanel<Extra: View>: View {
    let title: String
    let text: String
    @ViewBuilder var extra: Extra

    init(_ title: String, text: String, @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.text = text
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "questionmark.circle")
                .font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            extra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

extension ExplainerPanel where Extra == EmptyView {
    init(_ title: String, text: String) {
        self.init(title, text: text) { EmptyView() }
    }
}

/// You → repeaters → the node, with the signal on each link we know about
/// (AB node detail `.path`).
struct HopPath: View {
    struct Stop: Identifiable {
        let id: Int
        let name: String
        let symbol: String
        var tint: Color? = nil
    }

    let stops: [Stop]
    /// One label per link (stops.count − 1); nil draws a plain dashed link.
    let links: [Double?]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
            ScrollView(.horizontal, showsIndicators: false) { row(compact: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stops.map(\.name).joined(separator: ", then "))
    }

    private func row(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(stops) { stop in
                if stop.id > 0 { link(stop.id - 1 < links.count ? links[stop.id - 1] : nil) }
                VStack(spacing: 6) {
                    Image(systemName: stop.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(stop.tint ?? Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(stop.tint?.opacity(0.4) ?? Theme.hairlineStrong, lineWidth: 1))
                    Text(stop.name)
                        .font(.system(size: compact ? 11 : 12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: compact ? 64 : 96)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func link(_ snr: Double?) -> some View {
        let color = snr.map { SignalGrade.grade(snr: $0, rssi: nil) == .weak ? Theme.alert : Theme.meshcore } ?? Theme.textQuaternary
        return VStack(spacing: 3) {
            Text(snr.map(MeshCoreFormat.db) ?? " ")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(snr.map { SignalGrade.grade(snr: $0, rssi: nil) == .weak ? Theme.alert : Theme.textTertiary } ?? .clear)
                .lineLimit(1)
                .fixedSize()
            Line()
                .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
        }
        .padding(.top, 2)
        .frame(minWidth: 36, maxWidth: .infinity)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            return p
        }
    }
}

// MARK: - Contacts

struct MeshCoreContactsView: View {
    enum Filter: Hashable { case all, people, infrastructure }

    @Environment(MeshCoreLink.self) private var link
    @Environment(PacketFeed.self) private var feed
    @Environment(MyMeshStore.self) private var myMesh
    @State private var query = ""
    @State private var filter = Filter.all
    @AppStorage("meshcore.contactSort") private var sort = MeshCoreFormat.Sort.recent

    private var contacts: [MeshCore.Contact] {
        let all = link.session.contacts.values.filter { c in
            (query.isEmpty || c.name.localizedCaseInsensitiveContains(query) || c.shortID.contains(query.lowercased()))
                && (filter == .all || (filter == .infrastructure) == MeshCoreFormat.isInfrastructure(c.kind))
        }
        return MeshCoreFormat.sorted(Array(all), by: sort) { feed.signal(meshcore: $0) }
    }

    var body: some View {
        let list = contacts
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                FieldSegmented(options: [(Filter.all, "All"), (.people, "People"), (.infrastructure, "Repeaters")], selection: $filter)
                ModuleHeader(nil, "Contacts", detail: "\(list.count)") { MeshCoreSortMenu(sort: $sort) }
                if list.isEmpty {
                    EmptyState(symbol: "person.2.wave.2", title: query.isEmpty ? "No contacts yet" : "No matches",
                               text: query.isEmpty ? "MeshCore adds a node when it hears its advert. Send yours so others add you."
                                                   : "Nothing on this node matches “\(query)”.",
                               actionTitle: query.isEmpty ? "Send advert" : nil, action: query.isEmpty ? { link.advertise() } : nil)
                        .panel(.inset)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.publicKey) { i, c in
                            if i > 0 { FieldDivider() }
                            NavRow { MeshCoreContactDetail(key: c.publicKey) } label: {
                                MeshCoreNodeRow(contact: c, signal: feed.signal(meshcore: c.publicKey),
                                                mine: MeshCoreFormat.isMine(c, in: myMesh), chevron: true)
                            }
                        }
                    }
                    .panel(.inset)
                }
                Text("Signal is how well your radio last heard each node. Through repeaters it's the last hop's signal, not theirs.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .searchable(text: $query)
        .navigationTitle("Contacts")
        .refreshable { link.enqueue(.getContacts) }
    }
}

/// "Sort: signal" on a module header.
struct MeshCoreSortMenu: View {
    @Binding var sort: MeshCoreFormat.Sort

    var body: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(MeshCoreFormat.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Text("Sort: \(sort.title.lowercased())").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
        }
    }
}

struct MeshCoreContactDetail: View {
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshCoreStore.self) private var store
    @Environment(PacketFeed.self) private var feed
    @Environment(MyMeshStore.self) private var myMesh
    @Environment(ExploreModel.self) private var explore
    @Environment(\.dismiss) private var dismiss
    @Environment(Safety.self) private var safety
    let key: Data
    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var go: Destination?
    @State private var copied = false

    private enum Destination: Hashable { case message, trace, admin }

    var body: some View {
        if let c = link.session.contacts[key] {
            let signal = feed.signal(meshcore: c.publicKey)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    hero(c)
                    keys(c)
                    ModuleHeader(1, "Role")
                    ExplainerPanel(MeshCoreFormat.roleQuestion(c.kind), text: MeshCoreFormat.roleAnswer(c.kind)) {
                        PanelDivider().padding(.vertical, 4)
                        HopPath(stops: stops(c), links: links(c, signal))
                            .padding(.vertical, 2)
                    }
                    ModuleHeader(2, "Link") {
                        Text(linkHint(c, signal)).font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    }
                    linkPanel(c, signal)
                    ModuleHeader(3, "Raw", action: copied ? "Copied" : "Copy JSON", symbol: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = MeshCoreFormat.json(raw(c))
                        Haptics.success()
                        copied = true
                    }
                    KeyValueGrid(raw(c))
                    ModuleHeader(4, "Manage")
                    manage(c)
                }
                .padding(Theme.Space.edge)
                .padding(.bottom, Theme.Space.xl)
            }
            .screen()
            .navigationTitle(MeshCoreFormat.name(c))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = MeshCoreFormat.hex(c.publicKey)
                        Haptics.success()
                    } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy public key")
                }
            }
            .navigationDestination(item: $go) { d in
                switch d {
                case .message: MeshCoreChatView(origin: .contact(c.prefix))
                case .trace: MeshCoreTraceView(key: c.publicKey)
                case .admin: MeshCoreRepeaterView(key: c.publicKey)
                }
            }
            .onAppear { explore.begin(asking: false) }
            .onDisappear { explore.end() }
            .confirmationDialog("Remove \(c.name) from this node?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { link.removeContact(c); dismiss() }
            } message: { Text("It comes back the next time the node hears its advert (if auto-add is on).") }
            .confirmationDialog("Block \(c.name)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { safety.block(.contact(c)); Haptics.thud() }
            } message: {
                Text("Their messages disappear from Wildcat, you get no notifications from them, and the bridge won't relay them. Unblock any time in Safety.")
            }
        } else {
            Text("Contact removed.").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).screen()
        }
    }

    private func hero(_ c: MeshCore.Contact) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MeshCoreGlyph(kind: c.kind, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(MeshCoreFormat.name(c))
                    .font(.system(.title, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).minimumScaleFactor(0.6)
                HStack(spacing: 6) {
                    Tag(MeshCoreFormat.kind(c.kind))
                    NetworkTag(.meshcore)
                    if link.state.isReady {
                        // Whether your node holds it (it can message it) or only heard its advert.
                        Tag(link.session.isOnNode(c) ? "Saved on node" : "Heard only",
                            color: link.session.isOnNode(c) ? Theme.textSecondary : Theme.meshcore)
                    }
                    Text(c.shortID).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                }
                .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { t in
                    let online = c.lastAdvert.map { t.date.timeIntervalSince($0) < 3600 } ?? false
                    HStack(spacing: 7) {
                        StatusLED(color: Theme.ok, on: online, size: 7)
                        Text(heardLine(c, online: online, now: t.date))
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func heardLine(_ c: MeshCore.Contact, online: Bool, now: Date) -> String {
        let via = link.session.me.map { " via \($0.name)" } ?? ""
        guard let at = c.lastAdvert else { return "Not heard yet\(via)" }
        return "\(online ? "Online" : "Quiet") · heard \(MeshCoreFormat.ago(at, now: now))\(via)"
    }

    private func keys(_ c: MeshCore.Contact) -> some View {
        let infra = MeshCoreFormat.isInfrastructure(c.kind)
        let canMessage = c.kind == .chat || c.kind == .room
        let mine = MeshCoreFormat.isMine(c, in: myMesh)
        return StatusKeyRow {
            StatusKey("Message", symbol: "bubble.left", primary: canMessage) { go = .message }
                .disabled(!canMessage)
            StatusKey("Trace", symbol: "point.topleft.down.to.point.bottomright.curvepath", primary: c.kind == .repeater) { go = .trace }
                .disabled(!infra || !link.state.isReady)
            StatusKey("Admin", symbol: "key") { go = .admin }
                .disabled(!infra)
            StatusKey("My Mesh", symbol: mine ? "checkmark.circle" : "plus.circle", led: mine ? .on : .none) {
                let n = OwnedNode.meshcore(c, companion: link.session.me, origin: .manual)
                if myMesh.contains(n.id) { myMesh.remove(n.id) } else { myMesh.markMine(n) }
            }
            .disabled(myMesh.node(MeshCoreFormat.ownedID(c))?.origin == .practice)
        }
    }

    // MARK: Role path

    /// You, the repeaters on the route, then the node.
    private func stops(_ c: MeshCore.Contact) -> [HopPath.Stop] {
        var out = [HopPath.Stop(id: 0, name: "You", symbol: "person")]
        for (i, h) in MeshCoreFormat.pathHashes(c).enumerated() {
            let matches = link.session.contacts(hash: h)
            let name = matches.count == 1 ? MeshCoreFormat.name(matches[0]) : MeshCoreFormat.hex(h)
            out.append(HopPath.Stop(id: i + 1, name: name, symbol: MeshCoreFormat.symbol(.repeater), tint: Theme.meshcore))
        }
        out.append(HopPath.Stop(id: out.count, name: MeshCoreFormat.name(c), symbol: MeshCoreFormat.symbol(c.kind),
                                tint: MeshCoreFormat.isInfrastructure(c.kind) ? Theme.meshcore : nil))
        return out
    }

    /// We only know how well we heard the last hop: it goes on the link next to You.
    private func links(_ c: MeshCore.Contact, _ signal: PacketFeed.NodeSignal?) -> [Double?] {
        let count = MeshCoreFormat.pathHashes(c).count + 1
        return [signal?.snr] + Array(repeating: nil, count: max(0, count - 1))
    }

    // MARK: Link readouts

    private func linkHint(_ c: MeshCore.Contact, _ s: PacketFeed.NodeSignal?) -> String {
        guard let s else { return "not heard on air yet" }
        let grade = SignalGrade.grade(snr: s.snr, rssi: s.rssi).word
        return s.hops == 0 ? "\(grade) · direct" : "\(grade) · last hop"
    }

    private func linkPanel(_ c: MeshCore.Contact, _ s: PacketFeed.NodeSignal?) -> some View {
        let status = store.repeater(c).status
        let path = MeshCoreFormat.pathHashes(c).map(MeshCoreFormat.hex).joined(separator: " › ")
        return InstrumentPanel {
            ReadoutRow {
                ReadoutCell("SNR", value: s.map { MeshCoreFormat.number($0.snr, digits: 2) } ?? "—", unit: "dB") {
                    SegmentMeter(lit: SignalGrade.bars(snr: s?.snr, rssi: nil), of: 5, tint: Theme.meshcore, size: .xs)
                }
                CellDivider()
                ReadoutCell("RSSI", value: s?.rssi.map { MeshCoreFormat.minus("\($0)") } ?? "—", sub: "dBm")
                CellDivider()
                ReadoutCell("Hops", value: c.pathLength.map { "\($0)" } ?? "—",
                            sub: c.pathLength == 0 ? "direct" : path.isEmpty ? "flood" : path)
                CellDivider()
                if let status {
                    ReadoutCell("Batt", value: MeshCoreFormat.volts(status.batteryMillivolts), unit: "V",
                                sub: "up " + MeshCoreFormat.duration(status.uptimeSeconds))
                } else {
                    ReadoutCell("Seen", value: c.lastAdvert.map { MeshCoreFormat.ago($0, short: true) } ?? "—",
                                sub: c.lastAdvert == nil ? "no advert" : "ago")
                }
            }
        }
    }

    // MARK: Raw

    private func raw(_ c: MeshCore.Contact) -> [KeyValueItem] {
        var items = [
            KeyValueItem(key: "pubkey", value: MeshCoreFormat.hex(c.publicKey)),
            KeyValueItem(key: "type", value: "\(MeshCoreFormat.kind(c.kind).uppercased()) 0x" + String(format: "%02x", c.kind.rawValue),
                         note: myMesh.node(MeshCoreFormat.ownedID(c))?.firmware.map { "fw \($0)" }),
        ]
        if let me = link.session.me {
            items.append(KeyValueItem(key: "radio", value: String(format: "%.3f · %@ · SF%d · %d", me.frequency, OwnedNode.trim(me.bandwidth),
                                                                 me.spreadingFactor, me.codingRate),
                                      note: "shared"))
        }
        items.append(KeyValueItem(key: "path", value: c.pathLength == nil ? "none (flood)"
                                  : c.pathLength == 0 ? "direct" : MeshCoreFormat.pathHashes(c).map(MeshCoreFormat.hex).joined(separator: " › "),
                                  note: c.pathLength.map { "\($0) hop\($0 == 1 ? "" : "s")" }))
        if let at = c.lastAdvert {
            items.append(KeyValueItem(key: "advert", value: at.formatted(date: .omitted, time: .standard),
                                      note: MeshCoreFormat.ago(at, short: true)))
        }
        if let p = c.position {
            let here = explore.here ?? explore.lastKnown
            let d = here.map { Geo.distance($0, LatLon(lat: p.latitude, lon: p.longitude)) }
            items.append(KeyValueItem(key: "pos", value: MeshCoreFormat.minus(String(format: "%.4f, %.4f", p.latitude, p.longitude)),
                                      note: d.map(Geo.format)))
        }
        items.append(KeyValueItem(key: "flags", value: "0x" + String(format: "%02x", c.flags)))
        return items
    }

    // MARK: Manage

    @ViewBuilder private func manage(_ c: MeshCore.Contact) -> some View {
        FieldGroup {
            if link.state.isReady && !link.session.isOnNode(c) {
                Button { link.addContact(c); Haptics.success() } label: {
                    FieldRow(symbol: "plus.circle", tint: Theme.meshcore, title: "Add to node",
                             subtitle: "Your node heard it but hasn't saved it. Messaging it adds it too.", chevron: false)
                }
                .buttonStyle(.rowPress)
                FieldDivider()
            }
            Button { link.resetPath(c); Haptics.tap() } label: {
                FieldRow(symbol: "arrow.triangle.branch", title: "Reset route", subtitle: "Forget the path and find a new one", chevron: false)
            }
            .buttonStyle(.rowPress)
            if c.kind == .chat || c.kind == .room {
                FieldDivider()
                if safety.hides(c) {
                    Button { safety.unblock(c) } label: {
                        FieldRow(symbol: "hand.raised.slash", title: "Unblock", chevron: false)
                    }
                    .buttonStyle(.rowPress)
                } else {
                    Button { confirmBlock = true } label: {
                        FieldRow(symbol: "hand.raised", title: "Block", subtitle: "Hide their messages everywhere", chevron: false)
                    }
                    .buttonStyle(.rowPress)
                }
            }
            FieldDivider()
            Button { confirmRemove = true } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "trash", tint: Theme.alert)
                    Text("Remove contact").font(Theme.Fonts.heading).foregroundStyle(Theme.alert)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.rowH)
                .padding(.vertical, Theme.Space.rowV)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.rowPress)
        }
    }
}

// MARK: - Channels

/// What kind of channel a slot holds, for its icon and wording.
enum MeshCoreChannelKind {
    case publicChannel, hashtag, privateChannel

    init(index: Int, name: String, secret: Data) {
        if index == 0 { self = .publicChannel }
        else if MeshCoreChannelCode.isHashtag(name: name, key: secret) { self = .hashtag }
        else { self = .privateChannel }
    }

    var symbol: String {
        switch self {
        case .publicChannel: return "globe"
        case .hashtag: return "number"
        case .privateChannel: return "lock"
        }
    }

    var tag: String {
        switch self {
        case .publicChannel: return "Public"
        case .hashtag: return "Hashtag"
        case .privateChannel: return "Private"
        }
    }

    var line: String {
        switch self {
        case .publicChannel: return "Everyone on MeshCore nearby can read this one."
        case .hashtag: return "Anyone who knows the name can read it: treat it as public."
        case .privateChannel: return "Only radios with its key can read it."
        }
    }
}

struct MeshCoreChannelsView: View {
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshCoreStore.self) private var store
    @State private var sheet = false

    var body: some View {
        let s = link.session
        let channels = s.channels.values.sorted { $0.index < $1.index }
        let free = MeshCoreNodeLimits.freeChannelSlot(used: Set(s.channels.keys), maxChannels: s.device?.maxChannels)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                ModuleHeader(1, "Channels", detail: "\(s.channels.count) of \(s.device?.maxChannels ?? 8)")
                VStack(spacing: 0) {
                    ForEach(Array(channels.enumerated()), id: \.element.index) { i, c in
                        let kind = MeshCoreChannelKind(index: c.index, name: c.name, secret: c.secret)
                        if i > 0 { FieldDivider() }
                        NavRow { MeshCoreChannelDetail(index: c.index) } label: {
                            FieldRow(symbol: kind.symbol, title: s.label(.channel(c.index)),
                                     subtitle: store.lastLine(.channel(c.index)) ?? (c.index == 0 ? "Public: everyone on MeshCore" : "\(kind.tag) channel"),
                                     detail: "slot \(c.index)")
                        }
                    }
                }
                .panel(.inset)
                Button { sheet = true } label: {
                    Label("Add a channel", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.fieldPrimary)
                .disabled(free == nil)
                Text(free == nil ? "Every channel slot on this node is full. Delete one to add another."
                                 : "Create a private channel with a random 128-bit key, join one by its link, key or QR code, or join a #hashtag channel.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.edge)
        }
        .screen()
        .navigationTitle("MeshCore channels")
        .sheet(isPresented: $sheet) { MeshCoreChannelSheet() }
    }
}

struct MeshCoreChannelDetail: View {
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var copied: String?
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        if let c = link.session.channels[index] {
            let hex = MeshCoreFormat.hex(c.secret)
            let kind = MeshCoreChannelKind(index: index, name: c.name, secret: c.secret)
            let code = MeshCoreChannelCode(name: c.name, key: c.secret)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    HStack(alignment: .top, spacing: 14) {
                        IconTile(symbol: kind.symbol, tint: Theme.meshcore, size: 52)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(link.session.label(.channel(index))).font(.system(.title, weight: .bold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.6)
                            HStack(spacing: 6) {
                                Tag(kind.tag)
                                NetworkTag(.meshcore)
                                Text("slot \(index)").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                            }
                            Text(kind.line).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    NavigationLink { MeshCoreChatView(origin: .channel(index)) } label: {
                        Label("Open chat", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.fieldPrimary)
                    if let last = store.lastLine(.channel(index)) {
                        MetaLine("Last: \(last)")
                    }
                    if index > 0 {
                        ModuleHeader(1, "Share", action: copied == "link" ? "Copied" : "Copy link", symbol: copied == "link" ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = code.link
                            Haptics.success()
                            copied = "link"
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(kind == .hashtag
                                 ? "Others join by adding the hashtag channel \(c.name) (in Wildcat or the MeshCore app), or by scanning the code."
                                 : "Others scan this in Wildcat or the MeshCore app to join. Anyone with the code can read the channel.")
                                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            QRImage(text: code.link)
                                .frame(maxWidth: 220)
                                .frame(maxWidth: .infinity)
                            HStack {
                                ShareLink(item: code.link) { Label("Share link", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(.field(.secondary, .small))
                                Button {
                                    UIPasteboard.general.string = hex
                                    Haptics.success()
                                    copied = "key"
                                } label: { Label(copied == "key" ? "Copied" : "Copy key", systemImage: copied == "key" ? "checkmark" : "key") }
                                    .buttonStyle(.field(.secondary, .small))
                            }
                        }
                        .panel(.hero)
                        ModuleHeader(2, "Raw")
                        KeyValueGrid([
                            KeyValueItem(key: "name", value: c.name),
                            KeyValueItem(key: "slot", value: "\(index)"),
                            KeyValueItem(key: "key", value: hex, note: "\(c.secret.count * 8) bit"),
                            KeyValueItem(key: "link", value: code.link),
                        ])
                        ModuleHeader(3, "Manage")
                        if kind == .privateChannel {
                            Button { newName = c.name; renaming = true } label: {
                                Label("Rename channel", systemImage: "pencil").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.field(.secondary, .regular))
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete channel", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.field(.destructive, .regular))
                    }
                }
                .padding(Theme.Space.edge)
                .padding(.bottom, Theme.Space.xl)
            }
            .screen()
            .navigationTitle(link.session.label(.channel(index)))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete \(c.name) from this node?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { link.deleteChannel(index); dismiss() }
            }
            .alert("Rename channel", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") {
                    let n = MeshCoreNodeLimits.clamp(newName.trimmingCharacters(in: .whitespaces), maxBytes: MeshCoreChannelCode.maxNameBytes)
                    guard !n.isEmpty, !n.hasPrefix("#"), n != c.name else { return }
                    // Same key, new name: everyone keeps reading it; their copy keeps its old name.
                    link.enqueue(.setChannel(index: index, name: n, secret: c.secret))
                    link.enqueue(.getChannel(index: index))
                    Haptics.success()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The key stays the same, so everyone in it keeps reading it. Names starting with # are for hashtag channels.")
            }
        } else {
            Text("Channel deleted.").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).screen()
        }
    }
}

/// Create a private channel, join one by its link or key (typed, pasted or
/// scanned), or join a #hashtag channel (its key comes from its name).
struct MeshCoreChannelSheet: View {
    enum Mode: Hashable { case create, join, hashtag }
    @Environment(MeshCoreLink.self) private var link
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.create
    @State private var name = "WGBRIDGE"
    @State private var key = ""
    @State private var tag = ""
    @State private var scanning = false

    /// A pasted link or 32 hex digits = 16 bytes.
    private var keyData: Data? {
        if key.contains("://") { return MeshCoreChannelCode(scanned: key)?.key }
        return MeshCoreChannelCode.key(key)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var hashtag: String? { MeshCoreChannelCode.hashtagName(tag) }
    private var hasRoom: Bool {
        MeshCoreNodeLimits.freeChannelSlot(used: Set(link.session.channels.keys), maxChannels: link.session.device?.maxChannels) != nil
    }

    private var canSave: Bool {
        guard hasRoom else { return false }
        switch mode {
        case .create: return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        case .join: return !trimmed.isEmpty && keyData != nil
        case .hashtag: return hashtag != nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    FieldSegmented(options: [(Mode.create, "Create"), (.join, "Join"), (.hashtag, "#Hashtag")], selection: $mode)
                    switch mode {
                    case .create:
                        nameField
                        Text("A fresh random key only your nodes will know. Share it from the channel's page so others can join.")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    case .join:
                        nameField
                        VStack(alignment: .leading, spacing: 6) {
                            CardLabel("Link or key (32 hex digits)")
                            TextField("meshcore://channel/add?… or 8b3387e9…", text: $key, axis: .vertical)
                                .font(.system(.footnote, design: .monospaced))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .fieldInput()
                                .onChange(of: key) { _, v in take(v) }
                            HStack {
                                Button { key = UIPasteboard.general.string ?? "" } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                                    .buttonStyle(.field(.secondary, .small))
                                Button { scanning = true } label: { Label("Scan QR", systemImage: "qrcode.viewfinder") }
                                    .buttonStyle(.field(.secondary, .small))
                            }
                            if !key.isEmpty && keyData == nil {
                                Text("That isn't a MeshCore channel link or a 32-digit hex key.").font(Theme.Fonts.footnote).foregroundStyle(Theme.alert)
                            }
                        }
                    case .hashtag:
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledField(title: "Hashtag", text: $tag, prompt: "#hiking")
                            if let h = hashtag {
                                MetaLine("Joins \(h) · key \(MeshCoreFormat.hex(MeshCoreChannelCode.hashtagKey(h)).prefix(8))…")
                            } else if !tag.isEmpty {
                                Text("One word after the #, no spaces.").font(Theme.Fonts.footnote).foregroundStyle(Theme.alert)
                            }
                        }
                        Text("A hashtag channel's key comes from its name, so everyone who types the same #name (same capitals) meets there. It's not private: anyone who guesses the name can read it.")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !hasRoom {
                        Notice(text: "Every channel slot on this node is full. Delete one first.", color: Theme.alert)
                    }
                    Button {
                        save()
                        dismiss()
                    } label: {
                        Label(mode == .create ? "Create channel" : "Join channel", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.fieldPrimary)
                    .disabled(!canSave)
                }
                .padding(Theme.Space.edge)
            }
            .screen()
            .navigationTitle("Add a channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScanner(accept: { MeshCoreChannelCode(scanned: $0) != nil }) { code in
                    guard let c = MeshCoreChannelCode(scanned: code) else { return }
                    key = MeshCoreFormat.hex(c.key)
                    if let n = c.name { name = n }
                    scanning = false
                }
                .ignoresSafeArea()
            }
        }
        .presentationDetents([.large])
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledField(title: "Channel name", text: $name, prompt: "WGBRIDGE")
                .onChange(of: name) { _, v in
                    let c = MeshCoreNodeLimits.clamp(v, maxBytes: MeshCoreChannelCode.maxNameBytes)
                    if c != v { name = c }
                }
            if mode == .create && trimmed.hasPrefix("#") {
                Text("Names starting with # are hashtag channels: use the #Hashtag tab.").font(Theme.Fonts.footnote).foregroundStyle(Theme.alert)
            }
        }
    }

    /// A pasted or typed link fills in the name too.
    private func take(_ text: String) {
        guard text.contains("://"), let c = MeshCoreChannelCode(scanned: text), let n = c.name else { return }
        name = MeshCoreNodeLimits.clamp(n, maxBytes: MeshCoreChannelCode.maxNameBytes)
    }

    private func save() {
        switch mode {
        case .create: link.addChannel(named: trimmed)
        case .join: link.addChannel(named: trimmed, secret: keyData)
        case .hashtag:
            guard let h = hashtag else { return }
            link.addChannel(named: h, secret: MeshCoreChannelCode.hashtagKey(h))
        }
        Haptics.success()
    }
}

// MARK: - Map

struct MeshCoreMapView: View {
    /// What a pin on this map stands for, so tapping any of them selects it.
    enum Pick: Hashable { case meshcore(Data), meshtastic(NodeNum) }

    @Environment(MeshCoreLink.self) private var link
    @Environment(Radio.self) private var radio
    @Environment(PacketFeed.self) private var feed
    @Environment(ExploreModel.self) private var explore
    /// false: MeshCore only (the MeshCore tab's own map). true: both networks.
    var bothNetworks = true
    @State private var showMeshtastic = true
    @State private var showMeshCore = true
    @State private var showRange = true
    @State private var selected: Pick?

    /// Where "you" are: the phone, else the connected node's own position.
    private var here: LatLon? {
        if let h = explore.here ?? explore.lastKnown { return h }
        if let p = link.session.me?.position { return LatLon(lat: p.latitude, lon: p.longitude) }
        // Practice without location access: stand at the pretend park.
        return link.isDemo ? Self.practiceHere : nil
    }

    /// Where "you" stand in practice when the phone's location is unknown (the demo park).
    static let practiceHere = LatLon(lat: 37.7672, lon: -122.4880)

    private var placed: [MeshCore.Contact] { link.session.contacts.values.filter { $0.position != nil } }

    private var mtPlaced: [NodeInfo] {
        bothNetworks ? radio.session.nodes.values.filter { $0.position != nil && !$0.isIgnored && $0.num != radio.session.myNode } : []
    }

    var body: some View {
        let mc = showMeshCore ? placed : []
        let mt = showMeshtastic ? mtPlaced : []
        let here = here
        let rings = MeshCoreFormat.rings(farthest: farthest(here))
        Map(selection: $selected) {
            if let here, showRange {
                ForEach(rings, id: \.self) { r in
                    MapCircle(center: here.coordinate, radius: r)
                        .foregroundStyle(Theme.textPrimary.opacity(0.02))
                        .stroke(Theme.textPrimary.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [4, 5]))
                    Annotation("", coordinate: Geo.offset(here, distance: r, bearing: 0).coordinate, anchor: .bottom) {
                        Text(Geo.format(r))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.bottom, 2)
                    }
                }
            }
            if let here, let target = selectedCoordinate {
                MapPolyline(coordinates: [here.coordinate, target.coordinate])
                    .stroke(selectedColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            if let here {
                Annotation("You", coordinate: here.coordinate) {
                    Circle().fill(Theme.textPrimary).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                        .background(Circle().fill(Theme.textPrimary.opacity(0.15)).frame(width: 30, height: 30))
                }
                .annotationTitles(.hidden)
            } else {
                UserAnnotation().tint(Theme.textPrimary)
            }
            ForEach(mt, id: \.num) { n in
                if let p = n.position {
                    Annotation(n.shortName ?? n.num.short, coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                        pin(network: .meshtastic, diamond: false, selected: selected == .meshtastic(n.num),
                            name: n.shortName ?? n.num.short,
                            sub: n.hopsAway.map(MeshCoreFormat.hops))
                    }
                    .annotationTitles(.hidden)
                    .tag(Pick.meshtastic(n.num))
                }
            }
            ForEach(mc, id: \.publicKey) { c in
                if let p = c.position {
                    Annotation(MeshCoreFormat.name(c), coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                        pin(network: .meshcore, diamond: MeshCoreFormat.isInfrastructure(c.kind), selected: selected == .meshcore(c.publicKey),
                            name: MeshCoreFormat.name(c), sub: pinSub(c))
                    }
                    .annotationTitles(.hidden)
                    .tag(Pick.meshcore(c.publicKey))
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        .onChange(of: selected) { _, new in if new != nil { Haptics.tap() } }
        .safeAreaInset(edge: .top) { filters(mc: placed.count, mt: mtPlaced.count) }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if placed.isEmpty && mtPlaced.isEmpty {
                    Notice(text: "No nodes share a position yet. Nodes appear once their adverts include where they are.",
                           symbol: "mappin.slash")
                        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
                }
                readout
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .animation(Theme.Motion.settle, value: selected)
        }
        .navigationTitle(bothNetworks ? "Both networks" : "MeshCore map")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { explore.begin(asking: false) }
        .onDisappear { explore.end() }
    }

    private func farthest(_ here: LatLon?) -> Double {
        guard let here else { return 0 }
        let mc = placed.compactMap(\.position)
        let mt = mtPlaced.compactMap(\.position)
        return (mc + mt).map { Geo.distance(here, LatLon(lat: $0.latitude, lon: $0.longitude)) }.max() ?? 0
    }

    private func pinSub(_ c: MeshCore.Contact) -> String? {
        let hops = c.pathLength.map(MeshCoreFormat.hops)
        let snr = feed.signal(meshcore: c.publicKey).map { MeshCoreFormat.db($0.snr) }
        let parts = [hops, snr].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A dot (people) or diamond (repeaters) in the network's colour, labelled to its right.
    private func pin(network: MeshNetwork, diamond: Bool, selected: Bool, name: String, sub: String?) -> some View {
        ZStack {
            if selected {
                Circle().strokeBorder(network.color, lineWidth: 1.5).frame(width: 28, height: 28)
            }
            Group {
                if diamond {
                    RoundedRectangle(cornerRadius: 2).fill(network.color).frame(width: 11, height: 11).rotationEffect(.degrees(45))
                } else {
                    Circle().fill(network.color).frame(width: 12, height: 12)
                }
            }
            .overlay {
                if diamond {
                    RoundedRectangle(cornerRadius: 2).stroke(Theme.bg, lineWidth: 1.5).frame(width: 11, height: 11).rotationEffect(.degrees(45))
                } else {
                    Circle().stroke(Theme.bg, lineWidth: 1.5)
                }
            }
        }
        .frame(width: 30, height: 30)
        .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let sub { Text(sub).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary) }
            }
            .lineLimit(1)
            .fixedSize()
            .shadow(color: .black.opacity(0.9), radius: 2)
            .offset(x: 26)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }

    private func filters(mc: Int, mt: Int) -> some View {
        HStack(spacing: 6) {
            filterChip("MeshCore", count: mc, color: Theme.meshcore, on: $showMeshCore)
            if bothNetworks { filterChip("Meshtastic", count: mt, color: Theme.meshtastic, on: $showMeshtastic) }
            filterChip("Range", count: nil, color: nil, on: $showRange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func filterChip(_ title: String, count: Int?, color: Color?, on: Binding<Bool>) -> some View {
        Button {
            on.wrappedValue.toggle()
            Haptics.tap()
        } label: {
            HStack(spacing: 6) {
                if let color { Circle().fill(on.wrappedValue ? color : Theme.textQuaternary).frame(width: 7, height: 7) }
                Text(title).font(.system(.subheadline)).foregroundStyle(on.wrappedValue ? Theme.textPrimary : Theme.textTertiary)
                if let count { Text("\(count)").font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textTertiary) }
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(Theme.surface1.opacity(0.94), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }

    // MARK: Selection

    private var selectedCoordinate: LatLon? {
        switch selected {
        case .meshcore(let key)?: return link.session.contacts[key]?.position.map { LatLon(lat: $0.latitude, lon: $0.longitude) }
        case .meshtastic(let num)?: return radio.session.nodes[num]?.position.map { LatLon(lat: $0.latitude, lon: $0.longitude) }
        case nil: return nil
        }
    }

    private var selectedColor: Color {
        if case .meshtastic? = selected { return Theme.meshtastic }
        return Theme.meshcore
    }

    /// The tapped node as an instrument card: bearing, distance, hops, signal, then what you can do.
    @ViewBuilder private var readout: some View {
        switch selected {
        case .meshcore(let key)?:
            if let c = link.session.contacts[key] {
                let s = feed.signal(meshcore: key)
                MapReadoutCard(
                    network: .meshcore, glyph: MeshCoreGlyph(kind: c.kind, size: 38), name: MeshCoreFormat.name(c),
                    line: MeshCoreFormat.roleLine(c.kind), here: here, there: selectedCoordinate,
                    hops: c.pathLength, hopsSub: c.pathLength.map { $0 == 0 ? "direct" : "via \($0) rpt" } ?? "no route",
                    snr: s?.snr, rssi: s?.rssi,
                    raw: [c.shortID, s?.rssi.map { "RSSI \(MeshCoreFormat.minus("\($0)")) dBm" },
                          c.pathLength.flatMap { $0 > 0 ? "path " + MeshCoreFormat.pathHashes(c).map(MeshCoreFormat.hex).joined(separator: "›") : nil }]
                        .compactMap { $0 }.joined(separator: " · "),
                    close: { selected = nil }
                ) {
                    mapActions(c)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .meshtastic(let num)?:
            if let n = radio.session.nodes[num] {
                MapReadoutCard(
                    network: .meshtastic, glyph: IconTile(symbol: MeshNetwork.meshtastic.symbol, tint: Theme.meshtastic, size: 38),
                    name: n.longName ?? n.shortName ?? n.num.short, line: "A Meshtastic node", here: here, there: selectedCoordinate,
                    hops: n.hopsAway, hopsSub: n.hopsAway.map { $0 == 0 ? "direct" : "relayed" } ?? "unknown",
                    snr: n.snr.map(Double.init), rssi: nil,
                    raw: [n.num.id, n.hardware].compactMap { $0 }.joined(separator: " · "),
                    close: { selected = nil }
                ) {
                    NavigationLink { NodeDetailView(num: num) } label: {
                        Label("Details", systemImage: "info.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.field(.primary, .regular))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func mapActions(_ c: MeshCore.Contact) -> some View {
        let canMessage = c.kind == .chat || c.kind == .room
        let infra = MeshCoreFormat.isInfrastructure(c.kind)
        if canMessage {
            NavigationLink { MeshCoreChatView(origin: .contact(c.prefix)) } label: {
                Label("Message", systemImage: "bubble.left").frame(maxWidth: .infinity)
            }
            .buttonStyle(.field(.primary, .regular))
        }
        if infra {
            NavigationLink { MeshCoreTraceView(key: c.publicKey) } label: {
                Label("Trace", systemImage: "point.topleft.down.to.point.bottomright.curvepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.field(canMessage ? .secondary : .primary, .regular))
        }
        NavigationLink { MeshCoreContactDetail(key: c.publicKey) } label: {
            if canMessage || infra {
                Image(systemName: "info.circle").frame(width: 24)
            } else {
                Label("Details", systemImage: "info.circle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.field(canMessage || infra ? .secondary : .primary, .regular))
        .fixedSize(horizontal: canMessage || infra, vertical: false)
        .accessibilityLabel("Details")
    }
}

/// The card under a map for the selected node (AB map readout).
struct MapReadoutCard<Glyph: View, Actions: View>: View {
    let network: MeshNetwork
    let glyph: Glyph
    let name: String
    let line: String
    let here: LatLon?
    let there: LatLon?
    let hops: Int?
    let hopsSub: String
    let snr: Double?
    let rssi: Int?
    let raw: String
    let close: () -> Void
    @ViewBuilder var actions: Actions

    init(network: MeshNetwork, glyph: Glyph, name: String, line: String, here: LatLon?, there: LatLon?, hops: Int?,
         hopsSub: String, snr: Double?, rssi: Int?, raw: String, close: @escaping () -> Void,
         @ViewBuilder actions: () -> Actions) {
        self.network = network
        self.glyph = glyph
        self.name = name
        self.line = line
        self.here = here
        self.there = there
        self.hops = hops
        self.hopsSub = hopsSub
        self.snr = snr
        self.rssi = rssi
        self.raw = raw
        self.close = close
        self.actions = actions()
    }

    var body: some View {
        let bearing = here.flatMap { h in there.map { Geo.bearing(h, $0) } }
        let distance = here.flatMap { h in there.map { Geo.distance(h, $0) } }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(name).font(.system(.title3, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        NetworkTag(network)
                    }
                    Text(line).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(12)
            PanelDivider()
            ReadoutRow {
                ReadoutCell("Bearing", value: bearing.map { String(format: "%03.0f", $0) } ?? "—", unit: bearing == nil ? nil : "°",
                            sub: bearing.map(Geo.compass) ?? "no position")
                CellDivider()
                ReadoutCell("Dist", value: distance.map(MeshCoreFormat.distanceValue) ?? "—",
                            unit: distance.map(MeshCoreFormat.distanceUnit), sub: "straight line")
                CellDivider()
                ReadoutCell("Hops", value: hops.map { "\($0)" } ?? "—", sub: hopsSub)
                CellDivider()
                ReadoutCell("SNR", value: snr.map { MeshCoreFormat.number($0, digits: 1) } ?? "—") {
                    HStack(spacing: 5) {
                        SegmentMeter(lit: SignalGrade.bars(snr: snr, rssi: rssi), of: 5, tint: network.color, size: .xs)
                        Text(SignalGrade.grade(snr: snr, rssi: rssi).word).font(.caption).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            if !raw.isEmpty {
                PanelDivider()
                Text(raw).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) { actions }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, raw.isEmpty ? 12 : 0)
        }
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }
}

// MARK: - Settings

/// Everything about your own MeshCore node, in the same order as Meshtastic's
/// node settings: Setup, This node, Name, Radio, Position, Adverts, Telemetry,
/// Delivery, Channels, Danger zone. Each change is checked against what the node reports back.
struct MeshCoreSettingsView: View {
    @Environment(MeshCoreLink.self) private var link
    @State private var apply = MeshCoreApply()
    @State private var name = ""
    @State private var power = 22
    @State private var freq = ""
    @State private var bw = ""
    @State private var sf = 7
    @State private var cr = 5
    @State private var confirmReboot = false
    @State private var confirmClear = false
    @State private var pin = ""
    @State private var locating = false
    @State private var loaded = false

    var body: some View {
        Form {
            if let me = link.session.me {
                statusSection
                Section { header(me) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                setupSection(me)
                nodeSection(me)
                nameSection(me)
                radioSection(me)
                positionSection(me)
                advertSection(me)
                telemetrySection(me)
                deliverySection(me)
                channelSection
                FirmwareSection(network: .meshcore, number: 10)
                dangerSection
            } else {
                Text("Connect a MeshCore node first.")
            }
        }
        .fieldForm()
        .navigationTitle("MeshCore node")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .onChange(of: link.session.me) { _, _ in load(force: true) }
        .confirmationDialog("Reboot the node?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { link.reboot() }
        } message: { Text("It disconnects; reconnect in about 20 seconds.") }
        .confirmationDialog("Clear this node's position?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear position", role: .destructive) {
                save([MeshCoreApply.clearPosition] + (link.session.me?.advertLocationPolicy != 0 ? [MeshCoreApply.sharesPosition(false)] : []),
                     "Position cleared.")
            }
        } message: { Text("Its adverts stop carrying a position, so it drops off other people's maps after their next update.") }
    }

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        switch apply.status {
        case .idle: EmptyView()
        case .working(let t):
            Section { HStack(spacing: 10) { ProgressView().tint(Theme.textSecondary); Text(t).font(Theme.Fonts.data) } }.fieldSection()
        case .done(let t):
            Section { Notice(text: t, color: Theme.ok, symbol: "checkmark.circle") }.fieldSection()
        case .failed(let t):
            Section { Notice(text: t, color: Theme.alert, symbol: "exclamationmark.triangle") }.fieldSection()
        }
    }

    private func header(_ me: MeshCore.SelfInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: MeshNetwork.meshcore.symbol, tint: Theme.meshcore, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(me.name.isEmpty ? "Your node" : me.name)
                            .font(.system(.title3, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        NetworkTag(.meshcore)
                    }
                    Text(["Companion", MeshCoreFormat.hex(me.publicKey.prefix(4)), link.session.device.map { "fw \($0.version)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            RadioChips(frequency: me.frequency, bandwidth: me.bandwidth, spreadingFactor: me.spreadingFactor,
                       codingRate: me.codingRate, txPower: me.txPower)
        }
        .padding(14)
        .instrumentPanel()
    }

    private func setupSection(_ me: MeshCore.SelfInfo) -> some View {
        let needs = MeshCoreSetupCheck.needsSetup(me)
        return Section {
            if needs {
                Notice(text: (MeshCoreSetupCheck.line(me) ?? "") + ". Setup picks your mesh's preset, a name, your position and a first channel.",
                       symbol: "wand.and.stars")
            }
            NavigationLink { MeshCoreSetupView() } label: {
                Label(needs ? "Set up this node" : "Run setup again", systemImage: "wand.and.stars")
                    .foregroundStyle(needs ? Theme.alert : Theme.textPrimary)
            }
        } header: { ModuleHeader(1, "Setup") } footer: {
            Text("Create the network: radio preset, name, position, a private channel and a first advert, step by step.")
        }
        .fieldSection()
    }

    private func nodeSection(_ me: MeshCore.SelfInfo) -> some View {
        Section {
            LabeledContent("Public key") { Text(MeshCoreFormat.hex(me.publicKey.prefix(6)) + "…").font(Theme.Fonts.data) }
            if let d = link.session.device {
                LabeledContent("Firmware") { Text(d.version).font(Theme.Fonts.data) }
                LabeledContent("Board") { Text(d.manufacturer).font(Theme.Fonts.data) }
            }
            HStack {
                TextField("New 6-digit Bluetooth PIN", text: $pin).keyboardType(.numberPad)
                Button("Set PIN") { if let p = UInt32(pin), (100000...999999).contains(p) { link.setPIN(p); pin = ""; Haptics.success() } }
                    .disabled(UInt32(pin).map { !(100000...999999).contains($0) } ?? true)
            }
        } header: { ModuleHeader(2, "This node") } footer: {
            Text("The PIN is what your phone asks for when it pairs with the node.")
        }
        .fieldSection()
    }

    private func nameSection(_ me: MeshCore.SelfInfo) -> some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return Section {
            TextField("Name", text: $name)
                .onChange(of: name) { _, v in
                    let c = MeshCoreNodeLimits.clamp(v)
                    if c != v { name = c }
                }
            saveButton("Save name", disabled: trimmed.isEmpty || trimmed == me.name) {
                [MeshCoreApply.name(trimmed)]
            }
        } header: { ModuleHeader(3, "Name", detail: "\(name.utf8.count)/\(MeshCoreNodeLimits.maxNameBytes) bytes") } footer: {
            Text("What other people see in their contacts and on maps; it travels in every advert.")
        }
        .fieldSection()
    }

    private func radioSection(_ me: MeshCore.SelfInfo) -> some View {
        let f = Double(freq), b = Double(bw)
        let valid = f.flatMap { f in b.map { MeshCoreNodeLimits.isValidRadio(frequency: f, bandwidth: $0, spreadingFactor: sf, codingRate: cr) } } ?? false
        let typed = f.flatMap { f in b.flatMap { MeshCorePresets.label(frequency: f, bandwidth: $0, spreadingFactor: sf, codingRate: cr) } }
        return Section {
            Menu {
                ForEach(MeshCorePresets.all) { p in
                    Button(p.title + (p.deprecated ? " (deprecated)" : "")) {
                        freq = String(format: "%.3f", p.frequency); bw = OwnedNode.trim(p.bandwidth)
                        sf = p.spreadingFactor; cr = p.codingRate
                    }
                }
            } label: {
                LabeledContent("Preset") {
                    HStack(spacing: 6) {
                        Text(typed ?? "Custom").foregroundStyle(typed == nil ? Theme.amber : Theme.textSecondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            LabeledContent("Frequency (MHz)") { TextField("910.525", text: $freq).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Bandwidth (kHz)") { TextField("62.5", text: $bw).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            Stepper("Spreading factor: \(sf)", value: $sf, in: 5...12)
            Stepper("Coding rate: 4/\(cr)", value: $cr, in: 5...8)
            if f != nil, b != nil, !valid {
                Text("Bandwidth must be one LoRa supports (\(MeshCoreNodeLimits.bandwidths.map(OwnedNode.trim).joined(separator: ", ")) kHz), frequency 150–2500 MHz.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.alert)
            }
            saveButton("Save radio settings", disabled: !radioChanged(me) || !valid) {
                guard let f, let b else { return [] }
                return [MeshCoreApply.radio((f, b, sf, cr))]
            }
            Stepper("Transmit power: \(MeshCoreFormat.minus("\(power)")) dBm", value: $power, in: -9...max(me.maxTxPower, 1))
            saveButton("Save transmit power", disabled: power == me.txPower) { [MeshCoreApply.txPower(power)] }
        } header: { ModuleHeader(4, "Radio", detail: MeshCorePresets.match(me, regionCode: Locale.current.region?.identifier)?.title ?? "custom") } footer: {
            Text("Every node you want to talk to must use the same frequency, bandwidth, spreading factor and coding rate. Presets are MeshCore's community presets; most US meshes use USA.")
        }
        .fieldSection()
    }

    private func positionSection(_ me: MeshCore.SelfInfo) -> some View {
        Section {
            LabeledContent("Position") {
                Text(me.position.map { MeshCoreFormat.minus(String(format: "%.5f, %.5f", $0.latitude, $0.longitude)) } ?? "not set")
                    .font(Theme.Fonts.data)
            }
            Button(locating ? "Finding you…" : "Set position to where I am") {
                locating = true
                Task {
                    let l = await LocationOnce().get()
                    locating = false
                    guard let l else { apply.fail("Wildcat couldn't get this phone's location."); return }
                    save([MeshCoreApply.position(Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude))], "Position set.")
                }
            }
            .disabled(locating || apply.isWorking)
            Toggle("Share position in adverts", isOn: Binding(
                get: { me.advertLocationPolicy != 0 }, set: { save([MeshCoreApply.sharesPosition($0)], $0 ? "Adverts now carry the position." : "Adverts no longer carry the position.") }))
            Button("Clear position", role: .destructive) { confirmClear = true }
                .disabled(me.position == nil || apply.isWorking)
        } header: { ModuleHeader(5, "Position") } footer: {
            Text("Shared positions put this node on other people's maps. Clear removes the stored position and stops sharing it.")
        }
        .fieldSection()
    }

    private func advertSection(_ me: MeshCore.SelfInfo) -> some View {
        Section {
            Button { link.advertise(flood: true); apply.finish("Advert sent to the whole mesh."); Haptics.success() } label: {
                Label("Send advert to the whole mesh", systemImage: "megaphone")
            }
            Button { link.advertise(flood: false); apply.finish("Advert sent to nodes in range."); Haptics.success() } label: {
                Label("Send advert to nodes in range only", systemImage: "dot.radiowaves.left.and.right")
            }
            Toggle("Add contacts automatically", isOn: Binding(
                get: { me.manualAddContacts & 1 == 0 },
                set: { on in save([MeshCoreApply.other(on ? "Auto-add on" : "Auto-add off") {
                    $0.manualAddContacts = on ? ($0.manualAddContacts & ~1) : ($0.manualAddContacts | 1)
                }], on ? "New nodes become contacts automatically." : "New nodes wait for you to add them.") }))
        } header: { ModuleHeader(6, "Adverts") } footer: {
            Text("An advert tells nodes your name and key so they can add you. Whole mesh: repeaters pass it on. In range: only radios that hear yours directly (zero hop), lighter on the mesh. Auto-add: every node whose advert yours hears becomes a contact.")
        }
        .fieldSection()
    }

    private func telemetrySection(_ me: MeshCore.SelfInfo) -> some View {
        let modes = MeshCoreTelemetryMode.Modes(byte: me.telemetryModes)
        return Section {
            telemetryPicker("Battery", modes.base) { var m = modes; m.base = $0; return m }
            telemetryPicker("Location", modes.location) { var m = modes; m.location = $0; return m }
            telemetryPicker("Sensors", modes.environment) { var m = modes; m.environment = $0; return m }
        } header: { ModuleHeader(7, "Telemetry") } footer: {
            Text("Who may ask this node for readings: battery voltage, its position, and sensors like temperature. \"Contacts I allow\" means contacts you've given permission in the MeshCore app.")
        }
        .fieldSection()
    }

    private func telemetryPicker(_ title: String, _ value: MeshCoreTelemetryMode,
                                 _ change: @escaping (MeshCoreTelemetryMode) -> MeshCoreTelemetryMode.Modes) -> some View {
        Picker(title, selection: Binding(get: { value }, set: { new in
            let byte = change(new).byte
            save([MeshCoreApply.other("\(title) telemetry") { $0.telemetryModes = byte }], "\(title) telemetry: \(new.title.lowercased()).")
        })) {
            ForEach(MeshCoreTelemetryMode.allCases) { Text($0.title).tag($0) }
        }
        .disabled(apply.isWorking)
    }

    private func deliverySection(_ me: MeshCore.SelfInfo) -> some View {
        Section {
            Toggle("Extra delivery confirmations", isOn: Binding(
                get: { me.multiAcks != 0 },
                set: { on in save([MeshCoreApply.other(on ? "Extra acks on" : "Extra acks off") { $0.multiAcks = on ? 1 : 0 }],
                                  on ? "Extra acks on." : "Extra acks off.") }))
        } header: { ModuleHeader(8, "Delivery") } footer: {
            Text("Sends each \"got it\" for a direct message twice, so fewer messages look failed on a busy mesh. Costs a little airtime.")
        }
        .fieldSection()
    }

    private var channelSection: some View {
        let s = link.session
        return Section {
            NavigationLink { MeshCoreChannelsView() } label: {
                LabeledContent("Channels") { Text("\(s.channels.count) of \(s.device?.maxChannels ?? 8)").font(Theme.Fonts.data) }
            }
        } header: { ModuleHeader(9, "Channels") } footer: {
            Text("Create, join, rename, share and delete channels. Shares use the MeshCore app's link and QR format.")
        }
        .fieldSection()
    }

    private var dangerSection: some View {
        Section {
            Button("Reboot node", role: .destructive) { confirmReboot = true }
                .buttonStyle(.field(.destructive, .regular))
            Button("Disconnect", role: .destructive) { link.disconnect() }
                .foregroundStyle(Theme.alert)
        } header: { ModuleHeader(11, "Danger zone") } footer: {
            Text("Reboot restarts the node (reconnect in about 20 seconds). Disconnect only stops Wildcat listening; the node keeps running.")
        }
        .fieldSection()
    }

    // MARK: Helpers

    private func saveButton(_ title: String, disabled: Bool, _ steps: @escaping () -> [MeshCoreApply.Step]) -> some View {
        Button(title) { save(steps(), title.replacingOccurrences(of: "Save ", with: "").capitalizedFirst + " saved.") }
            .buttonStyle(.field(.primary, .regular))
            .disabled(disabled || apply.isWorking)
    }

    private func save(_ steps: [MeshCoreApply.Step], _ summary: String) {
        Task {
            if await apply.run(steps, on: link, summary: summary) { Haptics.success() } else { Haptics.error() }
        }
    }

    private func load(force: Bool = false) {
        guard let me = link.session.me, force || !loaded else { return }
        loaded = true
        name = me.name
        power = me.txPower
        freq = String(format: "%.3f", me.frequency)
        bw = OwnedNode.trim(me.bandwidth)
        sf = me.spreadingFactor
        cr = me.codingRate
    }

    private func radioChanged(_ me: MeshCore.SelfInfo) -> Bool {
        guard let f = Double(freq), let b = Double(bw) else { return false }
        return abs(f - me.frequency) > 0.0005 || abs(b - me.bandwidth) > 0.005 || sf != me.spreadingFactor || cr != me.codingRate
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Formatting

enum MeshCoreFormat {
    static func symbol(_ k: MeshCore.Contact.Kind) -> String {
        switch k {
        case .repeater: return "antenna.radiowaves.left.and.right"
        case .room: return "bubble.left.and.bubble.right"
        case .sensor: return "sensor"
        default: return "person"
        }
    }

    static func kind(_ k: MeshCore.Contact.Kind) -> String {
        switch k {
        case .chat: return "Companion"
        case .repeater: return "Repeater"
        case .room: return "Room server"
        case .sensor: return "Sensor"
        case .none: return "Node"
        }
    }

    /// Repeaters and room servers: the radios that carry other people's messages.
    static func isInfrastructure(_ k: MeshCore.Contact.Kind) -> Bool { k == .repeater || k == .room }

    static func name(_ c: MeshCore.Contact) -> String { c.name.isEmpty ? c.shortID : c.name }

    /// "direct", "1 hop", "3 hops".
    static func hops(_ n: Int) -> String { n <= 0 ? "direct" : n == 1 ? "1 hop" : "\(n) hops" }

    static func subtitle(_ c: MeshCore.Contact) -> String {
        let hops = c.pathLength.map(Self.hops) ?? "no route yet"
        let seen = c.lastAdvert.map { " · heard " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return "\(kind(c.kind).lowercased()) · \(hops)\(seen)"
    }

    /// "Direct · strong signal · 1 min ago": route, signal word, age.
    static func line(_ c: MeshCore.Contact, signal: PacketFeed.NodeSignal?, now: Date = Date()) -> String {
        var parts = [c.pathLength.map { $0 == 0 ? "Direct" : "\($0) hop\($0 == 1 ? "" : "s")" } ?? "No route yet"]
        if let signal { parts.append(SignalGrade.grade(snr: signal.snr, rssi: signal.rssi).word + " signal") }
        let at = [signal?.at, c.lastAdvert].compactMap { $0 }.max()
        parts.append(at.map { ago($0, now: now) } ?? "not heard yet")
        return parts.joined(separator: " · ")
    }

    /// One short line on what a node is, for a map card.
    static func roleLine(_ k: MeshCore.Contact.Kind) -> String {
        switch k {
        case .chat: return "A person you can message"
        case .repeater: return "A repeater: passes messages along"
        case .room: return "A room server: a board you can post to"
        case .sensor: return "A sensor: reports readings"
        case .none: return "A MeshCore node"
        }
    }

    static func roleQuestion(_ k: MeshCore.Contact.Kind) -> String {
        switch k {
        case .chat: return "What is a companion?"
        case .repeater: return "What is a repeater?"
        case .room: return "What is a room server?"
        case .sensor: return "What is a sensor?"
        case .none: return "What is this node?"
        }
    }

    static func roleAnswer(_ k: MeshCore.Contact.Kind) -> String {
        switch k {
        case .chat:
            return "A radio someone carries and chats from, like yours. It never passes other people's messages along; repeaters do that."
        case .repeater:
            return "A radio on a hill or roof that passes messages along so they travel farther. It doesn't chat, but you can trace through it or manage it with its password."
        case .room:
            return "A repeater that also keeps a message board. Log in to read what was posted while you were away, and post to everyone who joins it."
        case .sensor:
            return "A radio that reports readings, like temperature or a battery level. It doesn't chat or repeat."
        case .none:
            return "Its advert didn't say what kind of node it is."
        }
    }

    // MARK: Numbers

    /// A number with a true minus sign.
    static func minus(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "−") }

    static func number(_ v: Double, digits: Int = 1) -> String {
        guard v.isFinite else { return "—" }
        return minus(v.formatted(.number.precision(.fractionLength(0...max(0, digits)))))
    }

    /// "9.5 dB", "−3.25 dB".
    static func db(_ snr: Double) -> String { number(snr, digits: 2) + " dB" }

    static func volts(_ millivolts: Int) -> String { String(format: "%.2f", Double(millivolts) / 1000) }

    /// A rough charge level for a single Li-ion cell: 3.3 V empty, 4.2 V full.
    static func batteryPercent(millivolts mv: Int) -> Int? {
        guard mv > 2500, mv < 6000 else { return nil }
        let p = (Double(mv) - 3300) / (4200 - 3300) * 100
        return Int(max(0, min(100, p)).rounded())
    }

    static func distanceValue(_ m: Double) -> String {
        m < 1000 ? "\(Int(m.rounded()))" : String(format: m < 10_000 ? "%.1f" : "%.0f", m / 1000)
    }

    static func distanceUnit(_ m: Double) -> String { m < 1000 ? "m" : "km" }

    /// "42 s ago", "3 min ago", "2 h ago", "4 d ago" (or without "ago" when `short`).
    static func ago(_ date: Date, now: Date = Date(), short: Bool = false) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        let text: String
        if s < 5 { return short ? "now" : "just now" }
        else if s < 60 { text = "\(s) s" }
        else if s < 3600 { text = "\(s / 60) min" }
        else if s < 86_400 { text = "\(s / 3600) h" }
        else { text = "\(s / 86_400) d" }
        return short ? text : text + " ago"
    }

    /// "12d 3h", "4h 10m", "9m", "30s".
    static func duration(_ secs: UInt32) -> String {
        let s = Int(secs)
        if s >= 86_400 { return "\(s / 86_400)d \(s % 86_400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// A contact's route, one hash per repeater.
    static func pathHashes(_ c: MeshCore.Contact) -> [Data] {
        guard let n = c.pathLength, n > 0, !c.path.isEmpty else { return [] }
        let size = max(1, c.pathHashSize)
        let bytes = [UInt8](c.path)
        return stride(from: 0, to: bytes.count, by: size).prefix(n).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
    }

    /// Range rings around you: three evenly spaced rings that reach past the farthest node.
    static func rings(farthest: Double) -> [Double] {
        let steps: [Double] = [250, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000]
        let step = steps.first { $0 * 3 >= farthest } ?? steps[steps.count - 1]
        return [step, step * 2, step * 3]
    }

    /// Packets per minute over the last `minutes` minutes, oldest first.
    static func activity(_ times: [Date], now: Date, minutes: Int) -> [Double] {
        let n = max(1, minutes)
        var bins = [Double](repeating: 0, count: n)
        for t in times {
            let age = now.timeIntervalSince(t)
            guard age >= 0, age < Double(n) * 60 else { continue }
            bins[n - 1 - min(n - 1, Int(age / 60))] += 1
        }
        return bins
    }

    // MARK: Lists

    enum Sort: String, CaseIterable {
        case signal, recent, name

        var title: String {
            switch self {
            case .signal: return "Signal"
            case .recent: return "Recent"
            case .name: return "Name"
            }
        }
    }

    static func sorted(_ contacts: [MeshCore.Contact], by sort: Sort,
                       signal: (Data) -> PacketFeed.NodeSignal?) -> [MeshCore.Contact] {
        contacts.sorted { a, b in
            switch sort {
            case .signal:
                let sa = signal(a.publicKey)?.snr ?? -.infinity, sb = signal(b.publicKey)?.snr ?? -.infinity
                if sa != sb { return sa > sb }
            case .recent:
                let ta = [a.lastAdvert, signal(a.publicKey)?.at].compactMap { $0 }.max() ?? .distantPast
                let tb = [b.lastAdvert, signal(b.publicKey)?.at].compactMap { $0 }.max() ?? .distantPast
                if ta != tb { return ta > tb }
            case .name:
                break
            }
            return name(a).localizedCaseInsensitiveCompare(name(b)) == .orderedAscending
        }
    }

    /// Nodes heard in the last day (all of them if none are that fresh, e.g. a node that just booted).
    static func heardRecently(_ contacts: [MeshCore.Contact], now: Date = Date(), within: TimeInterval = 86_400) -> [MeshCore.Contact] {
        contacts.filter { $0.lastAdvert.map { now.timeIntervalSince($0) < within } ?? false }
    }

    /// The plain sentence on the node card.
    static func summary(heard: Int, repeaters: Int, batteryMillivolts: Int?) -> (lead: String, bold: String, rest: String) {
        if let mv = batteryMillivolts, let p = batteryPercent(millivolts: mv), p < 15 {
            return ("Battery low. ", "Charge it soon", " (\(p)%), or it will drop off the mesh.")
        }
        if heard == 0 { return ("Connected. ", "Nothing heard yet", ": send an advert so nodes nearby add you.") }
        let nodes = "Hearing \(heard) node\(heard == 1 ? "" : "s")"
        switch repeaters {
        case 0: return ("All good. ", nodes, ", no repeaters, so messages only reach radios in range.")
        case heard: return ("All good. ", nodes, heard == 1 ? ", a repeater." : ", all of them repeaters.")
        default: return ("All good. ", nodes, ", \(repeaters) of them repeater\(repeaters == 1 ? "" : "s").")
        }
    }

    /// The name of the MeshCore preset these settings match ("USA / Canada"), if any.
    static func presetName(frequency: Double, bandwidth: Double, spreadingFactor: Int, codingRate: Int) -> String? {
        MeshCorePresets.label(frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate)
    }

    // MARK: My Mesh

    static func ownedID(_ c: MeshCore.Contact) -> String { OwnedNode.id(.meshcore, OwnedNode.hex(c.prefix)) }

    @MainActor static func isMine(_ c: MeshCore.Contact, in store: MyMeshStore) -> Bool { store.node(ownedID(c)) != nil }

    /// The raw rows as a small JSON object, for "Copy JSON".
    static func json(_ items: [KeyValueItem]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let body = items.map { "  \"\(esc($0.key))\": \"\(esc($0.value))\"" }.joined(separator: ",\n")
        return "{\n\(body)\n}"
    }
}

// MARK: - Repeater admin

/// A repeater's status, ready to show (from the air, or made up in practice).
struct RepeaterReadings: Equatable {
    var batteryMillivolts: Int
    var uptime: UInt32
    var noiseFloor: Int
    var received: UInt32
    var sent: UInt32
    var airtime: UInt32
    var receiveAirtime: UInt32?
    var lastRSSI: Int
    var lastSNR: Double
    var queue: Int
    var duplicates: Int
    var errors: Int

    init(_ s: MeshCore.RepeaterStatus) {
        batteryMillivolts = s.batteryMillivolts
        uptime = s.uptimeSeconds
        noiseFloor = s.noiseFloor
        received = s.packetsReceived
        sent = s.packetsSent
        airtime = s.airtimeSeconds
        receiveAirtime = s.receiveAirtimeSeconds
        lastRSSI = s.lastRSSI
        lastSNR = s.lastSNR
        queue = s.txQueue
        duplicates = s.floodDuplicates + s.directDuplicates
        errors = s.errors
    }

    init(batteryMillivolts: Int, uptime: UInt32, noiseFloor: Int, received: UInt32, sent: UInt32, airtime: UInt32,
         receiveAirtime: UInt32?, lastRSSI: Int, lastSNR: Double, queue: Int, duplicates: Int, errors: Int) {
        self.batteryMillivolts = batteryMillivolts
        self.uptime = uptime
        self.noiseFloor = noiseFloor
        self.received = received
        self.sent = sent
        self.airtime = airtime
        self.receiveAirtime = receiveAirtime
        self.lastRSSI = lastRSSI
        self.lastSNR = lastSNR
        self.queue = queue
        self.duplicates = duplicates
        self.errors = errors
    }

    /// Made-up readings for practice.
    static let practice = RepeaterReadings(batteryMillivolts: 4050, uptime: 12 * 86_400 + 3 * 3600, noiseFloor: -112,
                                           received: 25_310, sent: 18_452, airtime: 35_600, receiveAirtime: 116_000,
                                           lastRSSI: -97, lastSNR: 6.25, queue: 0, duplicates: 412, errors: 0)

    /// Share of its uptime spent transmitting, in percent.
    var airtimePercent: Double? {
        uptime > 0 ? min(100, Double(airtime) / Double(uptime) * 100) : nil
    }

    /// Plain English first: is it healthy, is the channel quiet.
    var summary: String {
        let battery = MeshCoreFormat.batteryPercent(millivolts: batteryMillivolts)
        let channel = noiseFloor <= -105 ? "quiet channel" : noiseFloor <= -95 ? "some noise on the channel" : "noisy channel"
        if let battery, battery < 20 {
            return "Battery low (\(battery)%). It will drop off the mesh soon unless it charges."
        }
        if let a = airtimePercent, a > 10 {
            return "Busy: it spends \(MeshCoreFormat.number(a))% of its time transmitting. Up \(MeshCoreFormat.duration(uptime)), \(channel)."
        }
        return "Healthy: up \(MeshCoreFormat.duration(uptime)), \(channel)\(battery.map { ", battery \($0)%" } ?? "")."
    }
}

/// Log in to a repeater over the air: live status and its command line.
struct MeshCoreRepeaterView: View {
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshCoreStore.self) private var store
    let key: Data
    @State private var password = ""
    @State private var remember = true
    @State private var command = ""
    @State private var waiting: String?
    /// Practice: a pretend login and console (nothing is sent).
    @State private var practice = PracticeAdmin()

    private struct PracticeAdmin {
        var loggedIn = false
        var status: RepeaterReadings?
        var statusAt: Date?
        var lines: [(sent: Bool, text: String)] = []
    }

    private var contact: MeshCore.Contact? { link.session.contacts[key] }

    var body: some View {
        if let c = contact {
            let r = store.repeater(c)
            let loggedIn = link.isDemo ? practice.loggedIn : r.loggedIn
            let isAdmin = link.isDemo ? practice.loggedIn : r.isAdmin
            let status = link.isDemo ? practice.status : r.status.map(RepeaterReadings.init)
            let statusAt = link.isDemo ? practice.statusAt : r.statusAt
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    header(c, loggedIn: loggedIn, isAdmin: isAdmin)
                    if link.isDemo {
                        Notice(text: "Practice: any password works and nothing is sent.", symbol: "figure.walk.motion")
                    }
                    if loggedIn {
                        ModuleHeader(1, "Status") {
                            if let statusAt {
                                (Text("updated ") + Text(statusAt, style: .relative) + Text(" ago"))
                                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        statusPanel(status)
                        if let waiting { progress(waiting) }
                        StatusKeyRow {
                            StatusKey("Refresh", symbol: "arrow.clockwise", primary: true) { refresh(c) }
                            StatusKey("Log out", symbol: "rectangle.portrait.and.arrow.right") { logout(c) }
                        }
                        ModuleHeader(2, "Console")
                        console(c)
                    } else {
                        ModuleHeader(1, "Log in")
                        login(c, failed: !link.isDemo && r.loginFailed)
                        if let status {
                            ModuleHeader(2, "Status", detail: "guest")
                            statusPanel(status)
                        }
                    }
                }
                .padding(Theme.Space.edge)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .screen()
            .navigationTitle(MeshCoreFormat.name(c))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if password.isEmpty, !link.isDemo, let saved = MeshCoreStore.savedPassword(c) { password = saved } }
            .onChange(of: r.loggedIn) { _, ok in
                waiting = nil
                if ok { link.requestStatus(c); waiting = "Asking for status…" }
            }
            .onChange(of: r.loginFailed) { _, failed in if failed { waiting = nil } }
            .onChange(of: r.statusAt) { _, _ in waiting = nil }
        } else {
            Text("This repeater isn't in your contacts any more.").foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).screen()
        }
    }

    private func header(_ c: MeshCore.Contact, loggedIn: Bool, isAdmin: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MeshCoreGlyph(kind: c.kind, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(MeshCoreFormat.name(c)).font(.system(.title, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                HStack(spacing: 6) {
                    Tag(MeshCoreFormat.kind(c.kind))
                    NetworkTag(.meshcore)
                    if loggedIn { Tag(isAdmin ? "Admin" : "Guest", color: isAdmin ? Theme.ok : Theme.textSecondary) }
                }
                HStack(alignment: .top, spacing: 7) {
                    StatusLED(color: Theme.ok, on: loggedIn, size: 7).padding(.top, 6)
                    Text(loggedIn ? "Logged in · " + MeshCoreFormat.subtitle(c) : "Not logged in · " + MeshCoreFormat.subtitle(c))
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.meshcore)
            Text(text).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.row)
    }

    private func login(_ c: MeshCore.Contact, failed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The password travels encrypted to the repeater. It only works when your node can reach it.")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            SecureField("Admin password", text: $password)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .fieldInput()
            if password.count > 15 {
                Text("MeshCore only sends the first 15 characters of a password, so a longer one can't log in from a phone.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.alert)
            }
            if !link.isDemo {
                Toggle("Remember on this phone (Keychain)", isOn: $remember).tint(Theme.meshcore)
                    .font(Theme.Fonts.callout).foregroundStyle(Theme.textPrimary)
            }
            if failed { ToastBanner(text: "Wrong password, or the repeater said no.", kind: .danger) }
            if let waiting { progress(waiting) }
            Button { logIn(c) } label: {
                Label("Log in", systemImage: "key").frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
            .disabled(password.isEmpty || password.count > 15 || !link.state.isReady)
            Button("Check status as a guest") { refresh(c) }
                .buttonStyle(.field(.quiet, .regular))
                .frame(maxWidth: .infinity)
        }
        .panel()
    }

    /// The repeater's health as instrument readouts, the plain summary first.
    @ViewBuilder private func statusPanel(_ s: RepeaterReadings?) -> some View {
        if let s {
            let battery = MeshCoreFormat.batteryPercent(millivolts: s.batteryMillivolts)
            InstrumentPanel {
                Text(s.summary)
                    .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Uptime", value: MeshCoreFormat.duration(s.uptime), size: .large)
                    CellDivider()
                    ReadoutCell("Battery", value: MeshCoreFormat.volts(s.batteryMillivolts), unit: "V", size: .large) {
                        HStack(spacing: 7) {
                            SegmentMeter(value: Double(battery ?? 0) / 100, segments: 10,
                                         tint: (battery ?? 100) < 20 ? Theme.alert : Theme.ok)
                            if let battery { Text("\(battery)%").font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary) }
                        }
                    }
                }
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Noise", value: MeshCoreFormat.minus("\(s.noiseFloor)"), unit: "dBm",
                                sub: s.noiseFloor <= -105 ? "quiet" : s.noiseFloor <= -95 ? "some noise" : "noisy")
                    CellDivider()
                    ReadoutCell("Relayed", value: s.sent.formatted(.number.notation(.compactName)),
                                sub: "heard " + s.received.formatted(.number.notation(.compactName)))
                    CellDivider()
                    ReadoutCell("Airtime", value: s.airtimePercent.map { MeshCoreFormat.number($0) } ?? "—", unit: "%",
                                sub: "tx " + MeshCoreFormat.duration(s.airtime))
                }
                PanelDivider()
                Text(["last RSSI \(MeshCoreFormat.minus("\(s.lastRSSI)")) dBm", "SNR \(MeshCoreFormat.number(s.lastSNR, digits: 2))",
                      "queue \(s.queue)", "dup \(s.duplicates)", "err \(s.errors)",
                      s.receiveAirtime.map { "rx air " + MeshCoreFormat.duration($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        } else {
            Text("No status yet.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
        }
    }

    private func console(_ c: MeshCore.Contact) -> some View {
        let lines: [(id: String, sent: Bool, text: String)] = link.isDemo
            ? practice.lines.enumerated().map { ("p\($0.offset)", $0.element.sent, $0.element.text) }
            : link.session.chats.filter { $0.origin == .contact(c.prefix) && $0.textType == 1 }.suffix(40)
                .map { ($0.id.uuidString, $0.direction == .sent, $0.text) }
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["ver", "get radio", "get tx", "neighbors", "clock", "advert", "powersaving"], id: \.self) { cmd in
                        Button(cmd) { run(c, cmd) }
                            .font(.system(size: 12, design: .monospaced))
                            .buttonStyle(.field(.secondary, .small))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                if lines.isEmpty {
                    Text("Replies appear here. Commands are the same as over USB (see the MeshCore CLI reference).")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                }
                ForEach(lines, id: \.id) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(l.sent ? ">" : " ").foregroundStyle(Theme.meshcore)
                        Text(l.text).foregroundStyle(l.sent ? Theme.textSecondary : Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            HStack {
                TextField("Command", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .fieldInput()
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "return") }
                    .buttonStyle(.field(.primary, .regular))
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send command")
            }
        }
        .panel()
    }

    // MARK: Actions

    private func logIn(_ c: MeshCore.Contact) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if link.isDemo {
            waiting = "Waiting for \(c.name)…"
            Task {
                try? await Task.sleep(for: .seconds(1))
                waiting = nil
                practice.loggedIn = true
                practice.status = .practice
                practice.statusAt = Date()
                Haptics.success()
            }
            return
        }
        MeshCoreStore.savePassword(remember ? password : nil, for: c)
        store.clearLogin(c)
        link.login(c, password: password)
        waiting = "Waiting for \(c.name)… (can take up to 30 s over several hops)"
    }

    private func logout(_ c: MeshCore.Contact) {
        if link.isDemo { practice = PracticeAdmin(); return }
        link.logout(c)
        store.clearLogin(c)
    }

    private func refresh(_ c: MeshCore.Contact) {
        if link.isDemo {
            practice.status = .practice
            practice.statusAt = Date()
            return
        }
        link.requestStatus(c)
        waiting = "Asking for status…"
    }

    private func run(_ c: MeshCore.Contact, _ cmd: String) {
        if link.isDemo {
            practice.lines.append((true, cmd))
            practice.lines.append((false, Self.practiceReply(cmd)))
            return
        }
        link.remoteCommand(c, cmd)
    }

    private func send() {
        guard let c = contact else { return }
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        run(c, cmd)
        command = ""
    }

    static func practiceReply(_ cmd: String) -> String {
        switch cmd {
        case "ver": return "v1.8.2 (practice)"
        case "get radio": return "> 910.525,62.5,7,5"
        case "get tx": return "> 22"
        case "clock": return Date().formatted(date: .numeric, time: .standard)
        case "neighbors": return "1c2a3e:4:6.5\n2a3e51:18:−3.2"
        default: return "OK (practice: nothing was sent)"
        }
    }

    static func duration(_ secs: UInt32) -> String { MeshCoreFormat.duration(secs) }
}

// MARK: - Trace route

/// A trace, ready to draw: every hop on the way out and back, and how well each heard it.
struct TraceReading: Equatable {
    struct Hop: Equatable, Identifiable {
        let id: Int
        let hash: Data
        let snr: Double
    }

    var hops: [Hop]
    /// How well we heard the last hop.
    var finalSNR: Double

    init(_ tr: MeshCore.TraceResult) {
        hops = tr.hops.enumerated().map { Hop(id: $0.offset, hash: $0.element.hash, snr: $0.element.snr) }
        finalSNR = tr.finalSNR
    }

    init(hops: [Hop], finalSNR: Double) {
        self.hops = hops
        self.finalSNR = finalSNR
    }

    /// Practice: out through the contact's route, to it, and back, with made-up readings.
    static func practice(_ c: MeshCore.Contact) -> TraceReading {
        let out = MeshCoreFormat.pathHashes(c)
        let route = out + [Data(c.publicKey.prefix(1))] + out.reversed()
        let hops = route.enumerated().map { i, h in
            Hop(id: i, hash: h, snr: [8.5, -3.25, 6.0, 4.75, 9.25][i % 5])
        }
        return TraceReading(hops: hops, finalSNR: 7.5)
    }

    /// The weakest reading on the route (a hop or our own).
    var weakest: Double { (hops.map(\.snr) + [finalSNR]).min() ?? finalSNR }
}

/// Out to a repeater and back, with how well each hop heard the packet.
struct MeshCoreTraceView: View {
    @Environment(MeshCoreLink.self) private var link
    @Environment(MeshCoreStore.self) private var store
    let key: Data
    @State private var tag: UInt32?
    @State private var sentAt: Date?
    @State private var returnedAt: Date?
    @State private var practiceResult: TraceReading?
    @State private var practiceWaiting = false

    var body: some View {
        if let c = link.session.contacts[key] {
            let result = link.isDemo ? practiceResult : tag.flatMap { store.traces[$0] }.map(TraceReading.init)
            let waiting = link.isDemo ? practiceWaiting : (tag != nil && result == nil)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    HStack(alignment: .top, spacing: 14) {
                        MeshCoreGlyph(kind: c.kind, size: 52)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Trace to \(MeshCoreFormat.name(c))").font(.system(.title2, weight: .bold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.7)
                            HStack(spacing: 6) {
                                Tag(MeshCoreFormat.kind(c.kind))
                                NetworkTag(.meshcore, via: link.session.me?.name)
                            }
                            Text(c.pathLength.map { $0 == 0 ? "In range: the packet goes to it and straight back." : "Via \($0) repeater\($0 == 1 ? "" : "s"), there and back." }
                                 ?? "No known route yet: it's tried directly. Send an advert or message it first if this fails.")
                                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    StatusKeyRow {
                        StatusKey(result == nil && !waiting ? "Trace now" : "Trace again", symbol: "dot.radiowaves.forward", primary: true) {
                            start(c)
                        }
                        .frame(maxWidth: .infinity).layoutPriority(1)
                        .disabled(!link.state.isReady || waiting)
                    }
                    if waiting {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.meshcore)
                            Text("Waiting for the trace to come back…").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel(.row)
                    }
                    if let result {
                        resultView(result, c)
                    } else if !waiting {
                        ExplainerPanel("What does a trace show?",
                                       text: "A small packet goes out along the route to \(MeshCoreFormat.name(c)) and comes back. Every repeater on the way notes how well it heard it, so you can see which link is the weak one.")
                    }
                }
                .padding(Theme.Space.edge)
                .padding(.bottom, Theme.Space.xl)
            }
            .screen()
            .navigationTitle("Trace route")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: result != nil) { _, done in if done, returnedAt == nil { returnedAt = Date(); Haptics.success() } }
        }
    }

    private func start(_ c: MeshCore.Contact) {
        sentAt = Date()
        returnedAt = nil
        if link.isDemo {
            practiceResult = nil
            practiceWaiting = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                practiceResult = .practice(c)
                practiceWaiting = false
            }
        } else {
            tag = link.trace(c)
        }
    }

    private func name(_ hash: Data) -> String {
        let matches = link.session.contacts(hash: hash)
        if matches.count == 1 { return MeshCoreFormat.name(matches[0]) }
        return matches.isEmpty ? "Repeater \(MeshCoreFormat.hex(hash))" : "\(MeshCoreFormat.name(matches[0])) (or \(matches.count - 1) other)"
    }

    @ViewBuilder private func resultView(_ tr: TraceReading, _ c: MeshCore.Contact) -> some View {
        let weakest = tr.weakest
        let seconds = sentAt.flatMap { s in returnedAt.map { $0.timeIntervalSince(s) } }
        ModuleHeader(1, "Summary")
        InstrumentPanel {
            Text(summary(tr))
                .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 11)
            PanelDivider()
            ReadoutRow {
                ReadoutCell("Hops", value: "\(tr.hops.count)", sub: "out and back")
                CellDivider()
                ReadoutCell("Weakest", value: MeshCoreFormat.number(weakest, digits: 2), unit: "dB",
                            tint: SignalGrade.grade(snr: weakest, rssi: nil) == .weak ? Theme.alert : Theme.textPrimary) {
                    SegmentMeter(lit: SignalGrade.bars(snr: weakest, rssi: nil), of: 5, tint: Theme.meshcore, size: .xs)
                }
                CellDivider()
                ReadoutCell("Round trip", value: seconds.map { MeshCoreFormat.number($0) } ?? "—", unit: "s", sub: "or less")
            }
        }
        ModuleHeader(2, "Route", detail: "\(tr.hops.count + 2) stops")
        VStack(spacing: 0) {
            hopRow(0, title: "You", detail: "sent it", snr: nil, symbol: "person", tint: nil, first: true, last: false)
            ForEach(tr.hops) { h in
                let isTarget = c.publicKey.starts(with: h.hash)
                hopRow(h.id + 1, title: isTarget ? MeshCoreFormat.name(c) : name(h.hash), detail: MeshCoreFormat.hex(h.hash),
                       snr: h.snr, symbol: MeshCoreFormat.symbol(isTarget ? c.kind : .repeater), tint: Theme.meshcore,
                       first: false, last: false)
            }
            hopRow(tr.hops.count + 1, title: "You", detail: "heard the last hop", snr: tr.finalSNR, symbol: "person", tint: nil,
                   first: false, last: true)
        }
        .panel(.inset)
        Text("Each number is how well that radio heard the packet from the one before it. Above 0 dB is comfortable; below −10 dB is at the edge.")
            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summary(_ tr: TraceReading) -> String {
        let weakest = tr.weakest
        let grade = SignalGrade.grade(snr: weakest, rssi: nil)
        let db = MeshCoreFormat.db(weakest)
        switch grade {
        case .strong, .ok: return "Made it there and back. Every link is \(grade.word == "strong" ? "strong" : "fine"); the weakest is \(db)."
        default: return "Made it there and back, but one link is weak (\(db)). Messages on this route may need a retry."
        }
    }

    private func hopRow(_ index: Int, title: String, detail: String, snr: Double?, symbol: String, tint: Color?,
                        first: Bool, last: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(String(format: "%02d", index))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textQuaternary)
                .frame(width: 18, alignment: .leading)
            VStack(spacing: 0) {
                Rectangle().fill(first ? Color.clear : Theme.hairlineStrong).frame(width: 1).frame(maxHeight: .infinity)
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tint ?? Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(tint?.opacity(0.4) ?? Theme.hairlineStrong, lineWidth: 1))
                Rectangle().fill(last ? Color.clear : Theme.hairlineStrong).frame(width: 1).frame(maxHeight: .infinity)
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(detail).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let snr {
                VStack(alignment: .trailing, spacing: 4) {
                    SegmentMeter(lit: SignalGrade.bars(snr: snr, rssi: nil), of: 5,
                                 tint: SignalGrade.grade(snr: snr, rssi: nil) == .weak ? Theme.alert : Theme.meshcore)
                    Text(MeshCoreFormat.db(snr)).font(Theme.Fonts.raw)
                        .foregroundStyle(SignalGrade.grade(snr: snr, rssi: nil) == .weak ? Theme.alert : Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .frame(height: 56)
        .accessibilityElement(children: .combine)
    }

    /// SNR in LoRa terms: above 5 is strong, below −10 is at the edge.
    static func color(_ snr: Double) -> Color {
        snr > 5 ? Theme.ok : snr > -5 ? Theme.textPrimary : Theme.alert
    }
}
