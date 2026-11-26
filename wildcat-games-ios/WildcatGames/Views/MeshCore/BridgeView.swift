import SwiftUI
import WildcatRadioCore

/// Bridge a Meshtastic channel and a MeshCore channel through this phone.
struct BridgeView: View {
    @Environment(MeshBridge.self) private var bridge
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore

    var body: some View {
        @Bindable var bridge = bridge
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                Text("Your phone relays messages between one Meshtastic channel and one MeshCore channel. Keep Wildcat open and both nodes connected.")
                    .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ModuleHeader(1, "Status")
                status
                if let why = bridge.offReason { Notice(text: why) }

                ModuleHeader(2, "Channels")
                VStack(alignment: .leading, spacing: 0) {
                    pickerRow(.meshtastic) {
                        Picker("Meshtastic", selection: $bridge.meshtasticChannel) {
                            Text("Choose…").tag(Int?.none)
                            ForEach(radio.session.channels.values.sorted { $0.index < $1.index }, id: \.index) { c in
                                Text((c.name.isEmpty ? "Primary" : c.name) + (MeshBridge.isPublic(meshtastic: c) ? " (public)" : ""))
                                    .tag(Int?.some(c.index))
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    .padding(.horizontal, 14)
                    pickerRow(.meshcore) {
                        Picker("MeshCore", selection: $bridge.meshcoreChannel) {
                            Text("Choose…").tag(Int?.none)
                            ForEach(meshcore.session.channels.values.sorted { $0.index < $1.index }, id: \.index) { c in
                                Text(meshcore.session.label(.channel(c.index)) + (MeshBridge.isPublic(meshcore: c) ? " (public)" : ""))
                                    .tag(Int?.some(c.index))
                            }
                        }
                    }
                    PanelDivider()
                    Toggle(isOn: $bridge.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bridge on").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                            Text(bridge.enabled ? "Relaying while both nodes are connected" : "Nothing is relayed")
                                .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.ok)
                    .disabled(publicChosen || bridge.meshtasticChannel == nil || bridge.meshcoreChannel == nil)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .instrumentPanel()
                if publicChosen {
                    Notice(text: "A public channel belongs to everyone nearby: bridging it would push your traffic onto their mesh. Make a private channel on each side (e.g. WGBRIDGE) and bridge those.",
                           color: Theme.alert)
                }
                ExplainerPanel("Can I message one person?",
                               text: "Yes. On the bridged channel, start a message with @name (\"@MAYA hello\") to send it privately to that person on the other network. Their direct reply comes back to the sender.")

                if !bridge.log.isEmpty {
                    ModuleHeader(3, "Relayed", detail: "\(bridge.log.count)")
                    VStack(spacing: 0) {
                        ForEach(Array(bridge.log.reversed().enumerated()), id: \.element.id) { i, l in
                            if i > 0 { FieldDivider(inset: 14) }
                            logRow(l)
                        }
                    }
                    .panel(.inset)
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("Bridge")
    }

    private var publicChosen: Bool {
        let mt = bridge.meshtasticChannel.flatMap { radio.session.channels[$0] }
        let mc = bridge.meshcoreChannel.flatMap { meshcore.session.channels[$0] }
        return (bridge.meshtasticChannel != nil && MeshBridge.isPublic(meshtastic: mt))
            || (bridge.meshcoreChannel != nil && MeshBridge.isPublic(meshcore: mc))
    }

    private var status: some View {
        StatusKeyRow {
            StatusKey("Meshtastic", sub: radio.isReady ? radio.statusText : "Not connected",
                      led: radio.isReady ? .network(.meshtastic) : .off)
            StatusKey("MeshCore", sub: meshcore.state.isReady ? (meshcore.session.me?.name ?? "node") : "Not connected",
                      led: meshcore.state.isReady ? .network(.meshcore) : .off)
            StatusKey("Bridge", sub: bridge.isLive ? "⇄ Live" : bridge.enabled ? "Waiting" : "Off",
                      led: bridge.isLive ? .on : bridge.enabled ? .warn : .off)
        }
    }

    private func pickerRow<P: View>(_ network: MeshNetwork, @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 12) {
            NetworkTag(network)
            Spacer(minLength: 8)
            picker()
                .pickerStyle(.menu)
                .tint(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }

    private func logRow(_ l: MeshBridge.Line) -> some View {
        let to: MeshNetwork = l.way == .toMeshCore ? .meshcore : .meshtastic
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("→ \(to.short)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(to.color)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous).strokeBorder(to.stroke, lineWidth: 1))
                .fixedSize()
            Text(l.text).font(Theme.Fonts.footnote).foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(l.at, style: .time).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Relayed to \(to.name): \(l.text)")
    }
}
