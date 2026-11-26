import SwiftUI
import WildcatRadioCore

// MARK: - Tab toolbar

/// The same toolbar on every tab: both radios (the pill) on the left, the guide
/// and the app menu on the right.
struct TabToolbar: ToolbarContent {
    /// The guide chapter the "?" opens (nil: the whole guide).
    var guide: String? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { RadioPill() }
        ToolbarItemGroup(placement: .topBarTrailing) {
            GuideButton(chapter: guide)
            AppMenuButton()
        }
    }
}

// MARK: - App menu

/// Opens the app menu: everything that belongs to the whole app rather than one network.
struct AppMenuButton: View {
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Image(systemName: "line.3.horizontal") }
            .accessibilityLabel("Menu")
            .accessibilityHint("Bridge, firmware, Den, guide, safety, about and the radio log")
            .sheet(isPresented: $open) {
                NavigationStack { AppMenuView() }
                    .presentationBackground(Theme.bg)
            }
    }
}

/// Where app-wide things live (not inside one network's tab): the bridge, the combined map,
/// the radio log, both nodes' firmware, the guide, safety, about, the Den, and developer switches.
struct AppMenuView: View {
    @Environment(\.dismiss) private var dismiss

    /// How the menu is named in hints elsewhere ("Unblock any time in Menu → Safety").
    static let name = "Menu"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                masthead
                ModuleHeader(1, "Both networks")
                FieldGroup {
                    BridgeRow()
                    FieldDivider()
                    BothNetworksMapRow()
                    FieldDivider()
                    NavRow { LogView() } label: {
                        FieldRow(symbol: "text.alignleft", title: "Radio log",
                                 subtitle: "Meshtastic, MeshCore and the bridge: connections, hunt and Den lines")
                    }
                }
                ModuleHeader(2, "More")
                FieldGroup {
                    NavRow { ExploreView() } label: {
                        FieldRow(symbol: "map", title: "Explore", subtitle: "Nodedex, achievements, Territory, coverage walks")
                    }
                    FieldDivider()
                    RNodeRow()
                }
                ModuleHeader(3, "Firmware", detail: "both nodes")
                FirmwareMenuGroup()
                ModuleHeader(4, "Help")
                FieldGroup {
                    NavRow { GuideView() } label: {
                        FieldRow(symbol: "book", title: "Guide", subtitle: "How everything works, offline")
                    }
                    FieldDivider()
                    NavRow { SafetyView() } label: {
                        FieldRow(symbol: "hand.raised", title: "Safety", subtitle: "Blocked people, word filter, reporting")
                    }
                    FieldDivider()
                    NavRow { AboutView() } label: {
                        FieldRow(symbol: "info.circle", title: "About Wildcat Mesh", subtitle: "Privacy policy, support, version")
                    }
                }
                ModuleHeader(5, "Base station")
                FieldGroup {
                    NavRow { DenView() } label: {
                        FieldRow(symbol: "house.lodge", title: "Den (base station)",
                                 subtitle: "Optional, for Meshtastic: history, coverage maps, refereed hunts")
                    }
                }
                ModuleHeader(6, "Developer")
                FieldGroup {
                    KeepRawRow()
                    #if DEBUG
                    FieldDivider()
                    NavRow { DesignGalleryView() } label: {
                        FieldRow(symbol: "swatchpalette", title: "Design gallery", subtitle: "Developer only")
                    }
                    #endif
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle(Self.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private var masthead: some View {
        HStack(spacing: 12) {
            RemiMark(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("WILDCAT MESH")
                    .font(Theme.Fonts.label)
                    .tracking(Theme.labelTracking)
                    .foregroundStyle(Theme.textSecondary)
                Text("For the whole app · Meshtastic, MeshCore and RNode")
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared rows

/// The bridge, with whether it's relaying. Its home is the app menu; both network tabs
/// carry the same row as a shortcut.
struct BridgeRow: View {
    @Environment(MeshBridge.self) private var bridge

    var body: some View {
        NavRow { BridgeView() } label: {
            FieldRow(symbol: "arrow.left.arrow.right", tint: bridge.isLive ? Theme.ok : nil, title: "Bridge",
                     subtitle: "Relay a channel between Meshtastic and MeshCore",
                     detail: bridge.isLive ? "Live" : bridge.enabled ? "Waiting" : "Off")
        }
    }
}

/// The map with both networks' nodes, reachable from both network tabs and the app menu.
struct BothNetworksMapRow: View {
    var body: some View {
        NavRow { MeshCoreMapView(bothNetworks: true) } label: {
            FieldRow(symbol: "square.2.layers.3d", title: "Map (both networks)", subtitle: "Meshtastic and MeshCore nodes together")
        }
    }
}

/// Debug: keep each message's raw packet, for looking at what really went over the air.
struct KeepRawRow: View {
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MessageStore.self) private var messages
    @AppStorage(MessageStore.keepRawKey) private var keep = false

    var body: some View {
        Toggle(isOn: $keep) {
            FieldRow(symbol: "doc.plaintext", title: "Keep raw packets",
                     subtitle: "For debugging, both networks. Saved messages get bigger.", chevron: false)
        }
        .toggleStyle(FieldToggleStyle())
        .padding(.trailing, 14)
        .onChange(of: keep) { _, on in
            meshcore.keepsRawPackets = on
            messages.keepsRawPackets = on
        }
    }
}

// MARK: - Practice

/// Practice on both networks: pretend Meshtastic and MeshCore radios on this phone.
/// Used by both network tabs (and the same thing Play → Practice starts).
struct PracticeCard: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    /// Practice takes over this network even when a real radio is connected to it
    /// (the card under a connected node: "try practice instead").
    var replacing: MeshNetwork? = nil

    var body: some View {
        Button {
            switch replacing {
            case .meshtastic?: radio.startPractice()
            case .meshcore?: PracticeMode.startMeshCore(meshcore)
            case nil: break
            }
            PracticeMode.start(radio, meshcore)
        } label: {
            HStack(spacing: 14) {
                Emblem(symbol: "figure.walk.motion", size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    CardLabel("Practice")
                    Text("Pretend Meshtastic and MeshCore radios, a fox and a Den on this phone. No radio needed.")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Chevron()
            }
            .panel()
        }
        .buttonStyle(.rowPress)
        .accessibilityHint("Starts pretend radios on the networks with no radio connected")
    }
}

// MARK: - Needs a radio

/// One notice for "this needs a radio": names the network(s) the feature needs, says why
/// in one line, and opens that network's tab. Optionally offers practice.
struct NeedsRadioNotice: View {
    /// The networks that can do this (one, or both for "Meshtastic or MeshCore").
    let networks: [MeshNetwork]
    /// One plain line on why ("It hears the fox.").
    var why: String? = nil
    /// Shows a Practice button that runs this before practice starts (e.g. open the hunt).
    var practice: (() -> Void)? = nil
    /// Runs before switching tabs (a sheet passes its dismiss, so the tab isn't hidden under it).
    var onOpenTab: (() -> Void)? = nil

    @Environment(\.tabRouter) private var router
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore

    init(_ networks: MeshNetwork..., why: String? = nil, practice: (() -> Void)? = nil, onOpenTab: (() -> Void)? = nil) {
        self.networks = networks.isEmpty ? MeshNetwork.allCases : networks
        self.why = why
        self.practice = practice
        self.onOpenTab = onOpenTab
    }

    /// "Needs a Meshtastic node", "Needs a Meshtastic or MeshCore node".
    static func title(_ networks: [MeshNetwork]) -> String {
        "Needs a \(networks.map(\.name).joined(separator: " or ")) node"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: networks.count == 1 ? networks[0].symbol : "antenna.radiowaves.left.and.right",
                         tint: networks.count == 1 ? networks[0].color : nil, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(networks))
                        .font(Theme.Fonts.heading)
                        .foregroundStyle(Theme.textPrimary)
                    if let why {
                        Text(why)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.inset)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        if router != nil {
            ForEach(networks) { n in
                Button {
                    onOpenTab?()
                    router?.tab = AppTab(n)
                } label: {
                    Label("Connect on \(n.name)", systemImage: n.symbol)
                }
                .buttonStyle(.field(practice == nil ? .primary : .secondary, .small))
                .accessibilityHint("Opens the \(n.name) tab")
            }
        }
        if let practice {
            Button {
                PracticeMode.start(radio, meshcore)
                practice()
            } label: {
                Label("Practice", systemImage: "figure.walk.motion")
            }
            .buttonStyle(.field(.primary, .small))
        }
    }
}
