import CoreLocation
import Foundation
import Observation
import WildcatRadioCore

/// Runs a coverage walk: the phone's GPS, a beacon from the player's node
/// every `beaconInterval`, the Den's measurements of that node, and any
/// packet the node hears straight from the Den.
@MainActor
@Observable
final class WalkRecorder: NSObject, CLLocationManagerDelegate {
    private(set) var walk: CoverageWalk?
    private(set) var walks: [CoverageWalk] = WalkStore.load()
    private(set) var lastFix: WalkPairing.Fix?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var problem: String?
    private(set) var lastBeacon: Date?
    /// Five minutes: Meshtastic's smart-position floor while moving. LoRa airtime is
    /// shared, so a walk never beacons faster (Meshtastic LLC's request, 2026-11-25).
    var beaconInterval: TimeInterval = 300

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var pairing = WalkPairing()
    @ObservationIgnored private var beaconTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let radio: Radio
    @ObservationIgnored private let den: DenStore
    @ObservationIgnored private var channel = 0

    init(radio: Radio, den: DenStore) {
        self.radio = radio
        self.den = den
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        authorization = manager.authorizationStatus
        radio.addListener { [weak self] event in self?.handle(event) }
    }

    var isWalking: Bool { walk != nil }

    // MARK: Control

    func requestPermission() { manager.requestWhenInUseAuthorization() }

    /// Starts a walk; returns why it can't when something is missing.
    @discardableResult
    func start(channel: Int) -> String? {
        guard radio.source == .bluetooth, radio.isReady, let me = radio.session.myNode else {
            return "Needs a Meshtastic node (connect it on the Meshtastic tab). It sends the beacons the Den listens for."
        }
        guard let denID = den.myID, den.isReachable else { return "The Den isn't reachable. Check Tailscale." }
        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways: break
        case .notDetermined:
            requestPermission()
            return "Each reading is pinned to where you stood, so a walk uses your location. Answer iOS's question, then start again."
        default:
            return "Location is off for Wildcat, so walks can't pin readings to where you stood."
        }
        // Foreground only for 1.0: the walk pauses when the phone locks.
        manager.allowsBackgroundLocationUpdates = false
        manager.activityType = .fitness
        self.channel = channel
        pairing = WalkPairing()
        walk = CoverageWalk(name: "Walk " + Date().formatted(date: .abbreviated, time: .shortened),
                            started: Date(), node: me.id, den: denID, beaconInterval: beaconInterval)
        problem = nil
        manager.startUpdatingLocation()
        beaconTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))   // a first fix
            while !Task.isCancelled {
                self?.beacon()
                try? await Task.sleep(for: .seconds(self?.beaconInterval ?? 300))
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDen()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        return nil
    }

    func stop() {
        beaconTask?.cancel()
        pollTask?.cancel()
        manager.stopUpdatingLocation()
        guard var w = walk else { return }
        append(pairing.expire(now: .distantFuture))
        w = walk ?? w
        w.ended = Date()
        if !w.points.isEmpty { WalkStore.save(w) }
        walk = nil
        walks = WalkStore.load()
    }

    func delete(_ w: CoverageWalk) {
        WalkStore.delete(w)
        walks = WalkStore.load()
    }

    // MARK: Work

    private func beacon() {
        guard radio.isReady else {
            problem = "Your node disconnected. Beacons paused."
            return
        }
        let now = Date()
        guard pairing.beaconSent(at: now) else {
            problem = "Waiting for a good GPS fix…"
            return
        }
        radio.sendPositionBeacon(channel: channel)
        lastBeacon = now
        problem = nil
        append(pairing.expire(now: now))
    }

    private func pollDen() async {
        guard let w = walk, let client = den.client else { return }
        struct Signal: Decodable { var samples: [[Double?]]? }
        guard let s: Signal = try? await client.get("signal/\(w.node)?minutes=5") else { return }
        for row in s.samples ?? [] where row.count >= 3 {
            guard let ts = row[0] else { continue }
            let hops = row.count > 3 ? row[3].map { Int($0) } : nil
            if let p = pairing.denHeard(at: Date(timeIntervalSince1970: ts), snr: row[1],
                                        rssi: row[2].map { Int($0) }, hops: hops) {
                append([p])
            }
        }
        append(pairing.expire(now: Date()))
    }

    private func handle(_ event: MeshSession.Event) {
        guard let w = walk, case .packet(let p) = event, p.from.id == w.den, p.isDirectRF else { return }
        if let point = pairing.nodeHeardDen(at: Date(), snr: p.rxSNR.map(Double.init), rssi: p.rxRSSI) {
            append([point])
        }
    }

    private func append(_ points: [CoveragePoint]) {
        guard !points.isEmpty, walk != nil else { return }
        walk?.points.append(contentsOf: points)
        if let walk, walk.points.count % 10 == 0 { WalkStore.save(walk) }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            WalkPairing.Fix(time: $0.timestamp, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                            accuracy: $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil)
        }
        MainActor.assumeIsolated {
            for f in fixes { pairing.add(f) }
            lastFix = fixes.last
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { authorization = status }
    }
}
