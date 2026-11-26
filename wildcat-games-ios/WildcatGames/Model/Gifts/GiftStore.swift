import CoreLocation
import Foundation
import Observation
import UserNotifications
import WildcatRadioCore

/// Gifts you've been given (locked until you stand on the spot) and gifts
/// you've left (with "opened" receipts). Saved on the phone.
@MainActor
@Observable
final class GiftStore: NSObject, CLLocationManagerDelegate {
    struct Received: Codable, Identifiable, Equatable {
        var id: UInt32
        var payload: Data
        var from: String?
        var fromName: String?
        var channel: Int?
        /// Set when it came over MeshCore (a channel datagram).
        var meshcoreChannel: Int?
        var received: Date
        var opened: Date?
        var message: String?

        var gift: Gift? { GiftCodec.decode(payload) }
    }

    struct Sent: Codable, Identifiable, Equatable {
        var id: UInt32
        var payload: Data
        var spot: LatLon
        var message: String
        var teaser: String
        var to: String?
        var sent: Date
        var opened: Date?
        var openedBy: String?

        var gift: Gift? { GiftCodec.decode(payload) }
    }

    struct Saved: Codable {
        var received: [Received] = []
        var sent: [Sent] = []

        init(received: [Received], sent: [Sent]) {
            self.received = received
            self.sent = sent
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            received = try c.decodeIfPresent([Received].self, forKey: .received) ?? []
            sent = try c.decodeIfPresent([Sent].self, forKey: .sent) ?? []
        }
    }

    /// Gifts kept; past this the oldest opened ones go first, then the oldest locked.
    static let keepReceived = 100
    /// At most one "a gift from…" notification this often (a flood of gifts is one buzz).
    static let notifyGap: TimeInterval = 60

    private(set) var received: [Received] = []
    private(set) var sent: [Sent] = []
    private(set) var here: LatLon?
    private(set) var access = LocationAccess.notAsked
    /// The gift that just opened (for the reveal).
    var justOpened: Received?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let radio: Radio
    @ObservationIgnored private let meshcore: MeshCoreLink?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var lastGiftNotice: Date?
    /// The grid cell each locked gift was last tried in: opening only depends on
    /// the cell, so a gift isn't tried again until the phone moves to another one.
    @ObservationIgnored private var triedCell: [UInt32: GiftCodec.Cell] = [:]

    init(radio: Radio, meshcore: MeshCoreLink? = nil, file: URL? = nil) {
        self.radio = radio
        self.meshcore = meshcore
        fileURL = file ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gifts.json")
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        access = LocationAccess(manager.authorizationStatus)
        load()
        radio.addListener { [weak self] in self?.handle($0) }
        meshcore?.addListener { [weak self] in self?.handleMeshCore($0) }
    }

    enum GiftError: LocalizedError {
        case tooBigForMeshCore(Int)
        var errorDescription: String? {
            switch self {
            case .tooBigForMeshCore(let n): return "Too long for MeshCore: \(n) of \(MeshCore.maxChannelData) bytes. Shorten the message or teaser."
            }
        }
    }

    var locked: [Received] { received.filter { $0.opened == nil } }

    // MARK: Leaving a gift

    /// Seals and records a gift; sends it over the mesh unless `to` is nil and
    /// `broadcastChannel` is nil (link only). Returns the gift.
    func leave(message: String, teaser: String, at spot: LatLon, precision: Gift.Precision, hintRadius: Int,
               to: NodeNum?, broadcastChannel: Int?, meshcoreChannel: Int? = nil) throws -> Sent {
        let id = UInt32.random(in: 1...UInt32.max)
        let gift = Gift(id: id, precision: precision,
                        hintCenter: hintRadius == 0 ? spot : GiftCodec.hint(for: spot, radius: hintRadius),
                        hintRadius: hintRadius, created: Date(),
                        teaser: teaser, sealed: try GiftCodec.seal(message, at: spot, id: id, precision: precision))
        let payload = GiftCodec.encode(gift)
        if let mc = meshcoreChannel {
            guard payload.count <= MeshCore.maxChannelData, meshcore?.sendData(payload, channel: mc) == true else {
                throw GiftError.tooBigForMeshCore(payload.count)
            }
        } else if let to {
            radio.link?.sendPrivate(payload, to: to, channel: radio.session.channel(toReach: to))
        } else if let ch = broadcastChannel {
            radio.link?.sendPrivate(payload, to: .broadcast, channel: ch)
        }
        let s = Sent(id: id, payload: payload, spot: spot, message: message, teaser: teaser, to: to?.id, sent: Date())
        sent.insert(s, at: 0)
        save()
        return s
    }

    func deleteSent(_ s: Sent) {
        sent.removeAll { $0.id == s.id }
        save()
    }

    // MARK: Receiving

    /// A gift from a link or QR code (no radio needed). Returns false if it isn't one.
    @discardableResult
    func importLink(_ text: String) -> Bool {
        guard let g = GiftCodec.gift(fromLink: text) else { return false }
        add(payload: GiftCodec.encode(g), id: g.id, from: nil, channel: nil, meshcoreChannel: nil, notify: false)
        return true
    }

