import Foundation

/// The outer header of a Reticulum packet, as an RNode hands it to its host: what kind of packet
/// it is, which destination it's for, how far it has come. Nothing past the header is read here:
/// payloads are encrypted to their destination (announces are signed), and making sense of them
/// is the Reticulum stack's job, not Wildcat's. Wildcat doesn't re-implement Reticulum.
///
/// Written from the wire format in the Reticulum manual ("Understanding Reticulum" → Wire Format):
///
///     [HEADER 2 bytes] [ADDRESSES 16/32 bytes] [CONTEXT 1 byte] [DATA 0-465 bytes]
///     byte 0  IFAC flag (7) · header type (6) · context flag (5) · propagation type (4) ·
///             destination type (3-2) · packet type (1-0)
///     byte 1  hops
///
/// and checked against packets the RNS library built, read back by RNS's own inbound path
/// (`Tests/.../Fixtures/make_reticulum_fixtures.py` → `reticulum-packets.json`).
///
/// An RNode in its normal (non-promiscuous) mode strips its own one-byte LoRa header and joins
/// the two halves of a split packet before it hands the packet to the host, so these bytes start
/// with Reticulum's flags. (Promiscuous receive delivers nothing on nRF52 and ESP32 boards with
/// firmware 1.76 to 1.86, so there is no raw-LoRa mode to read here.)
public struct ReticulumPacket: Equatable, Sendable {
    public enum HeaderType: UInt8, Equatable, Sendable {
        /// One address: the destination.
        case type1 = 0
        /// Two addresses: the transport node carrying it, then the destination.
        case type2 = 1
    }

    public enum Propagation: UInt8, Equatable, Sendable {
        case broadcast = 0, transport = 1
    }

    public enum DestinationType: UInt8, Equatable, Sendable {
        case single = 0, group = 1, plain = 2, link = 3

        public var word: String {
            switch self {
            case .single: return "single"
            case .group: return "group"
            case .plain: return "plain"
            case .link: return "link"
            }
        }
    }

    public enum PacketType: UInt8, Equatable, Sendable {
        case data = 0, announce = 1, linkRequest = 2, proof = 3
    }

    /// Why bytes aren't a packet Reticulum would take. Reticulum drops each of these on arrival.
    public enum Problem: Equatable, Sendable {
        /// Shorter than the header, addresses and context its flags call for.
        case tooShort(length: Int, needed: Int)
        /// At or past the hop limit.
        case tooManyHops(Int)
        /// Nothing after the context byte.
        case noData

        public var text: String {
            switch self {
            case .tooShort(let n, let needed): return "\(n) byte\(n == 1 ? "" : "s"), too short for a Reticulum header (\(needed)+)"
            case .tooManyHops(let h): return "\(h) hops: past Reticulum's limit of \(ReticulumPacket.maxHops)"
            case .noData: return "a header with no data after it"
            }
        }
    }

    /// What can be read of the bytes an RNode heard.
    public enum Reading: Equatable, Sendable {
        /// A Reticulum header in the clear.
        case packet(ReticulumPacket)
        /// The IFAC flag is set: an interface access code masks the rest, and reading it takes
        /// that network's name and passphrase.
        case masked
        /// Not something Reticulum would accept: noise, a damaged frame, or another protocol on
        /// the same channel.
        case unreadable(Problem)

        public var packet: ReticulumPacket? {
            if case .packet(let p) = self { return p }
            return nil
        }

        public var kind: Kind {
            switch self {
            case .packet(let p): return p.kind
            case .masked: return .masked
            case .unreadable: return .unreadable
            }
        }
    }

    /// What to call a heard packet on a screen.
    public enum Kind: Equatable, Hashable, Sendable, CaseIterable {
        case announce, data, pathRequest, linkRequest, proof, masked, unreadable

        public var word: String {
            switch self {
            case .announce: return "Announce"
            case .data: return "Data"
            case .pathRequest: return "Path request"
            case .linkRequest: return "Link request"
            case .proof: return "Proof"
            case .masked: return "Access code"
            case .unreadable: return "Unreadable"
            }
        }
    }

    /// Addresses (destination hashes, transport ids) are SHA-256 truncated to 16 bytes.
    public static let addressLength = 16
    /// Reticulum's hop limit (the manual's default m): a packet with this many hops is dropped.
    public static let maxHops = 128
    /// Reticulum's MTU: the largest packet, header included.
    public static let mtu = 500
    /// Flags, hops, one address, context.
    public static let shortestHeader = 2 + addressLength + 1
    /// Where path requests go: the PLAIN destination `rnstransport.path.request`, the same on
    /// every Reticulum network (the value the RNS library computes, from the fixture script).
    public static let pathRequestDestination = Data([
        0x6b, 0x9f, 0x66, 0x01, 0x4d, 0x98, 0x53, 0xfa, 0xab, 0x22, 0x0f, 0xba, 0x47, 0xd0, 0x27, 0x61,
    ])

