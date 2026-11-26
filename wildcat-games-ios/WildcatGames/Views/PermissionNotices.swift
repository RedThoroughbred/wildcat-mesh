import AVFoundation
import CoreBluetooth
import CoreLocation
import SwiftUI

/// Wildcat's own page in the Settings app, where its permissions live.
@MainActor
func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

/// What each permission was when the app launched, so a screen can tell a choice made just
/// now from one made before (App Review guideline 5.1.1(iv)):
/// - Someone who taps Don't Allow during this run is not pointed at Settings: they just chose.
/// - On a later run, a feature that can't work without the permission may say so and offer a
///   quiet link to Settings, never pressure or a prompt to reconsider.
@MainActor
enum PermissionHistory {
    private(set) static var locationAtLaunch: CLAuthorizationStatus = .notDetermined
    private(set) static var bluetoothAtLaunch: CBManagerAuthorization = .notDetermined
    private(set) static var cameraAtLaunch: AVAuthorizationStatus = .notDetermined
    private static var recorded = false

    /// Called once at launch, before any screen asks for anything. Reading these never prompts.
    static func record() {
        guard !recorded else { return }
        recorded = true
        locationAtLaunch = CLLocationManager().authorizationStatus
        bluetoothAtLaunch = CBManager.authorization
        cameraAtLaunch = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// The person answered the location question during this run.
    static var locationDecidedThisRun: Bool { locationAtLaunch == .notDetermined }
    static var bluetoothDecidedThisRun: Bool { bluetoothAtLaunch == .notDetermined }
    static var cameraDecidedThisRun: Bool { cameraAtLaunch == .notDetermined }
}

/// A small, quiet link to Wildcat's page in Settings: plain text, not a call to action.
struct SettingsLink: View {
    var body: some View {
        Button { openAppSettings() } label: {
            Text("Settings").font(Theme.Fonts.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .accessibilityHint("Opens Wildcat's page in the Settings app")
    }
}

/// Location for a feature that uses it.
/// - Not asked yet: what the feature uses location for, and Continue, which shows the system
///   question (only offered where the screen passes `ask`).
/// - Turned off: a neutral note that this part isn't available, plus a quiet Settings link only
///   if the choice wasn't made during this run.
/// Shows nothing once location is allowed.
struct LocationNotice: View {
    let access: LocationAccess
    /// What this screen loses without location, when it still works: the end of "Location is
    /// off for Wildcat, so …". Nil for a part that can't work at all.
    var without: String? = nil
    /// Shows the system question (only offered before the first answer).
    var ask: (() -> Void)?

    var body: some View {
        switch access {
        case .allowed:
            EmptyView()
        case .notAsked:
            if let ask {
                VStack(alignment: .leading, spacing: 8) {
                    Notice(text: "This uses your location to work out where you are. iOS asks next.",
                           symbol: "location")
                    Button { ask() } label: { Text("Continue") }
                        .buttonStyle(.field(.secondary, .regular))
                }
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Notice(text: "Location is off for Wildcat, so \(without ?? "this part isn't available. Everything else works without it.")",
                       symbol: "location.slash")
                if !PermissionHistory.locationDecidedThisRun {
                    HStack(spacing: 4) {
                        Text("You can change this any time in").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                        SettingsLink()
                    }
                    .padding(.leading, 2)
                }
            }
        case .restricted:
            Notice(text: "Location is restricted on this phone (Screen Time or a device profile), so \(without ?? "this part isn't available.")",
                   symbol: "location.slash")
        }
    }
}

/// Bluetooth is off, or Wildcat isn't allowed to use it. Neutral: what can't happen and what
/// still works; a quiet Settings link only for a choice made on an earlier run.
struct BluetoothNotice: View {
    /// True when Bluetooth itself is off (Control Center), false when Wildcat isn't allowed.
    let allowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Notice(text: allowed
                   ? "Bluetooth is off on this iPhone, so Wildcat can't reach your node. Practice mode works without it."
                   : "Bluetooth is off for Wildcat, so it can't reach your node. Practice mode works without it.",
                   symbol: "antenna.radiowaves.left.and.right.slash")
            if !allowed && !PermissionHistory.bluetoothDecidedThisRun {
                HStack(spacing: 4) {
                    Text("You can change this any time in").font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    SettingsLink()
                }
                .padding(.leading, 2)
            }
        }
    }
}
