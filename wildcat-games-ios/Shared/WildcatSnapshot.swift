import Foundation

/// What the Home Screen widgets show: a small summary the app writes into the
/// App Group whenever something changes. Shared by the app and the widget extension.
struct WildcatSnapshot: Codable, Equatable {
    static let appGroup = "group.com.thebench.wildcatgames"
    static let widgetKind = "WildcatMesh"

    struct Node: Codable, Equatable {
        var name: String
        var badge: String
        var connected: Bool
        var heard: Int
        var lastHeard: Date?
        var batteryVolts: Double?
    }

    struct Line: Codable, Equatable, Identifiable {
        var id: String
        /// "MT" or "MC"
        var network: String
        var from: String
        var text: String
        var at: Date
    }

    var updated: Date
    var meshtastic: Node?
    var meshcore: Node?
    var bridgeOn: Bool
    var bridged: Int
    var bridgeChannels: String?
    var unreadMeshtastic: Int
    var unreadMeshCore: Int
    var recent: [Line]

    static let placeholder = WildcatSnapshot(
        updated: Date(),
        meshtastic: Node(name: "Trail Node", badge: "TN", connected: true, heard: 14, lastHeard: Date(), batteryVolts: nil),
        meshcore: Node(name: "Pack Node", badge: "PN", connected: true, heard: 5, lastHeard: Date(), batteryVolts: 3.78),
        bridgeOn: true, bridged: 12, bridgeChannels: "Camp ↔ WGBRIDGE",
        unreadMeshtastic: 2, unreadMeshCore: 1,
        recent: [Line(id: "1", network: "MC", from: "MAYA", text: "Howdy from the repeater!", at: Date()),
                 Line(id: "2", network: "MT", from: "STAY", text: "Heading to the park", at: Date().addingTimeInterval(-300))])

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func load() -> WildcatSnapshot? {
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WildcatSnapshot.self, from: d)
    }

    func save() {
        guard let url = Self.url, let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
