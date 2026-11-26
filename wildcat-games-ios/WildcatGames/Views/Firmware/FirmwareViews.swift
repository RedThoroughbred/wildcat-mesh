import SwiftUI
import WildcatRadioCore

// MARK: - What each node runs

/// One node's firmware as the app knows it: the connected node, the practice node, or
/// (disconnected) the version saved when it was last connected.
struct NodeFirmware: Equatable {
    var network: MeshNetwork
    /// What the node reports (Meshtastic DeviceMetadata, MeshCore device info), as it says it.
    var version: String?
    var practice: Bool = false
    var connected: Bool = false
    var name: String?
    /// When it was last connected, for a node that isn't connected now.
    var lastSeen: Date?

    /// "2.7.15.567b8ea", "Practice", "Not reported".
    var versionText: String {
        if practice { return "Practice" }
        return version.flatMap { $0.isEmpty ? nil : $0 } ?? "Not reported"
    }

    /// For rows: "2.7.15", "practice", "—".
    var shortText: String {
        if practice { return "practice" }
        return FirmwareVersion(version)?.description ?? version ?? "—"
    }

    @MainActor static func meshtastic(_ radio: Radio) -> NodeFirmware? {
        let s = radio.session
        let name = s.myNode.flatMap { s.nodes[$0]?.longName }
        switch radio.source {
        case .practice:
            return NodeFirmware(network: .meshtastic, version: s.firmware, practice: true, connected: true, name: name)
        case .bluetooth where radio.isReady:
            return NodeFirmware(network: .meshtastic, version: s.firmware, connected: true, name: name ?? s.myNode?.id)
        default:
            guard let c = MeshtasticCache.load() else { return nil }
            return NodeFirmware(network: .meshtastic, version: c.firmware, name: c.longName ?? c.nodeNum.id, lastSeen: c.saved)
        }
    }

    @MainActor static func meshcore(_ link: MeshCoreLink, myMesh: MyMeshStore) -> NodeFirmware? {
        let s = link.session
        if link.isDemo {
            return NodeFirmware(network: .meshcore, version: s.device?.version, practice: true, connected: true, name: s.me?.name)
        }
        if link.state.isReady {
            return NodeFirmware(network: .meshcore, version: s.device?.version, connected: true, name: s.me?.name)
        }
        // The last real MeshCore node, as My Mesh saved it.
        let last = myMesh.saved.filter { $0.network == .meshcore && $0.lastConnected != nil && $0.origin != .practice }
            .max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }
        guard let last else { return nil }
        return NodeFirmware(network: .meshcore, version: last.firmware, name: last.name, lastSeen: last.lastConnected)
    }
}

// MARK: - Firmware card

/// Installed version, what the check says, the latest stable release, and the ways on:
/// Check for updates, Release notes (the official page, in Safari) and How to update.
/// The same for both networks; used in Node settings and from the menu.
struct FirmwareCard: View {
    let network: MeshNetwork
    let node: NodeFirmware?
    /// Off where one button checks both networks (the menu).
    var showsCheck = true

    @Environment(FirmwareCheck.self) private var check
    @Environment(\.openURL) private var openURL
    @State private var howTo = false