    public let raw: Data
    public let headerType: HeaderType
    /// Signalling whose meaning depends on the packet (for announces: a ratchet key is included).
    public let contextFlag: Bool
    public let propagation: Propagation
    public let destinationType: DestinationType
    public let packetType: PacketType
    public let hops: Int
    /// Header type 2 only: the transport node that passed it on.
    public let transportID: Data?
    public let destinationHash: Data
    public let context: UInt8

    /// Reads the header. Never traps, whatever the bytes.
    public static func read(_ raw: Data) -> Reading {
        let p = [UInt8](raw)
        guard let flags = p.first else { return .unreadable(.tooShort(length: 0, needed: shortestHeader + 1)) }
        if flags & 0x80 != 0 {
            // The access code (1 to 64 bytes) follows the two header bytes; everything else is masked.
            let needed = shortestHeader + 2
            return p.count >= needed ? .masked : .unreadable(.tooShort(length: p.count, needed: needed))
        }
        let header = shortestHeader + ((flags >> 6) & 0x01 == 1 ? addressLength : 0)
        guard p.count >= header else { return .unreadable(.tooShort(length: p.count, needed: header + 1)) }
        guard Int(p[1]) < maxHops else { return .unreadable(.tooManyHops(Int(p[1]))) }
        guard p.count > header else { return .unreadable(.noData) }
        return .packet(ReticulumPacket(raw: raw, bytes: p))
    }

    /// The header when there is one in the clear (nil for masked and unreadable bytes).
    public init?(_ raw: Data) {
        guard case .packet(let p) = Self.read(raw) else { return nil }
        self = p
    }

    /// `bytes` already checked by `read`: long enough for its header type, hops in range.
    private init(raw: Data, bytes p: [UInt8]) {
        self.raw = raw
        let flags = p[0]
        headerType = HeaderType(rawValue: (flags >> 6) & 0x01) ?? .type1
        contextFlag = (flags >> 5) & 0x01 == 1
        propagation = Propagation(rawValue: (flags >> 4) & 0x01) ?? .broadcast
        destinationType = DestinationType(rawValue: (flags >> 2) & 0x03) ?? .single
        packetType = PacketType(rawValue: flags & 0x03) ?? .data
        hops = Int(p[1])
        var at = 2
        if headerType == .type2 {
            transportID = Data(p[at..<at + Self.addressLength])
            at += Self.addressLength
        } else {
            transportID = nil
        }
        destinationHash = Data(p[at..<at + Self.addressLength])
        at += Self.addressLength
        context = p[at]
    }

    /// Header bytes: flags, hops, the address or addresses, context.
    public var headerLength: Int { Self.shortestHeader + (headerType == .type2 ? Self.addressLength : 0) }
    /// Bytes after the context byte.
    public var dataLength: Int { raw.count - headerLength }

    public var kind: Kind {
        switch packetType {
        case .announce: return .announce
        case .linkRequest: return .linkRequest
        case .proof: return .proof
        case .data:
            return destinationType == .plain && destinationHash == Self.pathRequestDestination ? .pathRequest : .data
        }
    }

    /// "<53802fdd…>": the start of the destination hash, the way Reticulum tools abbreviate it.
    public var destinationPrefix: String { Self.hex(destinationHash.prefix(4)) }

    /// What the context byte means, for the values Reticulum names (nil for none and unknowns).
    public var contextName: String? { Self.contextNames[context] }

    public static let contextNames: [UInt8: String] = [
        0x01: "resource", 0x02: "resource advertisement", 0x03: "resource request", 0x04: "resource hashmap update",
        0x05: "resource proof", 0x06: "resource cancel (sender)", 0x07: "resource cancel (receiver)", 0x08: "cache request",
        0x09: "request", 0x0A: "response", 0x0B: "path response", 0x0C: "command", 0x0D: "command status",
        0x0E: "channel", 0xFA: "keepalive", 0xFB: "link identify", 0xFC: "link close", 0xFD: "link proof",
        0xFE: "link RTT", 0xFF: "link request proof",
    ]

    /// Lowercase hex without separators, as Reticulum prints hashes.
    public static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
