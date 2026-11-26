import Foundation
import WildcatRadioCore

/// Everything a hunter needs to join a phone-refereed hunt, in one QR code or
/// link: the hunt code, the hunt channel (key included), the fox's node and
/// the time limit, if there is one.
///
///     wildcat://hunt/<base64url JSON>
struct HuntInvite: Codable, Equatable, Identifiable {
    /// Hunt code, e.g. "FOX7".
    var code: String
    /// The hunt channel's ChannelSettings, raw (name + key).
    var channel: Data
    /// The fox's node number, so hunters don't have to pick it.
    var fox: UInt32
    /// The host's node number (who referees).
    var host: UInt32
    /// The hunt's time limit in minutes (nil: none). Older apps ignore it; older links don't have it.
    var limitMinutes: Int?

    static let prefix = "wildcat://hunt/"

    var id: String { "\(code)-\(fox)-\(host)" }

    var link: String {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(code: String, channel: Data, fox: NodeNum, host: NodeNum, limitMinutes: Int? = nil) {
        self.code = code
        self.channel = channel
        self.fox = fox.raw
        self.host = host.raw
        self.limitMinutes = limitMinutes
    }

    init?(link: String) {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix(Self.prefix) else { return nil }
        var b64 = String(s.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let v = try? JSONDecoder().decode(HuntInvite.self, from: data),
              !v.code.isEmpty, !v.channel.isEmpty else { return nil }
        self = v
    }

    var channelName: String { ChannelSettings(raw: channel).name }
    var foxNode: NodeNum { NodeNum(fox) }
    /// The time limit in seconds; nil for none (or a nonsense value from a hand-made link).
    var timeLimit: TimeInterval? {
        guard let limitMinutes, (1...24 * 60).contains(limitMinutes) else { return nil }
        return TimeInterval(limitMinutes) * 60
    }
}
