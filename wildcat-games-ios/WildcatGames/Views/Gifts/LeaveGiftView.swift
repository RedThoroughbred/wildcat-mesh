import MapKit
import SwiftUI
import WildcatRadioCore

/// Drop a pin, write a message, send it.
struct LeaveGiftView: View {
    @Environment(GiftStore.self) private var gifts
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @State private var meshcoreChannel = 0
    @Environment(\.dismiss) private var dismiss
    @State private var spot: LatLon?
    @State private var message = ""
    @State private var teaser = ""
    @State private var precision = Gift.Precision.tight
    @State private var hint = 300
    @State private var delivery = Delivery.link
    @State private var channel = 0
    @State private var recipient: NodeNum?
    @State private var done: GiftStore.Sent?
    @State private var error: String?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    enum Delivery: Hashable { case link, everyone, person, meshcore }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MapReader { proxy in
                        Map(position: $camera) {
                            UserAnnotation()
                            if let spot {
                                Annotation("Gift", coordinate: spot.coordinate) { GiftPin() }
                            }
                        }
                        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                        .onTapGesture { pt in
                            if let c = proxy.convert(pt, from: .local) {
                                Haptics.selection()
                                spot = LatLon(lat: c.latitude, lon: c.longitude)
                            }
                        }
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                    Button("Use where I'm standing") { if let h = gifts.here { spot = h } }
                        .disabled(gifts.here == nil)
                } header: { SectionLabel("The spot") } footer: {
                    Text(spot == nil ? "Tap the map to drop the gift, or use where you're standing." : "Tap the map to move it.")
                }
                .fieldSection()
                Section {
                    TextField("Your message", text: $message, axis: .vertical).lineLimit(3...6)
                    Text("\(message.utf8.count)/\(GiftCodec.maxMessageBytes)").font(Theme.Fonts.labelSmall)
                        .foregroundStyle(message.utf8.count > GiftCodec.maxMessageBytes ? Theme.hot : Theme.textSecondary)
                    TextField("Teaser they see before (e.g. \"where we met\")", text: $teaser)
                        .onChange(of: teaser) { _, v in if v.utf8.count > GiftCodec.maxTeaserBytes { teaser = String(v.prefix(GiftCodec.maxTeaserBytes)) } }
                } header: { SectionLabel("The gift") }
                .fieldSection()
                Section {
                    Picker("Opens within", selection: $precision) {
                        ForEach(Gift.Precision.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Hint area", selection: $hint) {
                        Text("Show the exact spot").tag(0)
                        Text("300 m circle").tag(300)
                        Text("1 km circle").tag(1000)
                        Text("3 km circle").tag(3000)
                    }
                } header: { SectionLabel("How hard") } footer: {
                    Text("They see the circle (or the spot) and your teaser. The message stays locked until they stand on the spot.")
                }
                .fieldSection()
                Section {
                    Picker("Send", selection: $delivery) {
                        Text("As a link or QR (no radio)").tag(Delivery.link)
                        Text("Over the mesh to everyone on a channel").tag(Delivery.everyone)
                        Text("Over the mesh to one person").tag(Delivery.person)
                        Text("MeshCore: everyone on a channel").tag(Delivery.meshcore)
                    }
                    if delivery == .meshcore {
                        Picker("MeshCore channel", selection: $meshcoreChannel) {
                            ForEach(meshcore.session.channels.values.sorted { $0.index < $1.index }, id: \.index) {
                                Text(meshcore.session.label(.channel($0.index))).tag($0.index)
                            }
                        }
                        let size = GiftCodec.encodedSize(message: message, teaser: teaser)
                        Text("\(size) of \(MeshCore.maxChannelData) bytes (MeshCore packets are smaller: keep message + teaser under \(MeshCore.maxChannelData - 52))")
                            .font(Theme.Fonts.dataSmall)
                            .foregroundStyle(size > MeshCore.maxChannelData ? Theme.hot : Theme.textSecondary)
                        if !meshcore.state.isReady {
                            NeedsRadioNotice(.meshcore, why: "It sends the gift on a MeshCore channel.", onOpenTab: { dismiss() })
                        }
                    }
                    if delivery == .everyone {
                        Picker("Channel", selection: $channel) {
                            ForEach(radio.session.channels.values.sorted { $0.index < $1.index }, id: \.index) {
                                Text($0.name.isEmpty ? "Primary" : $0.name).tag($0.index)
                            }
                        }
                    }
                    if delivery == .person {
                        Picker("To", selection: $recipient) {
                            Text("Choose…").tag(NodeNum?.none)
                            ForEach(radio.session.nodes.values.filter { $0.num != radio.session.myNode }
                                        .sorted { ($0.longName ?? "") < ($1.longName ?? "") }, id: \.num) {
                                Text("\($0.shortName ?? "?") · \($0.longName ?? $0.num.id)").tag(NodeNum?.some($0.num))
                            }
                        }
                    }
                    if (delivery == .everyone || delivery == .person) && !radio.isReady {
                        NeedsRadioNotice(.meshtastic, why: "It sends the gift over the mesh. The link works without a radio.", onOpenTab: { dismiss() })
                    }
                } header: { SectionLabel("Deliver") }
                .fieldSection()
                if let error {
                    Section { Notice(text: error, color: Theme.hot) }.fieldSection()
                }
            }
            .fieldForm()
            .navigationTitle("Leave a gift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Leave it") { leave() }.disabled(!canLeave) }
            }
            .onAppear {
                gifts.startWatching()
                if spot == nil { spot = gifts.here }
            }
            .onDisappear { gifts.stopWatching() }
            .onChange(of: gifts.here) { _, h in if spot == nil { spot = h } }
            .sheet(item: $done, onDismiss: { dismiss() }) { SentSheet(gift: $0) }
        }
        .presentationBackground(Theme.bg)
    }

    private var canLeave: Bool {
        spot != nil && !message.isEmpty && message.utf8.count <= GiftCodec.maxMessageBytes
            && (delivery == .link || delivery == .meshcore || radio.isReady) && (delivery != .person || recipient != nil)
            && (delivery != .meshcore || (meshcore.state.isReady
                                          && GiftCodec.encodedSize(message: message, teaser: teaser) <= MeshCore.maxChannelData))
    }

    private func leave() {
        guard let spot else { return }
        do {
            done = try gifts.leave(message: message, teaser: teaser, at: spot, precision: precision, hintRadius: hint,
                                   to: delivery == .person ? recipient : nil,
                                   broadcastChannel: delivery == .everyone ? channel : nil,
                                   meshcoreChannel: delivery == .meshcore ? meshcoreChannel : nil)
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SentSheet: View {
    let gift: GiftStore.Sent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    IconTile(symbol: "gift", tint: Theme.ok, size: 48)
                    Text("Gift left").font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    Text(gift.to != nil ? "Sent over the mesh. Also share the link in case they're out of range."
                         : "Share the link or QR code. It opens only at the spot.")
                        .font(Theme.Fonts.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let g = gift.gift {
                        let link = GiftCodec.link(g)
                        QRImage(text: link)
                        ShareLink(item: link, message: Text("I left you something. Open it in Wildcat when you're there.")) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.fieldPrimary)
                    }
                }
                .padding(24)
            }
            .screen()
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
    }
}