    func deleteReceived(_ r: Received) {
        received.removeAll { $0.id == r.id }
        save()
    }

    private func handle(_ e: MeshSession.Event) {
        guard case .packet(let p) = e, p.portnum == .privateApp, let payload = p.payload,
              p.from != radio.session.myNode else { return }
        if let id = GiftCodec.receiptID(payload), let i = sent.firstIndex(where: { $0.id == id }), sent[i].opened == nil {
            sent[i].opened = Date()
            sent[i].openedBy = radio.session.label(for: p.from)
            save()
            notify(title: "Your gift was opened", body: "\(sent[i].openedBy ?? "Someone") found \"\(sent[i].teaser)\"")
            return
        }
        if let g = GiftCodec.decode(payload) {
            add(payload: payload, id: g.id, from: p.from, channel: p.channel, meshcoreChannel: nil, notify: true)
        }
    }

    /// Gifts and receipts arriving as MeshCore channel datagrams.
    private func handleMeshCore(_ e: MeshCoreSession.Event) {
        guard case .datagram(let ch, let dt, let payload, _) = e, dt == MeshCore.wildcatDataType else { return }
        if let id = GiftCodec.receiptID(payload), let i = sent.firstIndex(where: { $0.id == id }), sent[i].opened == nil {
            sent[i].opened = Date()
            sent[i].openedBy = "someone on MeshCore"
            save()
            notify(title: "Your gift was opened", body: "Someone on MeshCore found \"\(sent[i].teaser)\"")
            return
        }
        if let g = GiftCodec.decode(payload) {
            add(payload: payload, id: g.id, from: nil, channel: nil, meshcoreChannel: ch, notify: true)
        }
    }

    private func add(payload: Data, id: UInt32, from: NodeNum?, channel: Int?, meshcoreChannel: Int?, notify: Bool) {
        guard !received.contains(where: { $0.id == id }), !sent.contains(where: { $0.id == id }) else { return }
        let name = from.map { radio.session.label(for: $0) }
            ?? meshcoreChannel.map { "MeshCore · \(meshcore?.session.label(.channel($0)) ?? "channel \($0)")" }
        received.insert(Received(id: id, payload: payload, from: from?.id, fromName: name, channel: channel,
                                 meshcoreChannel: meshcoreChannel, received: Date()), at: 0)
        received = Self.capped(received)
        save()
        if notify, let g = GiftCodec.decode(payload),
           lastGiftNotice.map({ Date().timeIntervalSince($0) >= Self.notifyGap }) ?? true {
            lastGiftNotice = Date()
            self.notify(title: "A gift from \(name ?? "someone")", body: g.teaser.isEmpty ? "Go find it." : g.teaser)
        }
        if let here { tryOpen(at: here) }
    }

    // MARK: Opening

    /// Watches location while a gifts screen is open (and there's something locked).
    func startWatching() {
        watchers += 1
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { manager.stopUpdatingLocation() }
    }

    /// Newest first in, `keep` out: drops the oldest opened gifts first, then the oldest locked ones.
    static func capped(_ list: [Received], keep: Int = keepReceived) -> [Received] {
        var out = list
        while out.count > keep {
            out.remove(at: out.lastIndex { $0.opened != nil } ?? out.count - 1)
        }
        return out
    }

    func tryOpen(at p: LatLon) {
        for i in received.indices where received[i].opened == nil {
            guard let g = received[i].gift else { continue }
            let cell = GiftCodec.cell(p, g.precision)
            guard triedCell[g.id] != cell else { continue }
            triedCell[g.id] = cell
            guard let message = GiftCodec.open(g, at: p) else { continue }
            received[i].opened = Date()
            received[i].message = message
            justOpened = received[i]
            save()
            if let mc = received[i].meshcoreChannel, meshcore?.state.isReady == true {
                meshcore?.sendData(GiftCodec.openedReceipt(id: g.id), channel: mc)
            } else if let s = received[i].from, let n = NodeNum(id: s), radio.isReady {
                radio.link?.sendPrivate(GiftCodec.openedReceipt(id: g.id), to: n, channel: radio.session.channel(toReach: n))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 60 else { return }
        let p = LatLon(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        MainActor.assumeIsolated {
            here = p
            tryOpen(at: p)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = LocationAccess(manager.authorizationStatus)
        MainActor.assumeIsolated { access = s }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Persistence

    private func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        // An unreadable file is set aside (gifts.json.bad-…), never overwritten.
        guard let s = SaveFile.load(Saved.self, from: fileURL, decoder: d) else { return }
        received = Self.capped(s.received)
        sent = s.sent
    }

    /// Small (at most 100 gifts plus yours), so it's written right away.
    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        SaveFile.writeNow(Saved(received: received, sent: sent), to: fileURL, encoder: e)
    }
}
