import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A raw MeshCore packet as heard on air (from the companion's RX log), per
/// src/Packet.cpp: header (route, payload type, version), optional transport
/// codes, a path of relay hashes (prefixes of each relayer's public key), payload.
public struct MeshCorePacket: Equatable, Sendable {
    public enum Route: UInt8, Sendable { case transportFlood = 0, flood = 1, direct = 2, transportDirect = 3 }
    public enum PayloadType: UInt8, Sendable {
        case request = 0, response, text, ack, advert, groupText, groupData, anonRequest, path, trace, multipart, control
        case rawCustom = 0x0F
    }

    /// The first byte as heard (route, type and version).
    public var header: UInt8
    public var route: Route
    /// The 4 transport-code bytes of transport routes, else empty.
    public var transportCodes: Data
    public var type: PayloadType?
    public var rawType: UInt8
    public var version: UInt8
    /// The path length byte as heard (hash size - 1 in the top 2 bits, count in the low 6).
    public var pathLen: UInt8
    /// Bytes per relay hash (1-3) and the hashes, oldest first.
    public var hashSize: Int
    public var path: [Data]
    public var payload: Data

    public var hops: Int { path.count }

    public init?(_ raw: Data) {
        let b = [UInt8](raw)
        guard b.count >= 2 else { return nil }
        var i = 0
        let header = b[i]; i += 1
        guard let route = Route(rawValue: header & 0x03) else { return nil }
        self.header = header
        self.route = route
        rawType = (header >> 2) & 0x0F
        type = PayloadType(rawValue: rawType)
        version = (header >> 6) & 0x03
        transportCodes = Data()
        if route == .transportFlood || route == .transportDirect {
            guard i + 4 < b.count else { return nil }
            transportCodes = Data(b[i..<(i + 4)])
            i += 4
        }
        guard i < b.count else { return nil }
        let pathLen = b[i]; i += 1
        self.pathLen = pathLen
        let count = Int(pathLen & 63), size = Int(pathLen >> 6) + 1
        guard size <= 3, count * size <= MeshCore.maxPathSize, i + count * size < b.count else { return nil }
        hashSize = size
        path = (0..<count).map { Data(b[(i + $0 * size)..<(i + ($0 + 1) * size)]) }
        i += count * size
        payload = Data(b[i...])
    }

    public var isFlood: Bool { route == .flood || route == .transportFlood }

    /// The packet as its sender put it on air: the same header and payload, no relay hashes yet.
    public var original: Data {
        var d = Data([header])
        d.append(transportCodes)
        d.append(pathLen & 0xC0)
        d.append(payload)
        return d
    }

    /// Bytes on air when sent (before any relay added its hash).
    public var originalSize: Int { 2 + transportCodes.count + payload.count }

    /// MeshCore's packet hash (Packet::calculatePacketHash): SHA-256 over the payload
    /// type (and path length for traces) and payload, first 8 bytes, as hex. The same
    /// for every copy of a packet, whichever way it came.
    public var hash: String? {
        #if canImport(CryptoKit)
        var d = Data([rawType])
        if type == .trace { d.append(pathLen) }
        d.append(payload)
        return SHA256.hash(data: d).prefix(8).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    /// Group text and data: the channel's 1-byte hash, first in the payload.
    public var channelHash: UInt8? {
        guard type == .groupText || type == .groupData, let h = payload.first else { return nil }
        return h
    }

    /// The recipient's 1-byte hash in addressed packets (request, response, text, path).
    public var destinationHash: UInt8? {
        guard version == 0, [.request, .response, .text, .path].contains(type), payload.count >= 2 else { return nil }
        return payload[payload.startIndex]
    }

    /// Whoever transmitted what we heard: the last relay, or the origin itself
    /// when it came straight from the sender (flood packets with no hops yet).
    public var lastHop: Data? { path.last }

    /// The sender's 1-byte hash in addressed packets (request, response, text,
    /// path, v1: dest hash, then source hash), when present.
    public var sourceHash: UInt8? {
        guard version == 0, [.request, .response, .text, .path].contains(type), payload.count >= 2 else { return nil }
        return payload[payload.startIndex + 1]
    }

    /// True when `publicKey` transmitted this packet (so its RSSI is theirs): the
    /// last relay of a flood packet, the sender of a zero-hop advert, or the sender
    /// of an addressed packet that reached us with no relays left.
    public func transmitted(by publicKey: Data) -> Bool {
        if route == .flood || route == .transportFlood, let last = lastHop { return publicKey.starts(with: last) }
        if let a = advert { return a.publicKey == publicKey && path.isEmpty }
        if path.isEmpty, let src = sourceHash { return publicKey.first == src }
        return false
    }

    // MARK: Adverts

    public struct Advert: Equatable, Sendable {
        public var publicKey: Data
        public var timestamp: Date
        public var kind: MeshCore.Contact.Kind
        public var position: Coordinate?
        public var name: String
    }

    /// payload: public key (32), timestamp (4), signature (64), app data
    /// (flags: low 4 bits = type; 0x10 lat/lon, 0x20/0x40 extra 2 bytes, 0x80 name).
    public var advert: Advert? {
        guard type == .advert else { return nil }
        let p = [UInt8](payload)
        guard p.count >= 32 + 4 + 64 + 1 else { return nil }
        let key = Data(p[0..<32])
        let ts = UInt32(p[32]) | UInt32(p[33]) << 8 | UInt32(p[34]) << 16 | UInt32(p[35]) << 24
        var i = 100
        let flags = p[i]; i += 1
        var pos: Coordinate?
        func i32(_ at: Int) -> Int32 {
            Int32(bitPattern: UInt32(p[at]) | UInt32(p[at + 1]) << 8 | UInt32(p[at + 2]) << 16 | UInt32(p[at + 3]) << 24)
        }
        if flags & 0x10 != 0, i + 8 <= p.count {
            let lat = i32(i), lon = i32(i + 4)
            if lat != 0 || lon != 0 { pos = Coordinate(latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6) }
            i += 8
        }
        if flags & 0x20 != 0 { i += 2 }
        if flags & 0x40 != 0 { i += 2 }
        let name = flags & 0x80 != 0 && i < p.count ? String(decoding: p[i...].prefix { $0 != 0 }, as: UTF8.self) : ""
        return Advert(publicKey: key, timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                      kind: MeshCore.Contact.Kind(rawValue: flags & 0x0F) ?? .none, position: pos, name: name)
    }
}
