#if canImport(CoreBluetooth)
import CoreBluetooth

/// Where the phone's Bluetooth stands for one link, so the app can say
/// "Bluetooth is off" or "Bluetooth isn't allowed" instead of scanning forever.
public enum BluetoothStatus: Equatable, Sendable {
    /// Not used yet: no Bluetooth manager, so no permission prompt either.
    case notStarted
    /// Started, waiting for iOS to report the state.
    case starting
    case on
    case off
    /// Denied or restricted in Settings.
    case unauthorized
    case unsupported

    init(_ s: CBManagerState) {
        switch s {
        case .poweredOn: self = .on
        case .poweredOff: self = .off
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        default: self = .starting
        }
    }

    /// True when the user said no in Settings (readable without prompting).
    public static var isDenied: Bool {
        CBManager.authorization == .denied || CBManager.authorization == .restricted
    }
}
#endif
