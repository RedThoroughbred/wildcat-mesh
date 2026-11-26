import SwiftUI
import WildcatRadioCore

/// One tap: make the connected node a fox, or a base station (Den Lite).
struct QuickSetupView: View {
    enum Kind { case fox, den }
    let kind: Kind

    @Environment(Radio.self) private var radio
    @Environment(NodeAdmin.self) private var admin
    @State private var hunt: QuickSetup.HuntChannel? = QuickSetup.saved
    @State private var confirm = false
    @State private var applied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                intro
                ModuleHeader(1, "What changes")
                FieldGroup {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        if i > 0 { FieldDivider(inset: 0) }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(String(format: "%02d", i + 1))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                            Text(line).font(Theme.Fonts.callout).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                ModuleHeader(2, "Hunt channel")
                huntCard
                Button {
                    confirm = true
                } label: {
                    Label(kind == .fox ? "Make it the fox" : "Make it my Den", systemImage: "wand.and.stars")
                }
                .buttonStyle(.fieldPrimary)
                .disabled(!canApply)
                if radio.session.needsRegion {
                    Notice(text: "Set this node's region first (Node settings → Set up).", color: Theme.alert)
                }
                statusLine
                if applied, let hunt {
                    ModuleHeader(3, "Hunters scan this")
                    VStack(spacing: 12) {
                        QRImage(text: hunt.addLink)
                        ShareLink(item: hunt.addLink) { Label("Share the hunt channel", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.fieldSecondary)
                        Text("Adds \(hunt.name) to their nodes, next to their other channels. Scan it in Wildcat (Node settings → Import).")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .panel()
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle(kind == .fox ? "Fox" : "Den Lite")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(kind == .fox ? "Turn this node into the fox?" : "Turn this node into your Den?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button(kind == .fox ? "Make it the fox" : "Make it my Den", role: kind == .fox ? .destructive : nil) {
                Task { await apply() }
            }
        } message: {
            Text(kind == .fox ? "Its other channels are removed. Use a spare node, not the one you carry." : "The node restarts to apply the changes.")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Emblem(symbol: kind == .fox ? "pawprint" : "house.lodge", size: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(kind == .fox ? "Make this node the fox" : "Make this node your Den")
                        .font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    NetworkTag(.meshtastic, via: radio.session.myNode.flatMap { radio.session.nodes[$0]?.shortName })
                }
            }
            Text(kind == .fox
                 ? "For a spare node you'll hide. It stops talking on your normal channels and only sends a small heartbeat on the hunt channel once an hour, without its location. Hunters ping it to hear it."
                 : "For a node that stays plugged in at home or up high. No computer needed: it relays for everyone, holds its position and keeps an eye on the mesh.")
                .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.hero)
    }

    @ViewBuilder private var huntCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hunt {
                HStack {
                    Text("Hunt channel").font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Chip(hunt.name, small: true)
                }
                if hunt.lora == nil {
                    Notice(text: "Frequency not known yet: the fox stays on this node's current frequency. Connect your everyday node once so Wildcat can learn it.")
                }
            } else if kind == .fox {
                Text("Wildcat hasn't seen a hunt channel yet. Connect your everyday node that has WGHUNT first, or make a new one here and share it with hunters afterwards.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Button("Make a new hunt channel") { hunt = QuickSetup.newHuntChannel(for: radio.session); QuickSetup.saved = hunt }
                    .buttonStyle(.field(.secondary, .regular))
            } else {
                Text("No hunt channel known: that's fine, the Den works without one.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    @ViewBuilder private var statusLine: some View {
        switch admin.status {
        case .working(let s):
            HStack(spacing: 10) { ProgressView().tint(Theme.textSecondary); Text(s).font(Theme.Fonts.data).foregroundStyle(Theme.textSecondary) }
        case .failed(let s):
            Notice(text: s, color: Theme.alert)
        case .done(let s):
            if applied { Notice(text: s, color: Theme.ok, symbol: "checkmark.circle") }
        case .idle:
            EmptyView()
        }
    }

    private var canApply: Bool {
        radio.isReady && radio.source == .bluetooth && !radio.session.needsRegion && !admin.isWorking
            && (kind == .den || hunt != nil)
    }

    private var lines: [String] {
        switch kind {
        case .fox:
            return ["Hunt channel becomes its only channel, on your mesh's frequency",
                    "Transmit power \(QuickSetup.foxPower) dBm, so walking closer really changes the signal",
                    "Location hidden: GPS off, no fixed position",
                    "Heartbeat every hour (battery and uptime, no location); it answers hunters' pings",
                    "Restarts once to apply"]
        case .den:
            return ["Fixed position: where your phone is now",
                    "Position and heartbeat once an hour (the Meshtastic defaults)",
                    "Store & forward on: keeps messages for nodes that were away (ESP32 boards with PSRAM)",
                    "Relays for everyone (role Client if it was a quiet role)",
                    "Hunt channel added, if Wildcat knows it",
                    "Restarts once to apply"]
        }
    }

    private func apply() async {
        let s = radio.session
        let changes: [NodeAdmin.Change]
        switch kind {
        case .fox:
            guard let hunt else { return }
            changes = QuickSetup.fox(s, hunt: hunt)
        case .den:
            let l = await LocationOnce().get()
            changes = QuickSetup.denLite(s, at: l.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                                         altitude: l.flatMap { $0.verticalAccuracy >= 0 ? Int($0.altitude.rounded()) : nil },
                                         hunt: hunt)
        }
        applied = true
        await admin.apply(changes, summary: kind == .fox ? "Fox setup" : "Den setup")
    }
}