    var body: some View {
        let entry = check.manifest?.network(network)
        VStack(alignment: .leading, spacing: 12) {
            line("Installed", node?.versionText ?? "No node connected",
                 note: node.flatMap { n in n.connected ? nil : n.lastSeen.map { "last connected \(MeshCoreFormat.ago($0))" } })
            if let node, let v = check.verdict(network, current: node.version, practice: node.practice) {
                FirmwareVerdictLine(verdict: v)
            }
            if let latest = entry?.latest {
                line("Latest stable", [FirmwareVersion(latest.version)?.description ?? latest.version, latest.dateText]
                    .compactMap { $0 }.joined(separator: " · "))
                if let summary = latest.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsCheck { FirmwareCheckButton() }
            HStack(spacing: 8) {
                if let url = entry?.latest.pageURL {
                    Button { openURL(url) } label: { Label("Release notes", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.field(.secondary, .small))
                        .accessibilityHint("Opens the official \(network.name) release page in Safari")
                }
                Button { howTo = true } label: { Label("How to update", systemImage: "questionmark.circle") }
                    .buttonStyle(.field(.secondary, .small))
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $howTo) {
            FirmwareHowToSheet(network: network, release: entry?.latest)
        }
    }

    private func line(_ key: String, _ value: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(Theme.Fonts.data).foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                if let note { Text(note).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The check's answer: a glyph in the status colour, the headline, and a plain line.
struct FirmwareVerdictLine: View {
    let verdict: FirmwareVerdict

    private var look: (symbol: String, color: Color) {
        switch verdict.status {
        case .upToDate: return ("checkmark.circle.fill", Theme.ok)
        case .updateAvailable: return ("arrow.down.circle.fill", Theme.warn)
        case .newerThanTested: return ("exclamationmark.circle", Theme.warn)
        case .aheadOfStable: return ("testtube.2", Theme.textSecondary)
        case .practice: return ("figure.walk.motion", Theme.textSecondary)
        case .unknown: return ("questionmark.circle", Theme.textTertiary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: look.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(look.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.headline)
                    .font(Theme.Fonts.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = verdict.detail {
                    Text(d)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Check for updates", with when the list last came (or why it didn't).
struct FirmwareCheckButton: View {
    @Environment(FirmwareCheck.self) private var check

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await check.check() }
            } label: {
                HStack(spacing: 8) {
                    if check.isChecking { ProgressView().controlSize(.small).tint(Theme.textSecondary) }
                    Text(check.isChecking ? "Checking…" : "Check for updates")
                }
            }
            .buttonStyle(.field(.primary, .regular))
            .disabled(check.isChecking)
            .accessibilityHint("Downloads a public version list from the Wildcat website")
            if case .failed(let why) = check.state {
                Text(why).font(Theme.Fonts.footnote).foregroundStyle(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let when = check.checked {
                Text("Checked \(MeshCoreFormat.ago(when))")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Node settings section

/// The Firmware section of a node's settings (both networks).
struct FirmwareSection: View {
    let network: MeshNetwork
    let number: Int
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MyMeshStore.self) private var myMesh

    var body: some View {
        Section {
            FirmwareCard(network: network, node: network == .meshtastic ? NodeFirmware.meshtastic(radio)
                         : NodeFirmware.meshcore(meshcore, myMesh: myMesh))
        } header: { ModuleHeader(number, "Firmware") } footer: {
            Text(FirmwarePrivacy.line)
        }
        .fieldSection()
    }
}

enum FirmwarePrivacy {
    static let line = "Check for updates downloads a public version list from the Wildcat website, only when you tap it. Nothing about you or your node is sent. Wildcat never installs firmware."
}

// MARK: - App menu

/// ≡ Menu → Firmware: both nodes' versions and one Check for updates for both.
struct FirmwareMenuGroup: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MyMeshStore.self) private var myMesh
    @Environment(FirmwareCheck.self) private var check

    var body: some View {
        FieldGroup {
            row(.meshtastic, NodeFirmware.meshtastic(radio))
            FieldDivider()
            row(.meshcore, NodeFirmware.meshcore(meshcore, myMesh: myMesh))
            FieldDivider(inset: 0)
            FirmwareCheckButton()
                .padding(.horizontal, Theme.Space.rowH)
                .padding(.vertical, 12)
        }
    }

    private func row(_ network: MeshNetwork, _ node: NodeFirmware?) -> some View {
        let verdict = node.flatMap { check.verdict(network, current: $0.version, practice: $0.practice) }
        let subtitle: String = {
            guard let node else { return "No node connected" }
            let who = node.name.map { node.connected ? $0 : "\($0), last connected" }
            if node.practice, let latest = check.manifest?.network(network)?.latest {
                return "Practice node · latest stable \(FirmwareVersion(latest.version)?.description ?? latest.version)"
            }
            return verdict?.headline ?? who ?? (node.connected ? "Connected" : "Last connected")
        }()
        return NavRow { FirmwareDetailView(network: network) } label: {
            FieldRow(symbol: network.symbol, tint: verdict?.wantsAttention == true ? Theme.warn : network.color,
                     title: network.name, subtitle: subtitle, detail: node?.shortText)
        }
    }
}

/// One network's firmware from the menu: the same card as in Node settings.
struct FirmwareDetailView: View {
    let network: MeshNetwork
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MyMeshStore.self) private var myMesh

    var body: some View {
        let node = network == .meshtastic ? NodeFirmware.meshtastic(radio) : NodeFirmware.meshcore(meshcore, myMesh: myMesh)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                HStack(spacing: 8) {
                    NetworkTag(network)
                    if let name = node?.name {
                        Text(name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    }
                }
                FirmwareCard(network: network, node: node)
                    .padding(14)
                    .panel(.inset)
                Text(FirmwarePrivacy.line)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.vertical, 12)
        }
        .screen()
        .navigationTitle("\(network.name) firmware")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - How to update

/// Plain steps per network, linking out to the official tools rather than copying their docs.
/// Wildcat itself never downloads or installs firmware.
struct FirmwareHowToSheet: View {
    let network: MeshNetwork
    var release: FirmwareManifest.Release?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    Notice(text: FirmwareHowTo.fileHint(network), symbol: "info.circle")
                    ModuleHeader(1, "nRF52 boards", detail: FirmwareHowTo.nrfExamples(network))
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(FirmwareHowTo.nrfSteps(network).enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 20, height: 18)
                                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                                    Text(step.text).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
                    Notice(text: "Over Bluetooth: close Wildcat first (swipe it away). A node talks to one app at a time.",
                           color: Theme.warn, symbol: "exclamationmark.triangle")
                    ModuleHeader(2, "ESP32 boards", detail: FirmwareHowTo.espExamples(network))
                    Text("Use a computer: open the web flasher in Chrome or Edge, plug the node in by USB and pick your board.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                    ModuleHeader(3, "Official links")
                    FieldGroup {
                        if let url = release?.pageURL {
                            link(url, symbol: "doc.text", title: "This release", subtitle: release?.name ?? url.host ?? "")
                            FieldDivider()
                        }
                        ForEach(Array(FirmwareHowTo.links(network).enumerated()), id: \.offset) { i, l in
                            if i > 0 { FieldDivider() }
                            link(l.url, symbol: l.symbol, title: l.title, subtitle: l.subtitle)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.edge)
                .padding(.vertical, 12)
            }
            .screen()
            .navigationTitle("Update \(network.name) firmware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
    }

    private func link(_ url: URL, symbol: String, title: String, subtitle: String) -> some View {
        Link(destination: url) {
            FieldRow(symbol: symbol, title: title, subtitle: subtitle, detail: nil, chevron: false)
                .overlay(alignment: .trailing) {
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textQuaternary).padding(.trailing, Theme.Space.rowH)
                }
        }
        .buttonStyle(.rowPress)
    }
}

/// The words and links of How to update (kept apart so they're easy to check against upstream docs).
enum FirmwareHowTo {
    struct Step { let title: String; let text: String }
    struct Link { let url: URL; let symbol: String; let title: String; let subtitle: String }

    static func fileHint(_ n: MeshNetwork) -> String {
        n == .meshtastic
            ? "Always pick the file for your exact board. Wildcat doesn't download or install firmware: these are Meshtastic's own tools."
            : "Pick your board and the Companion (Bluetooth) firmware: USB, repeater and room-server builds don't talk to phones. Wildcat doesn't download or install firmware."
    }

    static func nrfExamples(_ n: MeshNetwork) -> String {
        n == .meshtastic ? "RAK, XIAO, T-Echo" : "RAK, XIAO, T114"
    }

    static func espExamples(_ n: MeshNetwork) -> String {
        "Heltec, T-Beam"
    }

    static func nrfSteps(_ n: MeshNetwork) -> [Step] {
        switch n {
        case .meshtastic:
            return [
                Step(title: "USB-C, no app needed",
                     text: "Plug the node into a computer and double-tap its reset button: a drive appears. Copy your board's .uf2 file from the official release onto it. The node restarts by itself."),
                Step(title: "Web flasher, from a computer",
                     text: "Open flasher.meshtastic.org, pick your board and the version, and follow its steps."),
                Step(title: "Over Bluetooth, from this phone",
                     text: "Nordic's nRF Device Firmware Update app with your board's -ota.zip file from the release (the official Meshtastic app can also update it)."),
            ]
        case .meshcore:
            return [
                Step(title: "USB-C, no app needed",
                     text: "Plug the node into a computer and double-tap its reset button: a drive appears. Copy your board's companion_radio_ble .uf2 file from the official release onto it. The node restarts by itself."),
                Step(title: "Web flasher, from a computer",
                     text: "Open flasher.meshcore.io, pick your board, Companion (Bluetooth) and the version, and follow its steps."),
                Step(title: "Over Bluetooth, from this phone",
                     text: "Nordic's nRF Device Firmware Update app with your board's companion_radio_ble .zip file from the release. Needs companion firmware 1.15 or newer; MeshCore's FAQ explains how to start it."),
            ]
        }
    }

    static func links(_ n: MeshNetwork) -> [Link] {
        let dfu = Link(url: URL(string: "https://apps.apple.com/app/nrf-device-firmware-update/id1624454660")!, symbol: "iphone.radiowaves.left.and.right",
                       title: "nRF Device Firmware Update", subtitle: "Nordic's app, App Store")
        switch n {
        case .meshtastic:
            return [
                Link(url: URL(string: "https://flasher.meshtastic.org")!, symbol: "laptopcomputer", title: "Meshtastic web flasher",
                     subtitle: "flasher.meshtastic.org"),
                Link(url: URL(string: "https://meshtastic.org/docs/getting-started/flashing-firmware/")!, symbol: "book",
                     title: "Meshtastic: flashing firmware", subtitle: "meshtastic.org docs, every board"),
                dfu,
            ]
        case .meshcore:
            return [
                Link(url: URL(string: "https://flasher.meshcore.io")!, symbol: "laptopcomputer", title: "MeshCore web flasher",
                     subtitle: "flasher.meshcore.io"),
                Link(url: URL(string: "https://docs.meshcore.io/faq/")!, symbol: "book", title: "MeshCore FAQ",
                     subtitle: "docs.meshcore.io: updating nRF and ESP32 nodes"),
                dfu,
            ]
        }
    }
}
