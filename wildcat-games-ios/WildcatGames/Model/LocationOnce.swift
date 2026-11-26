import CoreLocation

/// One GPS fix, for setting a node's fixed position from the phone.
///
/// The wait for a fix only starts once location is allowed: the permission prompt can
/// stay up as long as the person needs (a timer running under it used to fail the
/// request before they'd answered). Denied answers at once with nil.
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeout: Duration = .seconds(15)
    private var timing = false

    func get(timeout: Duration = .seconds(15)) async -> CLLocation? {
        self.timeout = timeout
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        return await withCheckedContinuation { c in
            continuation = c
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()   // carries on in didChangeAuthorization
            case .authorizedWhenInUse, .authorizedAlways: start()
            default: finish(nil)
            }
        }
    }

    private func start() {
        manager.startUpdatingLocation()
        guard !timing else { return }
        timing = true
        Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            self?.finish(nil)
        }
    }

    private func finish(_ l: CLLocation?) {
        manager.stopUpdatingLocation()
        continuation?.resume(returning: l)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            switch status {
            case .notDetermined: break   // still asking
            case .authorizedWhenInUse, .authorizedAlways: start()
            default: finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 50 else { return }
        MainActor.assumeIsolated { finish(l) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (no fix yet) errors keep waiting; the timeout ends it.
    }
}
