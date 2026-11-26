import CoreLocation
import Observation

/// The phone's compass heading, so the Den's bearing ("BRG 045") can point
/// the way. Heading needs no location permission.
@MainActor
@Observable
final class Heading: NSObject, CLLocationManagerDelegate {
    private(set) var degrees: Double?
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
    }

    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.startUpdatingHeading()
    }

    func stop() { manager.stopUpdatingHeading() }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        MainActor.assumeIsolated { degrees = value }
    }
}
