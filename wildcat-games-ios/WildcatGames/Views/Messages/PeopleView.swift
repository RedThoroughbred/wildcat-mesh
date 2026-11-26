import SwiftUI
import WildcatRadioCore

/// Everyone Wildcat knows on both networks. People whose names share a first
/// word (usually a call sign, e.g. "MAYA …") are merged into one row.
struct PeopleView: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(Safety.self) private var safety
    @State private var query = ""
    @State private var blocking: Person?

    struct Person: Identifiable {
        var id: String
        var name: String
        var meshtastic: NodeInfo?
        var meshcore: MeshCore.Contact?
        var lastHeard: Date?
    }

    /// First word, upper-cased: call signs and short names line up across networks.
    static func handle(_ name: String?) -> String? {
        guard let first = name?.split(separator: " ").first, first.count >= 3 else { return nil }
        return first.uppercased()
    }

    private var people: [Person] {
        var byHandle: [String: Person] = [:]
        var out: [Person] = []
        let me = radio.session.myNode
        for n in radio.session.nodes.values where n.num != me && !n.isIgnored && !safety.hides(meshtasticNode: n.num.id) {
            let name = n.longName ?? n.shortName ?? n.num.id
            var p = Person(id: "mt:\(n.num.raw)", name: name, meshtastic: n, lastHeard: n.lastHeard)
            if let h = Self.handle(n.longName) ?? Self.handle(n.shortName), byHandle[h] == nil { p.id = "h:\(h)"; byHandle[h] = p }
            out.append(p)
        }
        for c in meshcore.session.contacts.values where c.kind == .chat && !safety.hides(c) {
            if let h = Self.handle(c.name), let existing = byHandle[h], existing.meshcore == nil,
               let i = out.firstIndex(where: { $0.id == existing.id }) {
                out[i].meshcore = c
                out[i].lastHeard = [out[i].lastHeard, c.lastAdvert].compactMap { $0 }.max()
                byHandle[h] = out[i]
            } else {
                out.append(Person(id: "mc:\(MeshCoreStore.hex(c.prefix))", name: c.name, meshcore: c, lastHeard: c.lastAdvert))
            }
        }
        let q = query.lowercased()
        return out.filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                let list = people
                SectionLabel("\(list.count) people", detail: "\(list.filter { $0.meshtastic != nil && $0.meshcore != nil }.count) on both networks")
                ForEach(list) { p in row(p) }
            }
            .padding(Theme.Space.edge)
        }
        .screen()
        .searchable(text: $query)
        .navigationTitle("People")
        .confirmationDialog("Block \(blocking?.name ?? "")?", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                            titleVisibility: .visible, presenting: blocking) { p in
            Button("Block", role: .destructive) {
                if let n = p.meshtastic { safety.block(.node(n)) }
                if let c = p.meshcore { safety.block(.contact(c)) }
                Haptics.thud()
            }
        } message: { _ in
            Text("Hides them on both networks: no messages, no notifications, and the bridge won't relay them. Unblock any time in \(AppMenuView.name) → Safety.")
        }
    }

    private func row(_ p: Person) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: "person", size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if p.meshtastic != nil { Tag(MeshNetwork.meshtastic.short, color: Theme.meshtastic) }
                        if p.meshcore != nil { Tag(MeshNetwork.meshcore.short, color: Theme.meshcore) }
                    }
                    Text(detail(p)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Block \(p.name)", systemImage: "hand.raised", role: .destructive) { blocking = p }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .accessibilityLabel("More for \(p.name)")
            }
            HStack(spacing: 8) {
                if let n = p.meshtastic {
                    NavigationLink { ConversationView(conversation: .direct(n.num.id)) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.meshtastic).frame(width: 6, height: 6)
                            Text("Meshtastic")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.field(.secondary, .small))
                    .disabled(!radio.isReady)
                }
                if let c = p.meshcore {
                    NavigationLink { MeshCoreChatView(origin: .contact(c.prefix)) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.meshcore).frame(width: 6, height: 6)
                            Text("MeshCore")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.field(.secondary, .small))
                    .disabled(!meshcore.state.isReady)
                }
            }
        }
        .panel()
    }

    /// "!a3f9c21e · c41977e2 · heard 5 min ago".
    private func detail(_ p: Person) -> String {
        var parts: [String] = []
        if let n = p.meshtastic { parts.append(n.num.id) }
        if let c = p.meshcore { parts.append(ChatMeta.hex(c.publicKey.prefix(4))) }
        if let h = p.lastHeard { parts.append("heard " + h.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}
