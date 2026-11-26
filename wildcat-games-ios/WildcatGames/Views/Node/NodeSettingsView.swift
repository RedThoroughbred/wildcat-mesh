import CoreImage.CIFilterBuiltins
import SwiftUI
import VisionKit
import WildcatRadioCore

/// Everything about your own node: set it up, rename it, radio, role,
/// position, channels (share and import Meshtastic links), reboot.
struct NodeSettingsView: View {
    @Environment(Radio.self) private var radio
    @Environment(NodeAdmin.self) private var admin
    @State private var owner = Owner(raw: Data())
    @State private var lora = LoRaSettings(raw: Data())
    @State private var device = DeviceSettings(raw: Data())
    @State private var position = PositionSettings(raw: Data())
    @State private var loaded = false
    @State private var editing: ChannelInfo?
    @State private var importing = false
    @State private var sharing: String?
    @State private var confirmReboot = false

    var body: some View {
        let s = radio.session
        Form {
            statusSection
            Section { NodeHeader() }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            if s.needsRegion { SetupSection() }
            Section {
                NavigationLink { QuickSetupView(kind: .fox) } label: { Label("Make this node the fox", systemImage: "pawprint") }
                NavigationLink { QuickSetupView(kind: .den) } label: { Label("Make this node my Den", systemImage: "house.lodge") }
            } header: { ModuleHeader(1, "One tap") } footer: {
                Text("Set up a spare node as the hidden fox, or as an always-on base station. No computer needed.")
            }
            .fieldSection()
            Section {
                LabeledContent("Node") { Text(s.myNode?.id ?? "?").font(Theme.Fonts.data) }
                if let fw = s.firmware { LabeledContent("Firmware") { Text(fw).font(Theme.Fonts.data) } }
            } header: { ModuleHeader(2, "This node") }
            .fieldSection()
            Section {
                TextField("Long name", text: $owner.longName)
                TextField("Short name (4 max)", text: $owner.shortName)
                    .font(Theme.Fonts.data)
                    .onChange(of: owner.shortName) { _, v in if v.count > 4 { owner.shortName = String(v.prefix(4)) } }
                saveButton("Save name", disabled: owner.raw == owner.patched || owner.longName.isEmpty) {
                    [.owner(owner.patched)]
                }
            } header: { ModuleHeader(3, "Name") }
            .fieldSection()
            Section {
                Picker("Region", selection: $lora.region) {
                    ForEach(Region.allCases) { Text($0.title).tag($0) }
                }
                Picker("Preset", selection: $lora.preset) {
                    ForEach(ModemPreset.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Hop limit: \(lora.hopLimit)", value: $lora.hopLimit, in: 1...7)
                Stepper("Transmit power: \(lora.txPower == 0 ? "board maximum" : "\(lora.txPower) dBm")", value: $lora.txPower, in: 0...30)
                Toggle("Transmit enabled", isOn: $lora.txEnabled)
                if let slot = FrequencySlot.effective(lora: lora, primaryName: s.channels[0]?.name ?? "") {
                    LabeledContent("Frequency slot") { Text("\(slot)").font(Theme.Fonts.data) }
                }
                saveButton("Save radio settings", disabled: lora.raw == lora.patched) {
                    var l = lora
                    l.usePreset = true
                    return [.config(.lora, l.patched)]
                }
            } header: { ModuleHeader(4, "Radio") } footer: {
                Text("Every node on a mesh needs the same region and preset. Lower power makes a better fox: walkers get a real gradient.")
            }
            .fieldSection()
            Section {
                Picker("Role", selection: $device.role) {
                    ForEach(DeviceRole.allCases) { Text($0.title).tag($0) }
                }
                Text(device.role.detail).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                saveButton("Save role", disabled: device.raw == device.patched) { [.config(.device, device.patched)] }
            } header: { ModuleHeader(5, "Role") }
            .fieldSection()
            Section {
                Picker("Broadcast every", selection: $position.broadcastSecs) {
                    Text("Default").tag(0)
                    Text("1 min").tag(60)
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("1 hour").tag(3600)
                    Text("12 hours").tag(43_200)
                }
                Toggle("Smart position (only when moving)", isOn: $position.smart)
                Toggle("Fixed position (use this phone's location)", isOn: $position.fixed)
                Button {
                    Task { await savePosition() }
                } label: {
                    Text(position.fixed ? "Save and set position to where I am" : "Save position settings")
                }
                .buttonStyle(.field(.primary, .regular))
                .disabled(admin.isWorking || (position.raw == position.patched && !position.fixed))
                if position.fixed {
                    Text("Nodes without GPS need a fixed position to beacon at all. Stand where the node will be, then save.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                }
            } header: { ModuleHeader(6, "Position") }
            .fieldSection()
            Section {
                ForEach(s.channels.values.sorted { $0.index < $1.index }, id: \.index) { c in
                    Button {
                        editing = c
                    } label: {
                        MeshtasticChannelRow(index: c.index, name: c.name, keyKind: c.settings.map { ChannelSettings(raw: $0).keyKind },
                                             chevron: true, padded: false, emptyName: "Primary (default name)")
                    }
                }
                Button { editing = ChannelInfo(index: -1, name: "", role: .secondary) } label: {
                    Label("New private channel", systemImage: "plus")
                }
                .disabled(s.channels.count >= 8)
                Button { importing = true } label: { Label("Import a Wildcat channel link or QR", systemImage: "qrcode.viewfinder") }
                Button {
                    sharing = ChannelLink(channels: s.channels.values.sorted { $0.index < $1.index }.compactMap { $0.settings.map(ChannelSettings.init) },
                                          lora: s.config[.lora], add: false).url
                } label: { Label("Share all channels as QR", systemImage: "qrcode") }
                GuideLink(chapter: "channels", title: "Channels, keys and the frequency rule")
                GuideLink(chapter: "fox", title: "How to make a fox")
            } header: { ModuleHeader(7, "Channels", detail: "\(s.channels.count) of 8") } footer: {
                Text("Links and QR codes are Wildcat's own: friends scan them in Wildcat (Node settings → Import).")
            }
            .fieldSection()
            FirmwareSection(network: .meshtastic, number: 8)
            Section {
                Button("Reboot node", role: .destructive) { confirmReboot = true }
                    .buttonStyle(.field(.destructive, .regular))
            }
            .fieldSection()
        }
        .fieldForm()
        .navigationTitle("Node settings")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(admin.isWorking)
        .onAppear { load() }
        .onChange(of: radio.session.config) { _, _ in load(force: true) }
        .sheet(item: $editing) { ChannelEditor(channel: $0) }
        .sheet(isPresented: $importing) { ImportChannelsSheet() }
        .sheet(item: Binding(get: { sharing.map(ShareItem.init) }, set: { sharing = $0?.url })) { QRSheet(url: $0.url) }
        .confirmationDialog("Reboot the node?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { Task { await admin.apply([.reboot], summary: "Reboot") } }
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch admin.status {
        case .idle: EmptyView()
        case .working(let t):
            Section { HStack(spacing: 10) { ProgressView().tint(Theme.textSecondary); Text(t).font(Theme.Fonts.data) } }.fieldSection()
        case .done(let t):
            Section { Notice(text: t, color: Theme.ok, symbol: "checkmark.circle") }.fieldSection()
        case .failed(let t):
            Section { Notice(text: t, color: Theme.alert, symbol: "exclamationmark.triangle") }.fieldSection()
        }
    }

    private func saveButton(_ title: String, disabled: Bool, _ changes: @escaping () -> [NodeAdmin.Change]) -> some View {
        Button(title) { Task { await admin.apply(changes(), summary: title.replacingOccurrences(of: "Save ", with: "").capitalized) } }
            .buttonStyle(.field(.primary, .regular))
            .disabled(disabled || admin.isWorking)
    }

    /// Position settings; with fixed position on, also stores the phone's
    /// current location as the node's position (as the Meshtastic app does).
    private func savePosition() async {
        var changes: [NodeAdmin.Change] = []
        if position.raw != position.patched { changes.append(.config(.position, position.patched)) }
        if position.fixed {
            guard let l = await LocationOnce().get() else {
                await admin.apply(changes, summary: "Position")
                return
            }
            changes.append(.fixedPosition(Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude),
                                          altitude: l.verticalAccuracy >= 0 ? Int(l.altitude.rounded()) : nil))
        } else if radio.session.position?.fixed == true {
            changes.append(.clearFixedPosition)
        }
        guard !changes.isEmpty else { return }
        await admin.apply(changes, summary: "Position")
    }

    private func load(force: Bool = false) {
        guard force || !loaded else { return }
        let s = radio.session
        if let raw = s.ownerRaw { owner = Owner(raw: raw) }
        if let l = s.lora { lora = l }
        if let d = s.device { device = d }
        if let p = s.position { position = p }
        loaded = true
    }
}

extension ChannelInfo: Identifiable { public var id: Int { index } }

/// The node the settings belong to: glyph, name, network and ids.
private struct NodeHeader: View {
    @Environment(Radio.self) private var radio

    var body: some View {
        let s = radio.session
        let me = s.myNode.flatMap { s.nodes[$0] }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: MeshNetwork.meshtastic.symbol, tint: Theme.meshtastic, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(me?.longName ?? s.myNode?.id ?? "Your node")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        NetworkTag(.meshtastic)
                    }
                    Text([s.myNode?.id, me?.hardware, s.firmware.map { "fw \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Fonts.raw)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // The radio's chips under the name, as the MeshCore settings masthead has them.
            MeshtasticRadioChips(session: s, practice: radio.source == .practice)
        }
        .padding(14)
        .instrumentPanel()
    }
}

private struct ShareItem: Identifiable {
    let url: String
    var id: String { url }
}

/// First-time setup: a node won't transmit until its region is set.
private struct SetupSection: View {
    @Environment(Radio.self) private var radio
    @Environment(NodeAdmin.self) private var admin
    @State private var region = Region.guess(regionCode: Locale.current.region?.identifier)
    @State private var longName = ""
    @State private var shortName = ""
    @State private var role = DeviceRole.client

    var body: some View {
        Section {
            Notice(text: "This node has no region yet, so it won't transmit. Pick your region, give it a name, and it's ready.", symbol: "wand.and.stars")
            Picker("Region", selection: $region) { ForEach(Region.allCases.filter { $0 != .unset }) { Text($0.title).tag($0) } }
            TextField("Long name (e.g. Maya's Scout)", text: $longName)
            TextField("Short name (4)", text: $shortName)
                .font(Theme.Fonts.data)
                .onChange(of: shortName) { _, v in if v.count > 4 { shortName = String(v.prefix(4)) } }
            Picker("Role", selection: $role) { ForEach([DeviceRole.client, .clientMute, .router, .tracker]) { Text($0.title).tag($0) } }
            Button("Set up node") {
                Task { await admin.apply(changes, summary: "Setup") }
            }
            .buttonStyle(.field(.primary, .regular))
            .disabled(region == .unset || admin.isWorking)
        } header: {
            ModuleHeader(nil, "Set up this node")
        }
        .fieldSection()
    }

    private var changes: [NodeAdmin.Change] {
        let s = radio.session
        var out: [NodeAdmin.Change] = []
        if !longName.isEmpty, var o = s.ownerRaw.map(Owner.init) {
            o.longName = longName
            if !shortName.isEmpty { o.shortName = shortName }
            out.append(.owner(o.patched))
        }
        if var d = s.device, d.role != role {
            d.role = role
            out.append(.config(.device, d.patched))
        }
        if var l = s.lora {
            l.region = region
            l.usePreset = true
            l.txEnabled = true
            if l.hopLimit == 0 { l.hopLimit = 3 }
            out.append(.config(.lora, l.patched))
        }
        return out
    }
}

/// Edit, share or remove one channel; index -1 creates a new private one.
private struct ChannelEditor: View {
    @Environment(Radio.self) private var radio
    @Environment(NodeAdmin.self) private var admin
    @Environment(\.dismiss) private var dismiss
    let channel: ChannelInfo
    @State private var name = ""
    @State private var newKey = false
    @State private var confirmDelete = false
    @State private var copied: String?
    @State private var confirmOnly = false

    private var mySlot: Int? {
        guard let l = radio.session.lora else { return nil }
        return FrequencySlot.effective(lora: l, primaryName: radio.session.channels[0]?.name ?? "")
    }

    /// Our radio settings with the slot pinned, for the fox link.
    private var foxRadio: Data? {
        guard let l = radio.session.lora, let slot = mySlot else { return radio.session.config[.lora] }
        return FrequencySlot.pinned(l, slot: slot)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (up to 11 characters)", text: $name)
                        .font(Theme.Fonts.data)
                        .onChange(of: name) { _, v in if v.count > 11 { name = String(v.prefix(11)) } }
                    if channel.index >= 0 {
                        Toggle("Make a new random key", isOn: $newKey)
                        Text("A new key locks out everyone who had the old one until you share the channel again.")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("A new channel gets a random 256-bit key: only people you share it with can read it.")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    }
                } header: { ModuleHeader(1, channel.index < 0 ? "New channel" : "Channel \(channel.index)") }
                .fieldSection()
                if channel.index >= 0, let raw = channel.settings {
                    let add = ChannelLink(channels: [ChannelSettings(raw: raw)], lora: nil, add: true).url
                    let only = ChannelLink(channels: [ChannelSettings(raw: raw)], lora: foxRadio, add: false).url
                    Section {
                        QRImage(text: add).frame(maxWidth: .infinity).padding(.vertical, 8)
                        Button { UIPasteboard.general.string = add; copied = "add"; Haptics.success() } label: {
                            Label(copied == "add" ? "Copied" : "Copy link", systemImage: copied == "add" ? "checkmark" : "doc.on.doc")
                        }
                        ShareLink(item: add) { Label("Share link", systemImage: "square.and.arrow.up") }
                    } header: { ModuleHeader(2, "Add to another node") } footer: {
                        Text("Adds this channel next to the node's existing ones (hunters, the Den).")
                    }
                    .fieldSection()
                    if channel.index > 0 {
                        Section {
                            Button {
                                confirmOnly = true
                            } label: {
                                Label("Make this the only channel (fox)", systemImage: "pawprint")
                            }
                        } footer: {
                            Text("Moves this channel to primary, removes the others, and pins the frequency slot (\(mySlot.map(String.init) ?? "?")) so this node stays on everyone's frequency. The node restarts.")
                        }
                        .fieldSection()
                    }
                    Section {
                        Button { UIPasteboard.general.string = only; copied = "only"; Haptics.success() } label: {
                            Label(copied == "only" ? "Copied" : "Copy fox link", systemImage: copied == "only" ? "checkmark" : "pawprint")
                        }
                    } header: { ModuleHeader(3, "Make it a fox") } footer: {
                        Text("For a dedicated fox node: this channel becomes its only (primary) channel, so its beacons go out here and not on the public channel. The link pins your mesh's frequency slot (\(mySlot.map(String.init) ?? "?")) so the fox stays on the same frequency as everyone else.")
                    }
                    .fieldSection()
                }
                if channel.index > 0 {
                    Section {
                        Button("Remove channel", role: .destructive) { confirmDelete = true }
                            .buttonStyle(.field(.destructive, .regular))
                    }
                    .fieldSection()
                }
            }
            .fieldForm()
            .navigationTitle(channel.index < 0 ? "New channel" : "Channel \(channel.index)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(); dismiss() } }.disabled(channel.index < 0 && name.isEmpty)
                }
            }
            .onAppear { name = channel.name }
            .confirmationDialog("Make \(channel.name.isEmpty ? "this" : channel.name) this node's only channel?", isPresented: $confirmOnly, titleVisibility: .visible) {
                Button("Make it the fox channel", role: .destructive) {
                    guard let raw = channel.settings else { return }
                    let changes = NodeAdmin.makeOnlyChannel(raw, current: radio.session.channels, lora: radio.session.lora)
                    Task {
                        await admin.apply(changes, summary: "Fox channel")
                        dismiss()
                    }
                }
            } message: {
                Text("The other channels are removed from this node. Use this on a dedicated fox, not your everyday node.")
            }
            .confirmationDialog("Remove this channel from your node?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task {
                        await admin.apply([.channel(index: channel.index, settings: nil, role: .disabled)], summary: "Channel removal")
                        dismiss()
                    }
                }
            }
        }
        .presentationBackground(Theme.bg)
    }

    private func save() async {
        if channel.index < 0 {
            guard let slot = (1...7).first(where: { radio.session.channels[$0] == nil }) else { return }
            let s = ChannelSettings(name: name, psk: ChannelSettings.randomKey())
            await admin.apply([.channel(index: slot, settings: s.raw, role: .secondary)], summary: "New channel")
        } else {
            var s = ChannelSettings(raw: channel.settings ?? Data())
            s.name = name
            if newKey { s.psk = ChannelSettings.randomKey() }
            await admin.apply([.channel(index: channel.index, settings: s.patched, role: channel.role)], summary: "Channel")
        }
    }
}

