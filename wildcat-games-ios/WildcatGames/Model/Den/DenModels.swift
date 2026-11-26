import Foundation

// The Den Observatory's /v2 API (wildcat-mesh-v2/wildcat/observatory/web.py).
// Every field is optional: the Den adds fields over time and omits unknowns.

enum Den {
    struct Health: Decodable, Equatable {
        var ok: Bool?
        var bus: Bool?
        var meshd: String?
        var my_id: String?
        var nodes: Int?
        var packets_seen: Int?
    }

    struct About: Decodable, Equatable {
        struct Counts: Decodable, Equatable {
            var heard_1h: Int?
            var internet_only: Int?
            var nodes: Int?
            var rf: Int?
        }
        struct Me: Decodable, Equatable {
            var id: String?
            var name: String?
        }
        var name: String?
        var bobcat: Bool?
        var counts: Counts?
        var den: Me?
    }

    struct Services: Decodable, Equatable {
        struct Meshd: Decodable, Equatable {
            var radio: String?
            var state: String?
            var rxCount: Int?
            var txSent: Int?
            var txQueued: Int?
        }
        struct Unit: Decodable, Equatable {
            var ActiveState: String?
            var SubState: String?
        }
        var meshd: Meshd?
        var units: [String: Unit]?
        var uptime: Double?
        var packets_seen: Int?
    }

    struct Position: Decodable, Equatable {
        var lat: Double?
        var lon: Double?
        var alt: Double?
    }

    /// One row of /api/nodes (the live roster).
    struct Node: Decodable, Equatable, Identifiable {
        var id: String
        var short_name: String?
        var long_name: String?
        var hw: String?
        var role: String?
        var position: Position?
        var hops_away: Int?
        var snr: Double?
        var battery: Int?
        var voltage: Double?
        var last_heard: Double?
        var last_rf: Double?
        var transport: String?
        var rf_heard: Bool?
        var rf_count: Int?
        var mqtt_count: Int?

        var name: String { short_name?.isEmpty == false ? short_name! : String(id.suffix(4)) }
        var lastHeard: Date? { last_heard.map { Date(timeIntervalSince1970: $0) } }
        /// Heard over the air by the Den (not only via the internet).
        var isRF: Bool { rf_heard == true || transport == "rf" }
        var hasPosition: Bool {
            guard let p = position, let la = p.lat, let lo = p.lon else { return false }
            return la != 0 || lo != 0
        }
    }

    struct Nodes: Decodable {
        var my_id: String?
        var nodes: [Node]
    }

    /// /api/signal: how the Den's radio hears each node.
    struct Signal: Decodable {
        struct Row: Decodable, Equatable, Identifiable {
            var id: String
            var s: String?
            var l: String?
            var snr: Double?
            var rssi: Int?
            var avg: Double?
            /// "strong", "ok" or "weak".
            var cls: String?
            var n: Int?
            var age: Int?
            var hops: Int?
            var spark: [Double]?
        }
        struct Summary: Decodable, Equatable {
            struct Class: Decodable, Equatable {
                var strong: Int?
                var ok: Int?
                var weak: Int?
            }
            var avg_snr: Double?
            var rf: Int?
            var internet_only: Int?
            var measured: Int?
            var classes: Class?
        }
        var nodes: [Row]
        var summary: Summary?
    }

    struct ChatMessage: Decodable, Equatable, Identifiable {
        var broadcast: Bool?
        var channel: Int?
        var mine: Bool?
        var rssi: Int?
        var snr: Double?
        var sender_id: String?
        var short_name: String?
        var text: String?
        var to: String?
        var ts: Double?

        var id: String { "\(ts ?? 0)-\(sender_id ?? "")-\(text?.hashValue ?? 0)" }
        var date: Date { Date(timeIntervalSince1970: ts ?? 0) }
    }

    struct Chat: Decodable {
        var messages: [ChatMessage]
        var my_id: String?
    }

    struct Channels: Decodable {
        struct Channel: Decodable, Equatable, Identifiable {
            var i: Int
            var n: String
            /// "P" primary, "S" secondary.
            var r: String?
            var id: Int { i }
        }
        var c: [Channel]
    }

    struct SOS: Decodable, Equatable {
        var active: Bool?
        var sent: Int?
    }

    /// /api/coverage: where positioned nodes were when the Den heard them.
    struct Coverage: Decodable {
        struct Point: Decodable, Equatable {
            var lat: Double?
            var lon: Double?
            var snr: Double?
            var rssi: Double?
            var hops: Int?
            var node_id: String?
            var ts: Double?
        }
        var points: [Point]
    }

    struct Auth: Decodable {
        var required: Bool?
        var authorized: Bool?
    }

    struct SendResult: Decodable {
        var ok: Bool?
        var error: String?
    }
}
