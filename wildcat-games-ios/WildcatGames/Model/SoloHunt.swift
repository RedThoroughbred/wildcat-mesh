import CoreLocation
import Foundation
import Observation
import WildcatRadioCore

/// Hunt any node by its signal, no Den needed: your node's readings of it
/// (including traffic it relays), traceroute pings for fresh readings, and
/// the direction your own readings point.
@MainActor
@Observable
final class SoloHunt: NSObject, CLLocationManagerDelegate {
    private(set) var fox: NodeNum?
    private(set) var tracker: FoxTracker?
    private(set) var started: Date?
    private(set) var finished: Date?
    private(set) var walked: Double = 0
    private(set) var lastPing: Date?
    private(set) var pings = 0
    private(set) var here: LatLon?
    private(set) var access = LocationAccess.notAsked
    @ObservationIgnored private var located: [(LatLon, Double)] = []
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let radio: Radio

    static let pingCooldown: TimeInterval = 30

    init(radio: Radio) {
        self.radio = radio
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        access = LocationAccess(manager.authorizationStatus)
        radio.addListener { [weak self] in self?.handle($0) }
    }

    var isActive: Bool { fox != nil && finished == nil }

    func start(_ node: NodeNum) {
        fox = node
        var t = FoxTracker(fox: node)
        t.acceptRelayed = true
        tracker = t
        started = Date()
        finished = nil
        walked = 0
        pings = 0
        located = []
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func finish() {
        finished = Date()
        manager.stopUpdatingLocation()
    }

    func reset() {
        fox = nil
        tracker = nil
        started = nil
        finished = nil
        manager.stopUpdatingLocation()
    }

    var canPing: Bool {
        isActive && radio.isReady && radio.source == .bluetooth
            && (lastPing.map { Date().timeIntervalSince($0) >= Self.pingCooldown } ?? true)
    }

    func ping() {
        guard canPing, let fox else { return }
        radio.sendTraceroute(to: fox, channel: radio.session.channel(toReach: fox))
        lastPing = Date()
        pings += 1
    }

    var signalBearing: Double? { Geo.signalBearing(located) }

    /// Readings taken with a GPS fix (what `signalBearing` works from).
    var fixes: Int { located.count }

    private func handle(_ e: MeshSession.Event) {
        guard isActive, case .packet(let p) = e, let s = tracker?.ingest(p, at: Date()) else { return }
        if let here {
            located.append((here, s.score))
            if located.count > 200 { located.removeFirst(located.count - 200) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = LocationAccess(manager.authorizationStatus)
        MainActor.assumeIsolated { access = s }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 50 else { return }
        let p = LatLon(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        MainActor.assumeIsolated {
            if let prev = here, isActive {
                let step = Geo.distance(prev, p)
                if step < 100 { walked += step }
            }
            here = p
        }
    }
}
