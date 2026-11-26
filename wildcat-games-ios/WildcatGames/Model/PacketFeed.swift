import Foundation
import Observation
import WildcatRadioCore

/// Recent on-air activity from both radios, newest first, for the live packet
/// strip (`PacketTicker`). One more listener on each link; purely presentational.
@MainActor
@Observable
final class PacketFeed {
    /// Newest first, capped at `limit`.
    private(set) var events: [TickerEvent] = []
    private let limit = 40

    /// How well this phone's MeshCore radio last heard a node, from its adverts
    /// and direct messages. MeshCore contacts carry no signal of their own.
    struct NodeSignal: Equatable {
        var snr: Double
        var rssi: Int?
        /// Repeaters it came through (0: heard directly, so the SNR is the node's own).
        var hops: Int
        var at: Date
    }

    /// Keyed by the first 6 bytes of the public key (a contact's `prefix`).
    private(set) var meshcoreSignals: [Data: NodeSignal] = [:]

    init(radio: Radio, meshcore: MeshCoreLink) {
        radio.addListener { [weak self] event in
            guard let self, case .packet(let p) = event else { return }
            self.push(Self.meshtastic(p, radio: radio))
        }
        meshcore.addListener { [weak self, weak meshcore] event in
            guard let self else { return }
            switch event {
            case .heard(let snr, let rssi, let raw):
                if let e = Self.meshcore(raw, snr: snr) { self.push(e) }
                if let (key, s) = Self.advertSignal(raw, snr: snr, rssi: rssi) { self.meshcoreSignals[key] = s }
            case .message(let chat) where chat.direction == .sent:
                self.push(TickerEvent(network: .meshcore, direction: .tx, kind: "TXT", text: Self.short(chat.text)))
            case .message(let chat):
                if case .contact(let p) = chat.origin, let snr = chat.snr, snr.isFinite {
                    self.meshcoreSignals[Data(p.prefix(6))] = NodeSignal(snr: snr, rssi: chat.rssi, hops: chat.hops ?? 0,
                                                                         at: chat.receivedAt ?? chat.at)
                }
            case .ready where meshcore?.isDemo == true:
                if let meshcore { self.startPractice(meshcore) }
            default:
                break
            }
        }
    }

    /// The events for one network only (MeshCore or Meshtastic screens).
    func events(for network: MeshNetwork) -> [TickerEvent] { events.filter { $0.network == network } }

    /// The last signal heard from a MeshCore node (by public key or prefix).
    func signal(meshcore key: Data) -> NodeSignal? { meshcoreSignals[Data(key.prefix(6))] }

    /// Who sent an advert heard on air, and how well.
    static func advertSignal(_ raw: Data, snr: Double, rssi: Int, at: Date = Date()) -> (Data, NodeSignal)? {
        guard snr.isFinite, let pkt = MeshCorePacket(raw), let advert = pkt.advert, advert.publicKey.count >= 6 else { return nil }
        return (Data(advert.publicKey.prefix(6)), NodeSignal(snr: snr, rssi: rssi, hops: pkt.hops, at: at))
    }

    // MARK: Practice

    /// Practice starts with a signal for every contact; the practice node's own made-up
    /// packets (adverts, group texts) keep the strip and the readings moving after that.
    private func startPractice(_ link: MeshCoreLink) {
        for c in link.session.contacts.values { meshcoreSignals[Data(c.prefix)] = Self.practiceSignal(c) }
    }

    /// A steady pretend reading: near repeaters strong, far chat nodes weak.
    static func practiceSignal(_ c: MeshCore.Contact) -> NodeSignal {
        let hops = max(0, c.pathLength ?? 0)
        let seed = Double((c.publicKey.first ?? 0) % 7)
        return NodeSignal(snr: 10.5 - Double(hops) * 5.5 - seed * 0.5, rssi: -88 - hops * 9 - Int(seed),
                          hops: hops, at: c.lastAdvert ?? Date())
    }

    private func push(_ e: TickerEvent) {
        events.insert(e, at: 0)
        if events.count > limit { events.removeLast(events.count - limit) }
    }

    static func meshtastic(_ p: MeshPacket, radio: Radio) -> TickerEvent {
        let who = radio.session.nodes[p.from]?.shortName ?? p.from.short
        let kind: String
        switch p.portnum {
        case .text?: kind = "TXT"
        case .position?: kind = "POS"
        case .nodeInfo?: kind = "INFO"
        case .telemetry?: kind = "TELEM"
        case .routing?: kind = "ACK"
        case .traceroute?: kind = "TRACE"
        case .waypoint?: kind = "WPT"
        case .privateApp?: kind = "APP"
        default: kind = p.isEncrypted ? "ENC" : "PKT"
        }
        var parts = [who]
        if let snr = p.rxSNR { parts.append(String(format: "%.1fdB", snr).replacingOccurrences(of: "-", with: "−")) }
        if let start = p.hopStart, let limit = p.hopLimit, start >= limit { parts.append("\(start - limit)h") }
        if p.viaMQTT { parts.append("mqtt") }
        return TickerEvent(network: .meshtastic, kind: kind, text: parts.joined(separator: " "))
    }

    static func meshcore(_ raw: Data, snr: Double) -> TickerEvent? {
        guard let pkt = MeshCorePacket(raw) else { return nil }
        let kind: String
        switch pkt.type {
        case .advert?: kind = "ADVERT"
        case .groupText?: kind = "GRP_TXT"
        case .groupData?: kind = "GRP_DATA"
        case .text?: kind = "TXT"
        case .ack?: kind = "ACK"
        case .path?: kind = "PATH"
        case .trace?: kind = "TRACE"
        case .request?, .anonRequest?: kind = "REQ"
        case .response?: kind = "RESP"
        default: kind = "PKT"
        }
        var parts: [String] = []
        if let name = pkt.advert?.name, !name.isEmpty { parts.append(name) }
        parts.append(String(format: "%.1fdB", snr).replacingOccurrences(of: "-", with: "−"))
        parts.append("\(pkt.hops)h")
        return TickerEvent(network: .meshcore, kind: kind, text: parts.joined(separator: " "))
    }

    private static func short(_ s: String) -> String { s.count > 24 ? String(s.prefix(23)) + "…" : s }
}
