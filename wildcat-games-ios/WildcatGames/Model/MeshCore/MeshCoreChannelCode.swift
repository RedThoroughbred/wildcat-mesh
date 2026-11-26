import Foundation
import WildcatRadioCore

/// A MeshCore channel's key as it's shared: the official link
/// (`meshcore://channel/add?name=…&secret=…`), 32 hex digits (typed with spaces,
/// or Wildcat's older QR), or any link carrying `secret=` (and maybe `name=`).
/// The official link and hashtag keys come from the core (`MeshCore.ChannelLink`,
/// `MeshCore.hashtagKey`, `MeshCore.hashtagName`); this adds the app's leniency.
struct MeshCoreChannelCode: Equatable {
    var name: String?
    var key: Data

    /// The channel's key on the air is 16 bytes.
    static let keyBytes = 16
    /// The firmware keeps 32 bytes for a channel name, the last one a terminator.
    static let maxNameBytes = 31

    init(name: String?, key: Data) {
        self.name = name
        self.key = key
    }

    /// 16 bytes from exactly 32 hex digits, ignoring anything else typed in
    /// between (spaces, dashes). ASCII only: fullwidth digits aren't hex here.
    static func key(_ text: String) -> Data? {
        let hex = text.lowercased().filter { $0.isASCII && $0.isHexDigit }
        guard hex.count == 32 else { return nil }
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(byte)
            i = j
        }
        return d
    }

    /// A scanned or pasted code: the official link (read by the core), the bare key,
    /// or any other link with the key in `secret` (and maybe `name`), like Wildcat's older QR codes.
    init?(scanned: String) {
        let s = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        if let official = MeshCore.ChannelLink(url: s) {
            key = official.secret
            name = official.name.isEmpty ? nil : official.name
            return
        }
        if s.count == 32, let k = Self.key(s) {
            key = k
            return
        }
        guard s.contains("://"), let items = Self.queryItems(s),
              let secret = items.first(where: { $0.name.lowercased() == "secret" })?.value,
              secret.count == 32, let k = Self.key(secret) else { return nil }
        key = k
        name = items.first(where: { $0.name.lowercased() == "name" })?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Query items with `+` read as a space (the official contact example encodes
    /// "Example+Contact"); a real plus arrives as %2B.
    private static func queryItems(_ s: String) -> [URLQueryItem]? {
        guard let c = URLComponents(string: s), let raw = c.percentEncodedQueryItems else { return nil }
        return raw.map { item in
            URLQueryItem(name: item.name,
                         value: item.value.map { ($0.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding ?? $0) })
        }
    }

    // MARK: Official share link

    /// The MeshCore app's channel link, also what its QR codes hold:
    /// `meshcore://channel/add?name=<url-encoded>&secret=<32 hex>` (the core's `MeshCore.ChannelLink`).
    var link: String { MeshCore.ChannelLink(name: name ?? "", secret: key).url }

    // MARK: Hashtag channels

    /// A hashtag channel's key comes from its name: the first 16 bytes of SHA-256 of the
    /// name including the "#", as typed (the core's `MeshCore.hashtagKey`). Empty for a
    /// name that isn't "#" plus something.
    static func hashtagKey(_ name: String) -> Data { MeshCore.hashtagKey(name) ?? Data() }

    /// "#hike" from "hike", "#hike" or " #hike " (tidied by the core's `MeshCore.hashtagName`);
    /// nil when there's nothing after the "#" or it has spaces (Wildcat keeps hashtags one word).
    /// Cut to fit the node's 31 bytes.
    static func hashtagName(_ text: String) -> String? {
        guard let t = MeshCore.hashtagName(text), !t.contains(where: \.isWhitespace) else { return nil }
        return MeshCoreNodeLimits.clamp(t, maxBytes: maxNameBytes)
    }

    /// A hashtag channel: its name starts with "#" and its key is the one the name derives.
    static func isHashtag(name: String, key: Data) -> Bool {
        name.hasPrefix("#") && name.count > 1 && hashtagKey(name) == key
    }

    /// The public channel's well-known key (companion_protocol.md, "Public Channel").
    static let publicKey = key("8b3387e9c5cdea6ac9e5edbaa115cd72") ?? Data()
}
