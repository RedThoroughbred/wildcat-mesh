#if DEBUG
import SwiftUI
import WildcatRadioCore

/// Developer-only: every bubble state on both networks with made-up data, for
/// checking the chat design without radios (launch with -ChatSamples).
struct ChatSamplesView: View {
    @State private var network: MeshNetwork = .meshcore
    @State private var draft = "Solar is up"

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Self.lines(network)) { l in
                    MessageBubble(line: l, expanded: l.text.hasPrefix("Heard it direct") || l.text.hasPrefix("ok, back"),
                                  onRetry: {})
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.vertical, 10)
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                Picker("Network", selection: $network) {
                    Text("MeshCore").tag(MeshNetwork.meshcore)
                    Text("Meshtastic").tag(MeshNetwork.meshtastic)
                }
                .pickerStyle(.segmented)
                ChatStrip(cells: network == .meshcore
                          ? [("Heard", "23"), ("Mode", "flood"), ("SF / BW", "7 / 62.5"), ("MHz", "910.525")]
                          : [("Heard", "12"), ("Preset", "LongFast"), ("Slot", "20"), ("Ch util", "4.2%")])
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.bottom, 6)
            .background(Theme.bg)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(network: network, target: network == .meshcore ? "Public" : "LongFast",
                         through: network == .meshcore ? "Wildcat Bag" : "GO", text: $draft,
                         limit: network == .meshcore ? MeshCore.maxTextBytes : 200, airtimeMs: 63, onSend: {})
        }
        .screen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitle(title: network == .meshcore ? "# Public" : "# LongFast", network: network,
                          via: network == .meshcore ? "Wildcat Bag" : "GO")
            }
        }
    }

    static func lines(_ n: MeshNetwork) -> [ChatLine] {
        let now = Date()
        func t(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        if n == .meshcore {
            var a = ChatLine(id: UUID(), network: .meshcore, sender: "TrailRunner", senderID: "9e41c0d2", time: t(6),
                             text: "Anyone hearing OAK.RPT.02 tonight? It dropped off my path around 7.")
            a.hops = 5; a.snr = 12.2; a.rssi = -97
            a.path = [Data([0x7a]), Data([0xc4]), Data([0x19]), Data([0xe2]), Data([0x5b])]
            var b = ChatLine(id: UUID(), network: .meshcore, sender: "Kestrel", senderID: "b20e7741", time: t(5),
                             text: "Heard it direct from the ridge at 18:50. Maybe snow on the panel?")
            b.hops = 2; b.snr = 4.5; b.rssi = -108; b.path = [Data([0xa4]), Data([0xc4])]
            b.kind = "GRP_TXT"; b.size = 42; b.airtimeMs = 61; b.radioName = "Wildcat Bag"
            b.raw = Data([0x15, 0x02, 0xa4, 0xc4, 0x3f, 0x9a, 0x07, 0xc1, 0xe2, 0x4d, 0x11, 0x8b, 0x70, 0x2c, 0x5e, 0xd4,
                          0x0b, 0x93, 0x61, 0xaa, 0x7f, 0x03, 0xc8, 0x19, 0xe5, 0x42, 0xb6, 0x0d])
            var c = ChatLine(id: UUID(), network: .meshcore, sender: "Juniper", senderID: "!a3f9c21e", time: t(5),
                             text: "copy, quiet on my side too.")
            c.bridged = BridgeOrigin(network: .meshtastic, senderID: "!a3f9c21e", senderName: "Juniper", channel: "LongFast", hops: 3, via: "GO")
            c.bridgeVia = "GO"
            c.snr = 6; c.rssi = -95
            var d = ChatLine(id: UUID(), network: .meshcore, mine: true, time: t(4), text: "Solar is up. I'll check OAK tomorrow.")
            d.flood = true; d.size = 44; d.airtimeMs = 63; d.status = .heardBy(3)
            var e = ChatLine(id: UUID(), network: .meshcore, mine: true, time: t(1), text: "Anyone near the windmill?")
            e.flood = true; e.size = 38; e.airtimeMs = 57; e.status = .unheard
            // Direct messages: sending again, on air by flood, and given up (with Retry).
            var f = ChatLine(id: UUID(), network: .meshcore, mine: true, time: t(1), text: "Bringing the spare antenna")
            f.direct = true; f.flood = false; f.size = 38; f.airtimeMs = 57; f.status = .retrying(try: 2)
            var g = ChatLine(id: UUID(), network: .meshcore, mine: true, time: t(0.6), text: "Meet at the trailhead?")
            g.direct = true; g.flood = true; g.size = 38; g.airtimeMs = 57; g.status = .awaiting(try: 3, flood: true)
            var h = ChatLine(id: UUID(), network: .meshcore, mine: true, time: t(0.2), text: "Are you still on the ridge?")
            h.direct = true; h.flood = true; h.size = 38; h.airtimeMs = 57; h.status = .undelivered("No confirmation after 3 tries")
            return [a, b, c, d, e, f, g, h]
        }
        var a = ChatLine(id: UUID(), network: .meshtastic, sender: "Juniper", senderID: "!a3f9c21e", time: t(8),
                         text: "copy, seeing it through the bridge")
        a.hops = 3; a.hopStart = 3; a.hopLimit = 0; a.snr = 6.75; a.rssi = -88; a.relayNode = 0x2c
        a.reactions = [("👍", 2)]
        var b = ChatLine(id: UUID(), network: .meshtastic, sender: "TrailRunner", time: t(7), text: "Solar is up on OAK.")
        b.bridged = BridgeOrigin(network: .meshcore, senderName: "TrailRunner", channel: "Public", hops: 5, via: "Wildcat Bag")
        b.bridgeVia = "Wildcat Bag"
        var c = ChatLine(id: UUID(), network: .meshtastic, sender: "Kestrel", senderID: "!9e766b18", time: t(6),
                         text: "ok, back at the trailhead")
        c.quote = .init(sender: "Juniper", text: "copy, seeing it through the bridge")
        c.hops = 0; c.snr = -3.25; c.rssi = -112; c.kind = "TEXT"; c.size = 58; c.airtimeMs = 330; c.radioName = "GO"
        var d = ChatLine(id: UUID(), network: .meshtastic, mine: true, time: t(3), text: "See you at 8")
        d.size = 30; d.airtimeMs = 207; d.status = .delivered; d.roundTripMs = 1800; d.direct = true
        var e = ChatLine(id: UUID(), network: .meshtastic, mine: true, time: t(1), text: "Anyone on the hill?")
        e.size = 35; e.airtimeMs = 240; e.status = .failed("Nobody acknowledged it")
        return [a, b, c, d, e]
    }
}
#endif
