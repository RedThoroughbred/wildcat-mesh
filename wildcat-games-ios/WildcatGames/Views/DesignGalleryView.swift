import SwiftUI
import UIKit
import WildcatRadioCore

/// Developer-only: every design-system piece with sample data, so the AB
/// components can be reviewed on a phone. Reached from Radio log (debug
/// builds). The network switch recolours everything that carries a network.
struct DesignGalleryView: View {
    @State private var network: MeshNetwork = .meshcore
    @State private var events: [TickerEvent] = DesignGalleryView.sampleEvents
    @State private var snr: Double = -3.25
    @State private var segment = 0
    @State private var toggle = true
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FieldSegmented(options: [(MeshNetwork.meshcore, "MeshCore"), (MeshNetwork.meshtastic, "Meshtastic")],
                               selection: $network)
                PacketTicker(events: events)
                    .padding(.horizontal, -Theme.Space.edge)
                Button("Add a packet") { addEvent() }
                    .buttonStyle(.field(.secondary, .small))

                tokens
                type
                thisRadio
                foxHunt
                signal
                messages
                raw
                rnodeHeard
                legacy
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xxl)
        }
        .screen()
        .navigationTitle("Design system")
        .navigationBarTitleDisplayMode(.inline)
        .tint(network.color)
        .toggleStyle(FieldToggleStyle())
        .task {
            // Keep the ticker moving while the gallery is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                addEvent()
            }
        }
    }

    // MARK: Sections

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(1, "Tokens")
            InstrumentPanel(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    swatchRow([("bg", Theme.bg), ("s1", Theme.surface1), ("s2", Theme.surface2), ("s3", Theme.surface3), ("well", Theme.well)])
                    swatchRow([("t1", Theme.textPrimary), ("t2", Theme.textSecondary), ("t3", Theme.textTertiary), ("t4", Theme.textQuaternary)])
                    swatchRow([("MT", Theme.meshtastic), ("MC", Theme.meshcore), ("ok", Theme.ok), ("alert", Theme.alert)])
                    HStack(spacing: 10) {
                        Text("hairline 7%").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Text("12%").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                        Rectangle().fill(Theme.hairlineStrong).frame(height: 1)
                    }
                }
            }
        }
    }

    private func swatchRow(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color)
                        .frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                    Text(name).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var type: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(2, "Type")
            InstrumentPanel(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        RemiMark(size: 44)
                        RemiMark(size: 30)
                        RemiMark(size: 20)
                        Spacer()
                    }
                    Text("MeshCore").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Wildcat Bag").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    Text("Row title").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                    Text("All good. Hearing 7 nodes, 2 of them repeaters.").font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary)
                    Text("Direct · strong signal · 1 min ago").font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                    Text("SNR 12.2 · −97 dBm · path 7a›c4›19").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    CardLabel("Section label")
                    Text("FOX-4827").font(Theme.Fonts.display).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var thisRadio: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(3, "This radio", action: "Switch", symbol: "antenna.radiowaves.left.and.right") {}
            InstrumentPanel {
                HStack(spacing: 12) {
                    IconTile(symbol: network.symbol, tint: network.color, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Wildcat Bag").font(.system(.headline, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Tag("Companion")
                        }
                        HStack(spacing: 7) {
                            StatusLED()
                            Text("Connected · BLE").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                            Text("7a3f91c2").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(14)
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Battery", value: "3.98", unit: "V", size: .large) {
                        HStack(spacing: 7) {
                            SegmentMeter(value: 0.82, segments: 10, tint: Theme.ok)
                            Text("82%").font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    CellDivider()
                    ReadoutCell("Airtime · 1h", value: "2.1", unit: "%", sub: "Quiet channel", size: .large) {
                        Sparkline(values: [3, 5, 2, 7, 4, 2, 6, 11, 4, 3, 6, 2], tint: network.color, style: .bars(highlight: 7))
                            .frame(width: 64, height: 11)
                    }
                }
                PanelDivider()
                ReadoutRow {
                    ReadoutCell("Noise", value: "−112", unit: "dBm")
                    CellDivider()
                    ReadoutCell("Best SNR", value: "9.5", unit: "dB")
                    CellDivider()
                    ReadoutCell("Uptime", value: "3d 04", unit: "h")
                }
            }
            StatusKeyRow {
                StatusKey("Link", sub: "BLE", led: .on)
                StatusKey("Bridge", sub: "⇄ \(network == .meshcore ? "MT" : "MC")", led: .on)
                StatusKey("GPS", sub: "Off", led: .off)
                StatusKey("Advert", sub: "Send", led: .network(network))
            }
        }
    }

    private var foxHunt: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(4, "Fox hunt", detail: "20-step meter")
            InstrumentPanel {
                ReadoutCell("Signal", value: snr.formatted(.number.precision(.fractionLength(2))), unit: "dB SNR", size: .hero)
                SegmentMeter(value: SegmentMeter.snrFraction(snr), segments: 20, network: network, size: .large,
                             scale: SegmentMeter.snrScale)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                PanelDivider()
                VStack(alignment: .leading, spacing: 8) {
                    CardLabel("Trend · 2 min")
                    Sparkline(values: [2, 3, 2, 4, 4, 5, 5, 7, 6, 8, 14, 7, 6, 8, 7, 9, 8, 10, 10, 11, 10, 12],
                              tint: network.color, style: .bars(highlight: nil), reference: 14)
                        .frame(height: 44)
                }
                .padding(12)
            }
            Slider(value: $snr, in: -20...20)
            StatusKeyRow {
                StatusKey("Ping now", symbol: "scope", primary: true)
                StatusKey("Mark", symbol: "mappin.and.ellipse")
                StatusKey("Sound", symbol: "waveform.path.ecg", led: .on)
                StatusKey("End", symbol: "xmark")
            }
        }
    }

    private var signal: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(5, "Meters", detail: "both networks")
            InstrumentPanel(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MeshNetwork.allCases) { n in
                        HStack(spacing: 14) {
                            SegmentMeter(value: 0.8, network: n, size: .xs)
                            SegmentMeter(value: 0.6, network: n, size: .small)
                            SegmentMeter(value: 0.4, network: n, size: .regular)
                            SegmentMeter(value: 0.75, segments: 8, network: n, size: .xs)
                        }
                    }
                    ForEach([12.2, 6.75, 3.5, -3.25], id: \.self) { value in
                        SignalMeter(snr: value, network: network, showsValue: true)
                    }
                    SignalMeter(snr: nil, rssi: -104, showsValue: true)
                    SignalMeter(snr: nil, rssi: nil)
                    HStack(spacing: 16) {
                        Sparkline(values: [3, 4, 3, 6, 5, 7, 6, 9], tint: network.color, style: .line).frame(width: 80, height: 22)
                        Sparkline(values: [3, 4, 3, 6, 5, 7, 6, 9], tint: network.color, style: .bars(highlight: nil)).frame(width: 80, height: 22)
                        HStack { StatusLED(); StatusLED(color: network.color); StatusLED(color: Theme.alert); StatusLED(on: false) }
                    }
                }
            }
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(6, "Networks and meta")
            NetworkTag(.meshcore, via: "Wildcat Bag", style: .header)
            NetworkTag(.meshtastic, via: "GO", style: .header)
            NetworkTag(.meshtastic, via: "STAY", style: .header, connected: false)
            HStack(spacing: 10) {
                NetworkTag(.meshcore)
                NetworkTag(.meshtastic, via: "LongFast")
                Tag("Repeater")
                Tag("Mine", color: Theme.textTertiary)
            }
            FieldGroup {
                FieldRow(symbol: "number", tint: network.color, title: "Public", subtitle: "TrailRunner: Anyone hearing OAK?", detail: "19:44")
                FieldDivider()
                FieldRow(symbol: "person", title: "MAYA", subtitle: "You: ok, I'll swing by", detail: "18:02")
            }
            MetaLine("5 hops · strong signal", raw: "SNR 12.2 · −97 dBm · path 7a›c4›19›e2›5b", signal: 1, network: .meshcore)
            MetaLine("3 hops on Meshtastic, relayed here by Wildcat Bag", signal: 0.6, network: .meshtastic)
            MetaLine("heard by 3 repeaters", raw: "flood · 44 B · 63 ms", alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var raw: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(7, "Raw", action: "Copy all", symbol: "doc.on.doc") {
                UIPasteboard.general.string = KeyValueGrid.text(Self.sampleRows)
            }
            RawPacketView(data: Self.samplePacket,
                          fields: [("Path", "a4 › c4"), ("SNR", "4.5 dB"), ("RSSI", "−108"), ("RX", "Wildcat Bag")],
                          detail: "GRP_TXT · \(Self.samplePacket.count) B · 61 ms",
                          highlights: [ByteHighlight(range: 2..<5, color: network.color)], emphasis: 0..<1)
            KeyValueGrid(Self.sampleRows)
        }
    }

    /// The RNode console's "Heard on air", over a made-up session (the simulator has no RNode).
    private var rnodeHeard: some View {
        let session = Self.sampleRNodeSession
        return VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(8, "Heard on air", detail: "\(session.heardCounts.total)")
            RNodeHeardPanel(session: session)
            NavRow { RNodeHeardScreen(session: session, clear: {}) } label: {
                FieldRow(symbol: "list.bullet.rectangle", tint: RNodeStyle.color, title: "Sample heard list", subtitle: "Packets, announcers, filters")
                    .panel(.inset)
            }
            if let first = session.heard.first {
                NavRow { RNodeHeardDetail(heard: first) } label: {
                    FieldRow(symbol: "doc.text.magnifyingglass", title: "Sample packet detail", subtitle: first.kind.word).panel(.inset)
                }
            }
        }
        .tint(RNodeStyle.color)
    }

    private var legacy: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(9, "Shared components", detail: "remapped")
            SectionLabel("Section label", detail: "detail")
            HStack {
                StatusPill(text: "Practice", color: Theme.meshcore, live: true)
                StatusPill(text: "No node")
            }
            HStack(spacing: 8) {
                StatTile(label: "Nodes", value: "23", compact: true)
                StatTile(label: "Hops", value: "2", compact: true)
                StatTile(label: "Best", value: "−1.0", unit: "dB", compact: true)
            }
            HStack(spacing: 8) {
                Chip("Found", color: Theme.ok)
                Chip("Live", color: Theme.alert)
                Chip("Code")
                Chip("MT", color: Theme.meshtastic, small: true)
                Chip("MC", color: Theme.meshcore, small: true)
            }
            FieldSegmented(options: [(0, "All"), (1, "MeshCore"), (2, "Meshtastic")], selection: $segment)
            Button("Primary") {}.buttonStyle(.fieldPrimary)
            HStack {
                Button("Secondary") {}.buttonStyle(.field(.secondary, .regular))
                Button("Delete") {}.buttonStyle(.field(.destructive, .regular))
            }
            Button("Quiet") {}.buttonStyle(.fieldQuiet)
            Toggle("A switch", isOn: $toggle).foregroundStyle(Theme.textPrimary)
            LabeledField(title: "Hunt code", text: $text, prompt: "FOX-0000")
            Notice(text: "A neutral hint: blue is MeshCore, amber is Meshtastic.", symbol: "info.circle")
            Notice(text: "Couldn't reach the radio.", color: Theme.alert, symbol: "xmark.octagon")
            ToastBanner(text: "Channel saved", kind: .info)
            ToastBanner(text: "Found it", kind: .success)
            HeroCard(symbol: "scope", title: "Fox hunt", text: "Find a hidden radio by its signal.")
            FieldGroup {
                FieldRow(symbol: "map", title: "Mesh map", subtitle: "Every node with a position")
                FieldDivider()
                FieldRow(symbol: "trash", tint: Theme.alert, title: "Remove", chevron: false)
            }
            EmptyState(symbol: "text.alignleft", title: "No traffic yet", text: "Messages appear here.")
                .panel()
        }
    }

    // MARK: Sample data (made-up names only)

    private func addEvent() {
        let kinds = ["ADVERT", "GRP_TXT", "TXT_MSG", "ACK", "TEXT", "POSITION"]
        let names = ["OAK.RPT.02", "MAYA", "#public", "N0CALL", "TrailRunner", "Wildcat Solar"]
        events.append(TickerEvent(network: Bool.random() ? .meshcore : .meshtastic,
                                  direction: Int.random(in: 0..<5) == 0 ? .tx : .rx,
                                  kind: kinds.randomElement(),
                                  text: "\(names.randomElement() ?? "MAYA") \(Int.random(in: -12...12))dB"))
        if events.count > 20 { events.removeFirst(events.count - 20) }
    }

    static let sampleEvents: [TickerEvent] = [
        TickerEvent(network: .meshcore, kind: "ADVERT", text: "OAK.RPT.02 −3.2dB", time: .now.addingTimeInterval(-4)),
        TickerEvent(network: .meshcore, kind: "GRP_TXT", text: "#public 5h", time: .now.addingTimeInterval(-12)),
        TickerEvent(network: .meshtastic, kind: "TEXT", text: "LongFast MAYA", time: .now.addingTimeInterval(-40)),
    ]

    static let samplePacket = Data([0x15, 0x00, 0x02, 0xa4, 0xc4, 0x3f, 0x9a, 0x07, 0xc1, 0xe2, 0x4d, 0x11, 0x8b, 0x70,
                                    0x2c, 0x5e, 0xd4, 0x0b, 0x93, 0x61, 0xaa, 0x7f, 0x03, 0xc8, 0x19, 0xe5, 0x42, 0xb6,
                                    0x0d, 0x71, 0x2e, 0x90])

    /// A made-up RNode session: radio on at the test settings, then a minute of Reticulum traffic
    /// (hand-built headers; the payloads are filler, not real announces).
    static let sampleRNodeSession: RNodeSession = {
        var s = RNodeSession()
        let start = Date().addingTimeInterval(-95)
        _ = s.handle(.spreadingFactor(8), now: start)
        _ = s.handle(.bandwidth(125_000), now: start)
        _ = s.handle(.codingRate(5), now: start)
        _ = s.handle(.radioState(true), now: start)
        if let phy = RNode.PhyStats(payload: [0x08, 0x00, 0x01, 0xE8, 0x00, 0x12, 0x00, 0x25, 0x00, 0x0C, 0x00, 0x30]) {
            _ = s.handle(.phyStats(phy), now: start)
        }
        func dest(_ seed: UInt8) -> Data { Data((0..<16).map { UInt8(truncatingIfNeeded: Int(seed) &* 37 &+ $0 &* 11) }) }
        func packet(_ flags: UInt8, hops: UInt8 = 0, to: Data, transport: Bool = false, context: UInt8 = 0, data: Int) -> Data {
            Data([flags, hops]) + (transport ? dest(99) : Data()) + to + Data([context]) + Data(repeating: 0x5A, count: data)
        }
        let path = ReticulumPacket.pathRequestDestination
        let traffic: [(Double, Int, Double, Data)] = [
            (0, -97, 9.25, packet(0x21, to: dest(1), data: 214)),
            (6, -112, 1.5, packet(0x51, hops: 2, to: dest(2), transport: true, data: 180)),
            (14, -97, 8.75, packet(0x08, to: path, data: 32)),
            (21, -104, 4.0, packet(0x02, to: dest(1), data: 67)),
            (22, -98, 9.0, packet(0x0F, to: dest(3), context: 0xFF, data: 96)),
            (40, -103, 5.5, packet(0x0C, to: dest(3), context: 0x0E, data: 120)),
            (55, -121, -6.25, Data(repeating: 0x9C, count: 46)),
            (63, -118, -3.0, Data([0x00, 0xD3, 0x10, 0x44, 0x91])),
            (80, -99, 8.0, packet(0x21, to: dest(1), data: 214)),
            (92, -108, 3.25, packet(0x00, to: dest(4), data: 96)),
        ]
        for (dt, rssi, snr, raw) in traffic {
            let at = start.addingTimeInterval(dt)
            _ = s.handle(.rssi(rssi), now: at)
            _ = s.handle(.snr(snr), now: at)
            _ = s.handle(.data(raw), now: at)
        }
        return s
    }()

    static let sampleRows: [KeyValueItem] = [
        KeyValueItem(key: "pubkey", value: "c41977e25b0a93d1f00c7e", note: "copy"),
        KeyValueItem(key: "type", value: "REPEATER 0x02", note: "fw 1.8.2"),
        KeyValueItem(key: "radio", value: "910.525 · 62.5 · SF7 · 5", note: "22 dBm"),
        KeyValueItem(key: "advert", value: "19:41:25", note: "42 s"),
        KeyValueItem(key: "pos", value: "45.1234, −100.5678", note: "312 m"),
    ]
}

#Preview {
    NavigationStack { DesignGalleryView() }
}
