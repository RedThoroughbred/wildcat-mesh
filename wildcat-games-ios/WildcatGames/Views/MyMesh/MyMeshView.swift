import SwiftUI
import WildcatRadioCore

/// The radios you own, on both networks, and what each one does.
struct MyMeshView: View {
    @Environment(MyMeshStore.self) private var store
    @AppStorage("mymesh.howItWorks") private var showHow = true

    var body: some View {
        let nodes = store.nodes
        let online = nodes.filter { store.isOnline($0) }.count
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                Text("Every radio you own, on both networks. Each one joins when this phone connects to it, or when you log in to a repeater as admin.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isPracticeRunning {
                    Notice(text: "Practice is on: the pretend radios below aren't saved.", symbol: "figure.walk.motion")
                }
                if !nodes.isEmpty {
                    InstrumentPanel {
                        ReadoutRow {
                            ReadoutCell("Radios", value: "\(nodes.count)", sub: "yours")
                            CellDivider()
                            ReadoutCell("Online", value: "\(online)", sub: "heard lately", tint: online > 0 ? Theme.ok : Theme.textPrimary)
                            CellDivider()
                            ReadoutCell("Networks", value: "\(Set(nodes.map(\.network)).count)",
                                        sub: networksLine(nodes))
                        }
                    }
                }
                ModuleHeader(1, "Your radios", detail: nodes.isEmpty ? nil : "\(nodes.count)")
                if nodes.isEmpty {
                    EmptyState(symbol: "antenna.radiowaves.left.and.right", title: "No radios yet",
                               text: "Connect your node in the Meshtastic or MeshCore tab and it shows up here. You can also mark a node you hear as yours from its page.")
                        .panel(.inset)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                            if i > 0 { FieldDivider() }
                            NavRow { MyMeshNodeView(id: n.id) } label: {
                                OwnedNodeCard(node: n, connected: store.isConnected(n), online: store.isOnline(n))
                            }
                        }
                    }
                    .panel(.inset)
                }
                ModuleHeader(2, "How your mesh works", action: showHow ? "Hide" : "Show",
                             symbol: showHow ? "chevron.up" : "chevron.down") {
                    withAnimation(Theme.Motion.snappy) { showHow.toggle() }
                }
                if showHow { howItWorks.transition(.opacity) }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("My Mesh")
        .onAppear { store.refreshFromLinks() }
    }

    private func networksLine(_ nodes: [OwnedNode]) -> String {
        let mt = nodes.filter { $0.network == .meshtastic }.count
        let mc = nodes.filter { $0.network == .meshcore }.count
        return "\(mt) MT · \(mc) MC"
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.explainer.enumerated()), id: \.offset) { i, line in
                if i > 0 { PanelDivider() }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%02d", i + 1))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textQuaternary)
                    Text(line).font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.inset)
    }

    static let explainer = [
        "On Meshtastic, every radio repeats what it hears, a few hops at most, so each radio you add stretches the mesh for everyone.",
        "MeshCore splits the jobs: companions (the radios you carry) never repeat. Only repeaters and room servers forward messages.",
        "The first message to someone on MeshCore floods out through every repeater. Once it arrives, the route is learned and later messages take just that path.",
        "A repeater on a high, always-on spot (a roof, a hill, a solar pole) hears far more than a radio in your pocket, so one good repeater can link people who could never hear each other.",
        "The two networks can't hear each other. The Bridge in this app relays a channel between them.",
    ]
}

/// One owned radio on My Mesh, as a row: glyph in its network's colour, name,
/// network and role, then a status line with an LED.
struct OwnedNodeCard: View {
    let node: OwnedNode
    let connected: Bool
    let online: Bool

    static func network(_ n: OwnedNode.Network) -> MeshNetwork { n == .meshcore ? .meshcore : .meshtastic }

    static func color(_ n: OwnedNode.Network) -> Color { network(n).color }

    static func plate(_ n: OwnedNode) -> String {
        n.shortName ?? (n.network == .meshcore ? MeshCoreStatusCard.initials(n.name) : String(n.nodeID.suffix(4)))
    }

    /// The row glyph: what the radio is, in its network's colour.
    static func symbol(_ n: OwnedNode) -> String {
        if let k = n.meshcoreKind, MeshCoreFormat.isInfrastructure(k) || k == .sensor { return MeshCoreFormat.symbol(k) }
        return network(n.network).symbol
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: Self.symbol(node), tint: Self.color(node.network), size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(node.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    NetworkTag(Self.network(node.network))
                    if node.origin == .practice { Tag("Practice", color: Theme.textTertiary) }
                }
                Text(node.roleSummary).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary).lineLimit(2)
                HStack(spacing: 6) {
                    StatusLED(color: connected ? Theme.ok : Self.color(node.network), on: connected || online, size: 6)
                    Text(connected ? "Connected" : "Heard " + OwnedNode.ago(node.lastHeard))
                        .foregroundStyle(connected ? Theme.ok : Theme.textTertiary)
                    if let b = node.batteryShort {
                        Text("·").foregroundStyle(Theme.textQuaternary)
                        Text("batt " + b).foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(Theme.Fonts.raw)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Chevron()
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV + 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Entry points

/// The My Mesh card near the top of Play.
struct MyMeshCard: View {
    @Environment(MyMeshStore.self) private var store

    var body: some View {
        let n = store.nodes
        NavigationLink { MyMeshView() } label: {
            HeroCard(symbol: "antenna.radiowaves.left.and.right", title: "MY MESH",
                     text: n.isEmpty ? "Your radios on both networks, and what each one does." : "Your radios, and what each one does.",
                     detail: "\(n.count) node\(n.count == 1 ? "" : "s") · \(n.filter { store.isOnline($0) }.count) online")
        }
        .buttonStyle(.rowPress)
    }
}

/// The My Mesh row in the Meshtastic and MeshCore tabs.
struct MyMeshRow: View {
    @Environment(MyMeshStore.self) private var store

    var body: some View {
        NavRow { MyMeshView() } label: {
            FieldRow(symbol: "antenna.radiowaves.left.and.right", title: "My Mesh",
                     subtitle: "Your radios on both networks", detail: "\(store.nodes.count)")
        }
    }
}

/// "This one's mine" on a node or contact page: adds it to My Mesh, or takes it off.
struct MyMeshButton: View {
    @Environment(MyMeshStore.self) private var store
    let node: OwnedNode

    var body: some View {
        let mine = store.contains(node.id)
        Button {
            if mine { store.remove(node.id) } else { store.markMine(node) }
        } label: {
            Label(mine ? "In My Mesh (tap to remove)" : "This one's mine: add to My Mesh",
                  systemImage: mine ? "checkmark.seal" : "plus.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.field(mine ? .quiet : .secondary, .regular))
    }
}
