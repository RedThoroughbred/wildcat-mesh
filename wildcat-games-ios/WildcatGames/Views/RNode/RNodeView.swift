import SwiftUI
import WildcatRadioCore

/// The RNode console: find an RNode (a LoRa modem for the Reticulum network) over Bluetooth,
/// pair, then an instrument panel for it: who it is, its radio settings, what it hears, its
/// battery. Phase 1 reads and tunes; it never transmits. Same skeleton as the network tabs:
/// This radio, Radio settings, Signal, Heard on air, Power.
struct RNodeView: View {
    @Environment(RNodeLink.self) private var link
    @State private var pending = PendingScan()
    @State private var confirmDisconnect = false
    @State private var showRadioHelp = false
    @State private var showPairingHelp = false
    @State private var showInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                switch link.state {
                case .ready: console
                case .connecting(let n), .starting(let n): connecting(n)
                default: finder
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: link.state.isReady)
        }
        .refreshable { if link.state.isReady { link.refreshParameters(); link.refreshCounters() } }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: RNodeStyle.symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(RNodeStyle.color)
                Text("RNode")
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Tag("Reticulum", color: RNodeStyle.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.bottom, 8)
            .background(Theme.bg.ignoresSafeArea(edges: .top))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .screen()
        .navigationTitle("RNode")
        .navigationBarTitleDisplayMode(.inline)
        .hidesNavigationTitle()
        .tint(RNodeStyle.color)
        .confirmationDialog("Disconnect \(link.state.isReady ? name : "the RNode")?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { link.disconnect() }
        } message: {
            Text("The RNode keeps its settings until it reboots. Reconnect from here; a paired phone needs no PIN.")
        }
        .sheet(isPresented: $showInfo) { RNodeInfoSheet() }
        .onDisappear {
            pending.cancel()
            if link.state == .scanning { link.stopScan() }
        }
    }

    private var name: String {
        if case .ready(let n) = link.state { return n }
        return link.lastNodeName ?? "RNode"
    }

    // MARK: Not connected

    private var finder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            ModuleHeader(1, "This radio", detail: link.lastNodeName)
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Theme.hairline, lineWidth: 1).frame(width: 96, height: 96)
                    Circle().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4])).frame(width: 68, height: 68)
                    Image(systemName: looking ? "dot.radiowaves.left.and.right" : RNodeStyle.symbol)
                        .font(.system(size: 28))
                        .foregroundStyle(RNodeStyle.color)
                        .symbolEffect(.variableColor.iterative, isActive: looking)
                }
                .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(looking ? "Looking for RNodes…" : "No RNode connected")
                        .font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("An RNode is a LoRa modem for the Reticulum network. Wildcat reads and tunes it over Bluetooth. Stop Reticulum (rnsd, Sideband) on your computer first: an RNode talks to one host at a time.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let why) = link.state { ToastBanner(text: why, kind: .danger) }
                if link.state == .poweredOff || link.state == .unauthorized {
                    BluetoothNotice(allowed: link.state == .poweredOff)
                }
                VStack(spacing: 8) {
                    Button { if !looking { find() } } label: {
                        Label(link.state == .scanning ? "Scanning…" : pending.isWaiting ? "Waiting for Bluetooth…" : "Find RNodes",
                              systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.fieldPrimary)
                    if link.lastNodeID != nil {
                        Button { reconnect() } label: {
                            Label("Reconnect \(link.lastNodeName ?? "the last one")", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.field(.secondary, .regular))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .instrumentPanel()
            StatusKeyRow {
                StatusKey("Link", sub: "Off", led: .off)
                StatusKey("Bluetooth", sub: bluetoothWord, led: bluetoothLED)
                StatusKey("Scan", sub: looking ? "On" : "Idle", led: looking ? .custom(RNodeStyle.color) : .off) { if !looking { find() } }
            }
            if !link.discovered.isEmpty {
                let rnodes = link.discovered.filter(\.isRNode).sorted { $0.rssi > $1.rssi }
                let others = link.discovered.count - rnodes.count
                ModuleHeader(2, "Found nearby", detail: "\(rnodes.count)")
                if rnodes.isEmpty {
                    EmptyState(symbol: RNodeStyle.symbol, title: "No RNode yet",
                               text: others > 0 ? "\(others) other Bluetooth UART device\(others == 1 ? "" : "s") nearby (MeshCore nodes use the same service), none named RNode."
                                                : "RNodes advertise as “RNode XXXX”. Is Bluetooth on in its firmware (rnodeconf -b)?")
                        .panel(.inset)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rnodes.enumerated()), id: \.element.id) { i, d in
                            if i > 0 { FieldDivider() }
                            Button { link.connect(d.id) } label: { discoveredRow(d) }
                                .buttonStyle(.rowPress)
                        }
                    }
                    .panel(.inset)
                    if others > 0 {
                        Text("\(others) other UART device\(others == 1 ? "" : "s") hidden: MeshCore nodes share this Bluetooth service.")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            ModuleHeader(link.discovered.isEmpty ? 2 : 3, "Pairing", action: showPairingHelp ? "Hide" : "How?", symbol: "questionmark.circle") {
                withAnimation(Theme.Motion.snappy) { showPairingHelp.toggle() }
            }
            if showPairingHelp {
                pairingHelp.transition(.opacity)
            } else {
                Text("The first connection needs a 6-digit PIN from the RNode. Tap How? for the steps.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
            }
            reticulumNote
        }
    }

    private var pairingHelp: some View {
        ExplainerPanel("Pairing an RNode",
                       text: "An RNode only talks to a paired phone, and most boards have no screen to show the PIN.") {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On the computer the RNode is plugged into, run rnodeconf -p <port>. The RNode opens pairing for 35 seconds and prints “Bluetooth pairing PIN is: 123456”.")
                step(2, "Within those 35 seconds, tap the RNode above. iOS asks for the PIN; type the six digits.")
                step(3, "The RNode drops the link once right after pairing. Wildcat reconnects by itself, then reads it.")
                step(4, "Next time, just tap Reconnect: a paired phone needs no PIN. Boards with a screen show the PIN there; a pairing button does what rnodeconf -p does.")
                Text("Only one host at a time: quit rnsd or Sideband on the computer, or the RNode may not answer.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Theme.Fonts.dataBold).foregroundStyle(RNodeStyle.color).frame(width: 14, alignment: .trailing)
            Text(text).font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func discoveredRow(_ d: RNodeLink.Discovered) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: RNodeStyle.symbol, tint: RNodeStyle.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("RNode · Bluetooth · tap to connect").font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                SegmentMeter(lit: SignalGrade.bars(snr: nil, rssi: d.rssi), of: 5, tint: RNodeStyle.color)
                Text(MeshCoreFormat.minus("\(d.rssi) dBm")).font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .contentShape(Rectangle())
    }

    private func connecting(_ n: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            ModuleHeader(1, "This radio")
            InstrumentPanel {
                HStack(spacing: 14) {
                    IconTile(symbol: RNodeStyle.symbol, tint: RNodeStyle.color, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).tint(RNodeStyle.color)
                            Text(link.state == .connecting(n) ? "Connecting over Bluetooth…" : startingText)
                                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                PanelDivider()
                Text("If iOS asks for a PIN, it's the six digits rnodeconf -p printed (or on the RNode's screen). The RNode drops the link once after pairing; Wildcat reconnects.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Button("Cancel") { link.disconnect() }
                .buttonStyle(.field(.quiet, .regular))
                .frame(maxWidth: .infinity)
        }
    }

    private var startingText: String {
        switch link.session.phase {
        case .detecting: return "Pairing if needed, asking if it's an RNode…"
        case .readingInfo: return "Reading firmware and board…"
        case .readingParameters: return "Reading radio settings…"
        default: return "Starting…"
        }
    }

    private var looking: Bool { link.state == .scanning || pending.isWaiting }

    private var bluetoothWord: String {
        switch link.bluetooth {
        case .notStarted: return "Not used yet"
        case .starting: return "Starting"
        case .on: return "On"
        case .off: return "Off"
        case .unauthorized: return "Not allowed"
        case .unsupported: return "None"
        }
    }

    private var bluetoothLED: StatusKey.LED {
        switch link.bluetooth {
        case .on: return .on
        case .off, .unauthorized, .unsupported: return .warn
        default: return .off
        }
    }

    private func find() {
        let link = link
        pending.start {
            switch link.state {
            case .unauthorized, .scanning, .connecting, .starting, .ready: return true
            default: link.scan(); return link.state == .scanning
            }
        }
    }

    private func reconnect() {
        let link = link
        pending.start {
            if link.state == .unauthorized { return true }
            let before = link.state
            link.reconnectLast()
            return link.state != before
        }
    }

    // MARK: Connected

    @ViewBuilder private var console: some View {
        let s = link.session
        ModuleHeader(1, "This radio", action: "Disconnect", symbol: "xmark") { confirmDisconnect = true }
        RNodeDeviceCard(showInfo: $showInfo)
        if link.hostAttached {
            Notice(text: "Reticulum (beta) is driving this RNode. The console only watches: settings and the radio switch wait until Reticulum stops.",
                   color: RNodeStyle.color, symbol: ReticulumStyle.symbol)
        }

        ModuleHeader(2, "Radio settings", action: showRadioHelp ? "Hide" : "What's this?", symbol: "questionmark.circle") {
            withAnimation(Theme.Motion.snappy) { showRadioHelp.toggle() }
        }
        NavRow { RNodeSettingsView() } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    if s.parameters.isComplete || s.parameters.canTurnOn {
                        RadioChips(frequency: s.parameters.frequencyMHz, bandwidth: s.parameters.bandwidthKHz,
                                   spreadingFactor: s.parameters.spreadingFactor, codingRate: s.parameters.codingRate,
                                   txPower: s.parameters.txPower)
                        Text(s.parameters.bitrateKbps.map { "\(RNodeFormat.kbps($0)) kbps on air · radio \(s.parameters.radioOn == true ? "on" : "off")" }
                             ?? "Radio \(s.parameters.radioOn == true ? "on" : "off")")
                            .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Not set since the RNode booted").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                        Text(RNodeFormat.unsetList(s.parameters)).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                Chevron()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(.inset)
        }
        if showRadioHelp {
            ExplainerPanel("What are these numbers?",
                           text: "The frequency is the channel. Bandwidth (BW), spreading factor (SF) and coding rate (CR) trade speed for range. All four must match the other RNode exactly, or neither hears the other. dBm is how loud it transmits. Set them here: Reticulum (beta) uses what this RNode is set to, and remembers it for next time.")
                .transition(.opacity)
        }

        ModuleHeader(3, "Signal", detail: s.parameters.radioOn == true ? "live" : "radio off")
        RNodeSignalPanel()

        ModuleHeader(4, "Heard on air", detail: s.heardCounts.total > 0 ? "\(s.heardCounts.total)" : nil)
        RNodeHeardPanel(session: s)

        ModuleHeader(5, "Power")
        RNodePowerPanel()

        reticulumNote
    }

    @ViewBuilder private var reticulumNote: some View {
        reticulumExplainer
        ReticulumRow().panel(.inset)
    }

    private var reticulumExplainer: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: ReticulumStyle.symbol, tint: RNodeStyle.color, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("RNode is a modem for Reticulum").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                Text("Reticulum is an encrypted network that runs over LoRa and other links. This console reads and tunes the modem and shows the packets it hears. Messaging is on the Reticulum (beta) screen, which takes the RNode over while it runs.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.inset)
    }
}

// MARK: - Device card

/// The connected RNode as an instrument panel: who it is (what `rnodeconf --info` says),
/// one plain line, readouts, and the status keys.
struct RNodeDeviceCard: View {
    @Environment(RNodeLink.self) private var link
    @Binding var showInfo: Bool
    @State private var confirmDisconnect = false
    @State private var refreshedAt: Date?

    var body: some View {
        let s = link.session
        let d = s.device
        VStack(alignment: .leading, spacing: 8) {
            InstrumentPanel {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(symbol: RNodeStyle.symbol, tint: RNodeStyle.color, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(name).font(.system(.title2, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Tag("RNode", color: RNodeStyle.color)
                        }
                        HStack(spacing: 6) {
                            StatusLED(color: Theme.ok, size: 7)
                            Text("Connected · BLE").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                            if let v = d.firmwareVersion {
                                Text("·").foregroundStyle(Theme.textQuaternary)
                                Text("fw \(v)").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
                Text(summary(d))
                    .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 12)
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Product", value: d.productName ?? "—", sub: d.bandText ?? (d.isProvisioned ? nil : "EEPROM not provisioned"), size: .large)
                    CellDivider()
                    ReadoutCell("Firmware", value: d.firmwareVersion ?? "—", sub: d.mcuName.map(RNodeFormat.shortMCU) ?? d.platformName, size: .large)
                }
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Serial", value: d.eeprom?.isProvisioned == true ? (d.eeprom?.serialLine ?? "—") : "—")
                    CellDivider()
                    ReadoutCell("Max power", value: d.maxTxPower.map { "\($0)" } ?? "—", unit: d.maxTxPower == nil ? nil : "dBm")
                    CellDivider()
                    ReadoutCell("Signature", value: d.signatureState.word, sub: signatureSub(d),
                                tint: d.signatureState == .signed ? Theme.textPrimary : Theme.alert)
                }
                if let raw = rawLine(d) {
                    PanelDivider()
                    Text(raw)
                        .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
            keys
        }
        .confirmationDialog("Disconnect \(name)?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { link.disconnect() }
        } message: {
            Text("The RNode keeps its settings until it reboots. A paired phone reconnects without a PIN.")
        }
    }

    private var name: String {
        if case .ready(let n) = link.state { return n }
        return "RNode"
    }

    private func summary(_ d: RNode.DeviceInfo) -> String {
        var parts: [String] = []
        if let p = d.productName, let b = d.bandText { parts.append("A \(p) built for \(b)") }
        else if d.isProvisioned { parts.append("An RNode") } else { parts.append("An RNode whose EEPROM was never provisioned") }
        if let chip = d.modemChip { parts.append("\(chip) modem") }
        if let ok = d.firmwareIsCurrentEnough { parts.append(ok ? "firmware new enough for Reticulum" : "firmware too old for Reticulum (needs 1.52+)") }
        return parts.joined(separator: " · ") + "."
    }

    private func signatureSub(_ d: RNode.DeviceInfo) -> String? {
        switch d.signatureState {
        case .signed: return d.eeprom?.checksumValid == true ? "checksum OK" : nil
        case .unsigned: return "checksum OK"
        case .checksumMismatch: return "reflash with rnodeconf"
        case .unprovisioned: return "rnodeconf --autoinstall"
        }
    }

    /// "10:12:51 · nRF52840 · made 2026-10-07"
    private func rawLine(_ d: RNode.DeviceInfo) -> String? {
        var parts: [String] = []
        if let c = d.codes { parts.append(c) }
        if let m = d.mcuName { parts.append(RNodeFormat.shortMCU(m)) }
        if let made = d.eeprom?.made, d.isProvisioned { parts.append("made " + made.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))) }
        if let match = d.firmwareHashMatches { parts.append(match ? "firmware hash OK" : "firmware hash differs") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var keys: some View {
        let p = link.session.parameters
        return TimelineView(.periodic(from: .now, by: 1)) { t in
            let fresh = refreshedAt.map { t.date.timeIntervalSince($0) < 2 } ?? false
            StatusKeyRow {
                StatusKey("Link", sub: "BLE", led: .on) { confirmDisconnect = true }
                StatusKey("Radio", sub: p.radioOn == true ? "On" : p.canTurnOn ? "Off" : "Not set",
                          led: p.radioOn == true ? .on : p.canTurnOn ? .off : .warn) {
                    guard p.canTurnOn else { return }
                    link.setRadio(on: !(p.radioOn ?? false))
                    Haptics.success()
                }
                StatusKey("Read", sub: fresh ? "Done" : "Again", led: fresh ? .custom(RNodeStyle.color) : .off) {
                    link.refreshParameters()
                    link.refreshCounters()
                    refreshedAt = Date()
                }
                StatusKey("Info", sub: "rnodeconf", led: .none) { showInfo = true }
            }
        }
    }
}

// MARK: - Signal and power

/// What the modem hears: RSSI and noise floor now (channel stats, about once a second while
/// the radio is on), airtime and channel load, and the last packet's RSSI/SNR. Receive only.
struct RNodeSignalPanel: View {
    @Environment(RNodeLink.self) private var link

    var body: some View {
        let s = link.session
        let on = s.parameters.radioOn == true
        InstrumentPanel {
            if !on {
                Text(s.parameters.canTurnOn
                     ? "The radio is off, so the RNode measures nothing. Turn it on (the Radio key) to see the noise floor and whatever it hears. Wildcat only listens; nothing is transmitted in this phase."
                     : "Set the frequency, bandwidth, spreading factor and TX power first; the RNode won't turn its radio on without them.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    let c = s.channel
                    let stale = s.lastStatsAt.map { t.date.timeIntervalSince($0) > 5 } ?? true
                    ReadoutRow {
                        ReadoutCell("RSSI now", value: c.map { MeshCoreFormat.minus("\($0.rssi)") } ?? "—", unit: c == nil ? nil : "dBm", size: .large) {
                            HStack(spacing: 7) {
                                SegmentMeter(value: RNodeFormat.levelFraction(c?.rssi), segments: 10, tint: RNodeStyle.color)
                                Text(c == nil ? (stale ? "waiting for the first reading" : "") : stale ? "stale" : "live")
                                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        CellDivider()
                        ReadoutCell("Noise floor", value: c.map { MeshCoreFormat.minus("\($0.noiseFloor)") } ?? "—", unit: c == nil ? nil : "dBm", size: .large) {
                            HStack(spacing: 7) {
                                SegmentMeter(value: RNodeFormat.levelFraction(c?.noiseFloor), segments: 10, tint: Theme.textSecondary)
                                Text(c?.interference.map { "interference \(MeshCoreFormat.minus("\($0)")) dBm" } ?? "quiet")
                                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                    }
                }
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Airtime", value: s.channel.map { RNodeFormat.percent($0.airtimeShort) } ?? "—", unit: s.channel == nil ? nil : "%",
                                sub: s.channel.map { "\(RNodeFormat.percent($0.airtimeLong))% over the hour" } ?? "this RNode's own")
                    CellDivider()
                    ReadoutCell("Channel load", value: s.channel.map { RNodeFormat.percent($0.channelLoadShort) } ?? "—", unit: s.channel == nil ? nil : "%",
                                sub: s.channel.map { "\(RNodeFormat.percent($0.channelLoadLong))% over the hour" } ?? "everyone on the channel")
                    CellDivider()
                    ReadoutCell("Heard", value: "\(s.packetsHeard)", sub: s.signal.map { sig in
                        [sig.rssi.map { "\(MeshCoreFormat.minus("\($0)")) dBm" }, sig.snr.map { "SNR \(MeshCoreFormat.number($0))" }]
                            .compactMap { $0 }.joined(separator: " · ")
                    } ?? "packets, last RSSI/SNR")
                }
                if let phy = s.phy {
                    PanelDivider()
                    Text("symbol \(MeshCoreFormat.number(phy.symbolTimeMs)) ms · preamble \(phy.preambleSymbols) sym (\(phy.preambleTimeMs) ms) · CSMA slot \(phy.csmaSlotMs) ms · DIFS \(phy.difsMs) ms")
                        .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
        }
    }
}

/// Battery and temperature, as the RNode reports them by itself (about every 5 s on boards
/// that measure a battery). Many boards report nothing without a battery attached.
struct RNodePowerPanel: View {
    @Environment(RNodeLink.self) private var link

    var body: some View {
        let s = link.session
        InstrumentPanel {
            ReadoutRow {
                ReadoutCell("Battery", value: s.battery.map { "\($0.percent)" } ?? "—", unit: s.battery == nil ? nil : "%", size: .large) {
                    HStack(spacing: 7) {
                        SegmentMeter(value: Double(s.battery?.percent ?? 0) / 100, segments: 10,
                                     tint: (s.battery?.percent ?? 100) < 15 ? Theme.alert : Theme.ok)
                        Text(s.battery?.stateWord ?? "not reported (USB power, or no battery)")
                            .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                CellDivider()
                ReadoutCell("Temperature", value: s.temperature.map { "\($0)" } ?? "—", unit: s.temperature == nil ? nil : "°C",
                            sub: s.temperature == nil ? "not reported" : nil, size: .large)
            }
            if let rx = s.statRX, let tx = s.statTX {
                PanelDivider()
                Text("over the air since boot: \(rx) bytes received · \(tx) bytes sent")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
    }
}

// MARK: - Info sheet

/// What `rnodeconf --info` prints for this RNode, line for line, to compare with the computer.
struct RNodeInfoSheet: View {
    @Environment(RNodeLink.self) private var link
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = link.session.device.infoLines()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.stack) {
                    Text("Device info:").font(Theme.Fonts.label).tracking(Theme.labelTracking).foregroundStyle(Theme.textTertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
                    Text("The same block rnodeconf --info prints over USB, from the EEPROM read over Bluetooth. The signature line is the one difference: rnodeconf validates it with its signing keys; Wildcat checks the checksum and that a signature is present.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(link.session.device.signatureState.detail)
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.edge)
            }
            .screen()
            .navigationTitle("rnodeconf --info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Shared row

/// The way to the RNode console from the app menu and the network tabs' Manage groups.
struct RNodeRow: View {
    @Environment(RNodeLink.self) private var link

    var body: some View {
        NavRow { RNodeView() } label: {
            FieldRow(symbol: RNodeStyle.symbol, tint: link.state.isReady ? RNodeStyle.color : nil, title: "RNode console",
                     subtitle: "Read and tune a Reticulum LoRa modem over Bluetooth",
                     detail: link.state.isReady ? "Connected" : link.state.isBusy ? "Connecting" : nil)
        }
    }
}

/// The way to Reticulum (beta) from the app menu and the RNode console.
struct ReticulumRow: View {
    @Environment(\.tabRouter) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = ReticulumModel.shared
        let row = FieldRow(symbol: ReticulumStyle.symbol, tint: model.isRunning ? ReticulumStyle.color : nil, title: "Reticulum (beta)",
                           subtitle: "Encrypted messages over your RNode, with Sideband and other LXMF apps",
                           detail: model.isRunning ? "Running" : model.unread > 0 ? "\(model.unread) new" : nil)
        if let router {
            // Reticulum has its own tab: go there, closing the console (a sheet, or a push from that tab).
            Button {
                router.tab = .reticulum
                dismiss()
            } label: { row }
            .buttonStyle(.rowPress)
        } else {
            NavRow { ReticulumView() } label: { row }
        }
    }
}

// MARK: - Formatting

enum RNodeFormat {
    /// "3.13", "5.47".
    static func kbps(_ v: Double) -> String { String(format: "%.2f", v) }
    /// "2.9", "12", "0.4".
    static func percent(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
    /// "nRF52840" from "Nordic Semiconductor nRF52840".
    static func shortMCU(_ s: String) -> String { s.split(separator: " ").last.map(String.init) ?? s }
    /// -140 dBm (nothing) … -40 dBm (deafening) as 0…1 for a level meter.
    static func levelFraction(_ dBm: Int?) -> Double {
        guard let dBm else { return 0 }
        return max(0, min(1, (Double(dBm) + 140) / 100))
    }
    /// "frequency, bandwidth and TX power" for whatever is still unset.
    /// Why the radio switch is off limits, naming what the RNode still lacks (the coding rate
    /// isn't needed: the firmware starts it at 4/5).
    static func radioLockText(_ p: RNode.RadioParameters) -> String {
        var names: [String] = []
        if p.frequencyHz == nil { names.append("frequency") }
        if p.bandwidthHz == nil { names.append("bandwidth") }
        if p.spreadingFactor == nil { names.append("spreading factor") }
        if p.txPower == nil { names.append("transmit power") }
        guard !names.isEmpty else { return "" }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "The RNode hasn't been given its \(list) yet, so it won't turn its radio on. "
            + "A number shown above only counts once its Set button is pressed and the RNode answers."
    }

    static func unsetList(_ p: RNode.RadioParameters) -> String {
        var names: [String] = []
        if p.frequencyHz == nil { names.append("frequency") }
        if p.bandwidthHz == nil { names.append("bandwidth") }
        if p.spreadingFactor == nil { names.append("spreading factor") }
        if p.codingRate == nil { names.append("coding rate") }
        if p.txPower == nil { names.append("TX power") }
        guard !names.isEmpty else { return "All set." }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "Still unset: \(list). Set them here: Reticulum uses what this RNode is set to."
    }
}