/// Paste or scan a Wildcat channel link (wildcat://channel#…) and apply it.
private struct ImportChannelsSheet: View {
    @Environment(Radio.self) private var radio
    @Environment(NodeAdmin.self) private var admin
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scanning = false
    @State private var applyRadio = false

    private var link: ChannelLink? { ChannelLink(url: text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("wildcat://channel#…", text: $text, axis: .vertical).font(Theme.Fonts.dataSmall)
                    Button("Paste") { text = UIPasteboard.general.string ?? "" }
                    if DataScannerViewController.isSupported {
                        Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                    }
                } header: { ModuleHeader(1, "Link") }
                .fieldSection()
                if let link {
                    Section {
                        ForEach(Array(link.channels.enumerated()), id: \.offset) { _, c in
                            HStack {
                                Text(c.name.isEmpty ? "Primary (default name)" : c.name)
                                Spacer()
                                Tag(c.keyKind)
                            }
                        }
                        if link.lora != nil {
                            Toggle("Also use its radio settings (region and preset)", isOn: $applyRadio)
                        }
                    } header: { ModuleHeader(2, link.add ? "Adds these channels" : "Replaces all your channels with") }
                    .fieldSection()
                } else if !text.isEmpty {
                    Section { Notice(text: "That isn't a Meshtastic channel link.", color: Theme.alert) }.fieldSection()
                }
            }
            .fieldForm()
            .navigationTitle("Import channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard let link else { return }
                        let changes = NodeAdmin.changes(for: link, current: radio.session.channels, applyRadio: applyRadio,
                                                        lora: radio.session.lora)
                        Task {
                            await admin.apply(changes, summary: "Channels")
                            dismiss()
                        }
                    }
                    .disabled(link == nil)
                }
            }
            .sheet(isPresented: $scanning) {
                QRScanner(accept: { ChannelLink(url: $0) != nil }) { code in
                    text = code
                    scanning = false
                }
                .ignoresSafeArea()
            }
        }
        .presentationBackground(Theme.bg)
    }
}

/// A QR code on a white card (scanners need the white), in a hairline frame.
struct QRImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m + 4, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                .accessibilityLabel("QR code")
        }
    }

    static func render(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct QRSheet: View {
    let url: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                QRImage(text: url)
                ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.fieldSecondary)
                Text("Scan in Wildcat or the Meshtastic app to get these channels.").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screen()
            .navigationTitle("Your channels")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }
}
