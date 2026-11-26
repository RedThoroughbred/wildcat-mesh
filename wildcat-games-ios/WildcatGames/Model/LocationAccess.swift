import CoreLocation

/// Where the phone's location permission stands, in the app's terms.
enum LocationAccess: Equatable {
    case notAsked, allowed, denied, restricted

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notAsked
        case .authorizedWhenInUse, .authorizedAlways: self = .allowed
        case .restricted: self = .restricted
        default: self = .denied
        }
    }

    /// What a screen waiting for a fix should say instead, or nil when location
    /// is allowed (then it's really waiting for GPS).
    var problem: String? {
        switch self {
        case .allowed: return nil
        case .notAsked: return "This uses your location."
        case .denied: return "Location is off for Wildcat, so this part isn't available."
        case .restricted: return "Location is restricted on this phone (Screen Time or a device profile), so this part isn't available."
        }
    }
}
