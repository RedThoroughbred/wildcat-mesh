import CoreLocation
import Observation
import WildcatRadioCore

/// The phone's position for Hunt (Small Play 2): where the hider put each piece down, and
/// the GPS guide and walked distance for hunters. Runs only while a screen asks for it
/// (`begin`/`end`), and only asks for permission when `begin(asking: true)`.
@MainActor
@Observable
final class GameLocation: NSObject, CLLocationManagerDelegate {
    /// The latest fix (any accuracy; callers check).
    private(set) var fix: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Told about every new fix.
    @ObservationIgnored var onFix: ((CLLocation) -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        authorization = manager.authorizationStatus
    }

    var isAllowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    func begin(asking: Bool) {
        users += 1
        if asking, authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        if isAllowed || asking { manager.startUpdatingLocation() }
    }

    func end() {
        users = max(0, users - 1)
        if users == 0, waiting.isEmpty { manager.stopUpdatingLocation() }
    }

    /// A fix at most `maxAge` old and within `accuracy` metres, waiting up to `timeout` for one.
    func current(maxAge: TimeInterval = 20, accuracy: Double = 50, timeout: Duration = .seconds(8)) async -> CLLocation? {
        if let f = fix, -f.timestamp.timeIntervalSinceNow <= maxAge, f.horizontalAccuracy >= 0, f.horizontalAccuracy <= accuracy { return f }
        guard isAllowed else { return nil }
        manager.startUpdatingLocation()
        let got: CLLocation? = await withCheckedContinuation { c in
            waiting.append(c)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeWaiting(nil)
            }
        }
        if users == 0, waiting.isEmpty { manager.stopUpdatingLocation() }
        return got.flatMap { $0.horizontalAccuracy <= accuracy ? $0 : nil }
    }

    private func resumeWaiting(_ l: CLLocation?) {
        let w = waiting
        waiting = []
        w.forEach { $0.resume(returning: l) }
    }

    static func coordinate(_ l: CLLocation) -> Coordinate {
        Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        MainActor.assumeIsolated {
            fix = l
            onFix?(l)
            if l.horizontalAccuracy <= 50 { resumeWaiting(l) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = s
            if users > 0 || !waiting.isEmpty, isAllowed { self.manager.startUpdatingLocation() }
            if s == .denied || s == .restricted { resumeWaiting(nil) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
