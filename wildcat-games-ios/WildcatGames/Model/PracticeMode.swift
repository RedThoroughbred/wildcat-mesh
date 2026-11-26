import Foundation
import WildcatRadioCore

/// Practice on both networks at once: a pretend Meshtastic mesh (`PracticeMesh`) and a
/// pretend MeshCore node (`MeshCoreLink.startDemo`). A real radio is never replaced.
@MainActor
enum PracticeMode {
    /// Where the phone last was, when the app may already use location (set by the app;
    /// never asks for permission). The practice meshes are placed around it.
    static var location: () -> LatLon? = { nil }

    /// Starts pretend radios on every network that has no radio connected.
    static func start(_ radio: Radio, _ meshcore: MeshCoreLink) {
        if !radio.isReady { radio.startPractice() }
        if !meshcore.state.isReady { startMeshCore(meshcore) }
    }

    /// The practice MeshCore node, its made-up mesh around the phone (or a public park
    /// when the phone's position isn't known). Live positions (`walked(to:)`) then move
    /// the player, so the practice fox gets warmer as they walk.
    static func startMeshCore(_ meshcore: MeshCoreLink) {
        meshcore.startDemo(center: location().map(coordinate))
    }

    /// A new position from the phone: while practising, it's where the player is.
    static func walked(to p: LatLon, _ meshcore: MeshCoreLink) {
        if meshcore.isDemo { meshcore.setPracticeLocation(coordinate(p)) }
    }

    static func coordinate(_ p: LatLon) -> Coordinate { Coordinate(latitude: p.lat, longitude: p.lon) }

    /// Ends practice on both networks (real radios stay connected).
    static func end(_ radio: Radio, _ meshcore: MeshCoreLink) {
        if radio.source == .practice { radio.stopPractice() }
        if meshcore.isDemo { meshcore.disconnect() }
    }

    /// Either network is in practice.
    static func isOn(_ radio: Radio, _ meshcore: MeshCoreLink) -> Bool {
        radio.source == .practice || meshcore.isDemo
    }
}
