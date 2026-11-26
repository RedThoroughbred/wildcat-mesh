import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Group channel encryption as the firmware does it (Mesh::createGroupDatagram,
/// Utils::encryptThenMAC): payload = channel hash (1), MAC (2), AES-128-ECB of
/// timestamp (4) + flags (1) + "NAME: text", zero-padded to 16 bytes. The MAC is the
/// first 2 bytes of HMAC-SHA256 over the ciphertext, keyed by the secret padded to 32.
/// The channel hash is the first byte of SHA-256 of the 16-byte secret.
public enum MeshCoreChannelCrypto {
    public struct Plain: Equatable, Sendable {
        public var timestamp: UInt32
        public var flags: UInt8
        public var text: String
    }

    public static var isAvailable: Bool {
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        return true
        #else
        return false
        #endif
    }

    public static func hash(secret: Data) -> UInt8? {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: secret.prefix(16))).first
        #else
        return nil
        #endif
    }

    /// The text of a group text payload, when `secret` opens it (nil for another channel).
    public static func decrypt(payload: Data, secret: Data) -> Plain? {
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        let p = [UInt8](payload)
        guard secret.count >= 16, p.count >= 1 + 2 + 16, (p.count - 3) % 16 == 0,
              p[0] == hash(secret: secret) else { return nil }
        let cipher = Data(p[3...])
        guard Array(mac(cipher, secret: secret)) == Array(p[1..<3]),
              let plain = ecb(cipher, key: secret.prefix(16), encrypt: false), plain.count >= 5 else { return nil }
        let ts = UInt32(plain[0]) | UInt32(plain[1]) << 8 | UInt32(plain[2]) << 16 | UInt32(plain[3]) << 24
        let text = String(decoding: plain[5...].prefix { $0 != 0 }, as: UTF8.self)
        return Plain(timestamp: ts, flags: plain[4], text: text)
        #else
        return nil
        #endif
    }

    /// A group text payload (tests and the practice node build packets with it).
    public static func encrypt(_ plain: Plain, secret: Data) -> Data? {
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        guard secret.count >= 16, let h = hash(secret: secret) else { return nil }
        var data = Data()
        withUnsafeBytes(of: plain.timestamp.littleEndian) { data.append(contentsOf: $0) }
        data.append(plain.flags)
        data.append(Data(plain.text.utf8))
        if data.count % 16 != 0 { data.append(Data(count: 16 - data.count % 16)) }
        guard let cipher = ecb(data, key: secret.prefix(16), encrypt: true) else { return nil }
        return Data([h]) + mac(cipher, secret: secret) + cipher
        #else
        return nil
        #endif
    }

    #if canImport(CryptoKit) && canImport(CommonCrypto)
    private static func mac(_ cipher: Data, secret: Data) -> Data {
        var key = Data(secret.prefix(32))
        if key.count < 32 { key.append(Data(count: 32 - key.count)) }
        return Data(HMAC<SHA256>.authenticationCode(for: cipher, using: SymmetricKey(data: key)).prefix(2))
    }

    private static func ecb(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        guard data.count % 16 == 0, key.count == 16 else { return nil }
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), k.baseAddress, 16, nil,
                            i.baseAddress, data.count, o.baseAddress, data.count, &moved)
                }
            }
        }
        return status == kCCSuccess && moved == data.count ? out : nil
    }
    #endif
}

/// The last few seconds of packets the companion heard on air (LOG_RX_DATA, 0x88),
/// so the message frame that follows can be paired with the packet that carried it:
/// its RSSI, relay path, size and packet hash. The firmware logs every packet it
/// hears before handling it, so a message's packet is always already here.
public struct MeshCoreHeardLog: Sendable {
    public struct Entry: Equatable, Sendable {
        public var at: Date
        public var snr: Double
        public var rssi: Int
        public var raw: Data
        public var packet: MeshCorePacket
    }

    public static let capacity = 64
    public static let maxAge: TimeInterval = 10
    /// Direct messages can't be opened here, so only a packet this recent counts.
    public static let directWindow: TimeInterval = 2

