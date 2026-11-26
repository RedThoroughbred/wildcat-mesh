import Foundation
import Observation
import WildcatRadioCore

/// Fox-hunt a real MeshCore repeater by its signal. Readings come from every
/// packet the Bag hears that the repeater itself transmitted: its adverts, the
/// traffic it relays, and its answers to our pings (status requests).
@MainActor
@Observable
final class MeshCoreHunt {
    struct Reading: Equatable {
        var at: Date
        var rssi: Int
        var snr: Double
    }

    private(set) var target: MeshCore.Contact?
    private(set) var readings: [Reading] = []
    private(set) var best: Reading?
    private(set) var trend: FoxTracker.Trend = .none
    private(set) var started: Date?
    private(set) var found: Date?
    private(set) var lastPing: Date?
    static let pingEvery: TimeInterval = 20

    private let link: MeshCoreLink

    init(link: MeshCoreLink) {
        self.link = link
        link.addListener { [weak self] in self?.handle($0) }
    }

    var last: Reading? { readings.last }
    var isActive: Bool { target != nil && found == nil }
    var score: Double { last.flatMap { FoxReferee.score(rssi: Double($0.rssi), snr: $0.snr) } ?? 0 }
    var canPing: Bool { lastPing.map { Date().timeIntervalSince($0) >= Self.pingEvery } ?? true }

    func start(_ c: MeshCore.Contact) {
        target = c
        readings = []
        best = nil
        trend = .none
        started = Date()
        found = nil
        ping()
    }

    func stop() { target = nil; found = nil }

    func markFound() { found = Date() }

    /// Asks the repeater for its status: its answer is a fresh reading.
    func ping() {
        guard let c = target, canPing else { return }
        lastPing = Date()
        link.requestStatus(c)
    }

    private func handle(_ e: MeshCoreSession.Event) {
        guard isActive, let key = target?.publicKey, case .heard(let snr, let rssi, let raw) = e,
              let p = MeshCorePacket(raw), p.transmitted(by: key) else { return }
        let r = Reading(at: Date(), rssi: rssi, snr: snr)
        if let prev = readings.last {
            let d = r.rssi - prev.rssi
            trend = d >= 3 ? .warmer : d <= -3 ? .colder : .steady
        }
        readings.append(r)
        if readings.count > 300 { readings.removeFirst(readings.count - 300) }
        if best.map({ r.rssi > $0.rssi }) ?? true { best = r }
    }
}
