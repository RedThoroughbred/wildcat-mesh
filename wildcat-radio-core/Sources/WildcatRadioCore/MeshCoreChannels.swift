import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// MeshCore channel keys and share links, as the official MeshCore app uses them.
extension MeshCore {
    /// The key of a hashtag channel: the first 16 bytes of SHA-256 of its name,
    /// '#' included, as UTF-8 ("#test" -> 9cd8fcf22a47333b591d96a2b848b73f).
    /// Source: meshcore-dev/MeshCore docs/companion_protocol.md, "Channel Types"
    /// https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md#channel-types
    /// The name is hashed exactly as given: the doc says nothing about case, so
    /// "#Test" and "#test" are different channels (normalise with `hashtagName`).
    /// Nil for a name that isn't '#' plus something.
    public static func hashtagKey(_ name: String) -> Data? {
        guard name.hasPrefix("#"), name.count > 1 else { return nil }
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: Data(name.utf8)).prefix(16))
        #else
        return nil
        #endif
    }

    /// A typed hashtag channel name made tidy: spaces trimmed, one leading '#'.
    /// Case is left alone (see `hashtagKey`). Nil when nothing is left.
    public static func hashtagName(_ typed: String) -> String? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : "#" + s
    }

    /// The official app's "Add Channel" link (and QR code):
    /// `meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72`,
    /// the secret as 32 hex digits, plus an optional `region_scope` (app v1.47.0+).
    /// Source: meshcore-dev/MeshCore docs/qr_codes.md
    /// https://github.com/meshcore-dev/MeshCore/blob/main/docs/qr_codes.md
    public struct ChannelLink: Equatable, Sendable {
        public var name: String
        /// 16 bytes.
        public var secret: Data
        public var regionScope: String?

        public init(name: String, secret: Data, regionScope: String? = nil) {
            self.name = name
            self.secret = secret
            self.regionScope = regionScope
        }

        /// The link to share (or put in a QR code).
        public var url: String {
            var s = "meshcore://channel/add?name=" + Self.encode(name) + "&secret=" + secret.prefix(16).map { String(format: "%02x", $0) }.joined()
            if let regionScope, !regionScope.isEmpty { s += "&region_scope=" + Self.encode(regionScope) }
            return s
        }

        /// Reads a scanned or pasted link. Nil for anything else, or a secret that isn't 32 hex digits.
        public init?(url text: String) {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = "meshcore://channel/add?"
            guard s.count <= 2048, s.lowercased().hasPrefix(head) else { return nil }
            var items: [String: String] = [:]
            for pair in s.dropFirst(head.count).split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let k = kv.first.flatMap({ Self.decode(String($0)) })?.lowercased() else { continue }
                if items[k] == nil { items[k] = kv.count > 1 ? Self.decode(String(kv[1])) : "" }
            }
            guard let hex = items["secret"], let key = Self.key(hex) else { return nil }
            name = items["name"] ?? ""
            secret = key
            regionScope = items["region_scope"].flatMap { $0.isEmpty ? nil : $0 }
        }

        /// 16 bytes from exactly 32 hex digits.
        static func key(_ hex: String) -> Data? {
            let b = Array(hex.utf8)
            guard b.count == 32 else { return nil }
            var d = Data()
            for i in stride(from: 0, to: 32, by: 2) {
                guard let v = UInt8(String(decoding: b[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
                d.append(v)
            }
            return d
        }

        /// Percent-encoding for a query value: only unreserved characters stay as they are.
        static func encode(_ s: String) -> String {
            let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
        }

        /// Form decoding ('+' is a space, as in the doc's contact example).
        static func decode(_ s: String) -> String? {
            s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
    }
}