    public private(set) var entries: [Entry] = []
    /// Payloads already paired with a message (never paired twice).
    private var used: [Data] = []

    public init() {}

    /// Keeps a heard packet; nil when it doesn't parse.
    @discardableResult
    public mutating func add(snr: Double, rssi: Int, raw: Data, at now: Date) -> Entry? {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.maxAge }
        guard let p = MeshCorePacket(raw) else { return nil }
        let e = Entry(at: now, snr: snr, rssi: rssi, raw: raw, packet: p)
        entries.append(e)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return e
    }

    /// The packet that carried `message`, which arrived at `now`: for a channel, the
    /// group text that opens with its secret to the same timestamp and text (or, without
    /// the secret, the latest one with the channel's hash within 2 s); for a direct
    /// message, the latest text packet to `myHash` from the contact's hash within 2 s.
    /// Of several copies (relayed more than one way) it's the first one heard.
    public mutating func match(_ message: MeshCore.Message, at now: Date, channelSecret: Data?, myHash: UInt8?) -> Entry? {
        let recent = entries.filter {
            now.timeIntervalSince($0.at) <= Self.maxAge && $0.at <= now.addingTimeInterval(1) && !used.contains($0.packet.payload)
        }
        func inWindow(_ e: Entry) -> Bool { now.timeIntervalSince(e.at) <= Self.directWindow }
        var pick: Entry?
        switch message.origin {
        case .channel:
            let secs = UInt32(clamping: Int64(message.sent.timeIntervalSince1970))
            let group = recent.filter { $0.packet.type == .groupText }
            if let secret = channelSecret, MeshCoreChannelCrypto.isAvailable {
                pick = group.first {
                    guard let plain = MeshCoreChannelCrypto.decrypt(payload: $0.packet.payload, secret: secret) else { return false }
                    return plain.timestamp == secs && (plain.text == message.text || (!message.text.isEmpty && plain.text.hasPrefix(message.text)))
                }
            } else {
                let h = channelSecret.flatMap(MeshCoreChannelCrypto.hash)
                pick = group.last { inWindow($0) && (h == nil || $0.packet.channelHash == h) }
            }
        case .contact(let prefix):
            pick = recent.last {
                inWindow($0) && $0.packet.type == .text && $0.packet.sourceHash == prefix.first
                    && (myHash == nil || $0.packet.destinationHash == myHash)
            }
        }
        guard let pick else { return nil }
        used.append(pick.packet.payload)
        if used.count > Self.capacity { used.removeFirst(used.count - Self.capacity) }
        return recent.first { $0.packet.payload == pick.packet.payload } ?? pick
    }
}

/// Watches the air for repeaters re-broadcasting a channel message this node sent:
/// the first heard copy that opens to our timestamp and text fixes the payload, and
/// every copy after it with that payload counts. Each copy's last hop is a repeater
/// that heard us (or heard one that did).
public struct MeshCoreEchoWatch: Equatable, Sendable {
    public static let window: TimeInterval = 30

    public var chat: UUID
    public var channel: Int
    public var sentAt: Date
    public var text: String
    /// Our packet's payload, once a first echo shows it.
    public var payload: Data?

    public init(chat: UUID, channel: Int, sentAt: Date, text: String) {
        self.chat = chat
        self.channel = channel
        self.sentAt = sentAt
        self.text = text
    }

    public func isOpen(at now: Date) -> Bool { now.timeIntervalSince(sentAt) <= Self.window }

    /// True (and remembers the payload) when `packet` is a copy of our message.
    public mutating func isEcho(_ packet: MeshCorePacket, secret: Data?) -> Bool {
        guard packet.type == .groupText, !packet.path.isEmpty else { return false }
        if let payload { return packet.payload == payload }
        guard let secret, let plain = MeshCoreChannelCrypto.decrypt(payload: packet.payload, secret: secret) else { return false }
        let secs = UInt32(clamping: Int64(sentAt.timeIntervalSince1970))
        guard plain.timestamp == secs, plain.text.hasSuffix(": " + text) || plain.text == text else { return false }
        payload = packet.payload
        return true
    }
}
