import Foundation

/// MeshCore's companion-radio protocol (firmware v1.12+), as a phone app speaks it
/// over Bluetooth (Nordic UART service). One command at a time; each frame is a
/// type byte plus data, integers little-endian. Layouts follow the firmware's
/// examples/companion_radio/MyMesh.cpp (v1.17.1).
public enum MeshCore {
    public static let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// App -> firmware (write).
    public static let rx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Firmware -> app (notify).
    public static let tx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    /// The protocol version we understand (v3 adds SNR to received messages).
    public static let appTargetVersion: UInt8 = 3
    public static let publicKeySize = 32
    public static let maxPathSize = 64
    /// MAX_CHANNEL_DATA_LENGTH: the most payload a channel datagram can carry.
    public static let maxChannelData = 163
    /// The most text (UTF-8 bytes) Wildcat puts in one MeshCore message.
    public static let maxTextBytes = 133
    /// Wildcat's data type for channel datagrams (developer range, unregistered).
    public static let wildcatDataType: UInt16 = 0xFF57

    // MARK: Commands (app -> firmware)

    public enum Command: Equatable, Sendable {
        case appStart(name: String)
        case deviceQuery
        case setDeviceTime(Date)
        case getContacts
        case syncNextMessage
        case getChannel(index: Int)
        /// A 16-byte secret; index 0 is the public channel.
        case setChannel(index: Int, name: String, secret: Data)
        case sendChannelText(channel: Int, text: String, at: Date)
        /// To a contact by the first 6 bytes of its public key.
        case sendText(to: Data, text: String, at: Date, attempt: Int = 0)
        case sendSelfAdvert(flood: Bool)
        case getBatteryAndStorage
        case setName(String)
        /// Frequency MHz, bandwidth kHz, spreading factor 5-12, coding rate 5-8.
        case setRadio(frequency: Double, bandwidth: Double, spreadingFactor: Int, codingRate: Int)
        case setTxPower(Int)
        case setPosition(Coordinate)
        /// Auto-add contacts, telemetry modes byte, advert location policy (1 = share), multi-acks.
        case setOtherParams(manualAddContacts: UInt8, telemetryModes: UInt8, advertLocationPolicy: UInt8, multiAcks: UInt8)
        case removeContact(publicKey: Data)
        case resetPath(publicKey: Data)
        case reboot
        case setPIN(UInt32)
        /// Log in to a repeater or room server (the password travels encrypted).
        case login(publicKey: Data, password: String)
        case logout(publicKey: Data)
        case statusRequest(publicKey: Data)
        /// A command for a repeater's CLI (you must be logged in as admin).
        case remoteCommand(to: Data, command: String, at: Date)
        /// A binary datagram on a channel (flooded). Up to 163 bytes of payload.
        case sendChannelData(channel: Int, dataType: UInt16, payload: Data)
        /// Walk a list of 1-byte repeater hashes, collecting SNR at each hop.
        case trace(tag: UInt32, hashes: [UInt8])
        /// CMD_ADD_UPDATE_CONTACT (9): puts a contact in the node's own table (or
        /// updates it). Needed before the node can DM someone it only heard.
        case addContact(Contact)

        /// For logs: the command's name, never keys or message text.
        public var label: String {
            switch self {
            case .appStart: return "app start"
            case .deviceQuery: return "device query"
            case .setDeviceTime: return "set time"
            case .getContacts: return "get contacts"
            case .syncNextMessage: return "sync message"
            case .getChannel(let i): return "get channel \(i)"
            case .setChannel(let i, _, _): return "set channel \(i)"
            case .sendChannelText(let c, _, _): return "send to channel \(c)"
            case .sendText: return "send direct"
            case .sendSelfAdvert: return "advert"
            case .getBatteryAndStorage: return "battery"
            case .setName: return "set name"
            case .setRadio: return "set radio"
            case .setTxPower(let p): return "set power \(p)"
            case .setPosition: return "set position"
            case .setOtherParams: return "set other params"
            case .removeContact: return "remove contact"
            case .resetPath: return "reset path"
            case .reboot: return "reboot"
            case .setPIN: return "set PIN"
            case .login: return "login"
            case .logout: return "logout"
            case .statusRequest: return "status request"
            case .remoteCommand: return "remote command"
            case .trace(_, let h): return "trace (\(h.count) hops)"
            case .sendChannelData(let ch, _, let p): return "datagram to channel \(ch) (\(p.count) bytes)"
            case .addContact: return "add contact"
            }
        }

        public var data: Data {
            var d = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func secs(_ date: Date) -> UInt32 { UInt32(clamping: Int64(date.timeIntervalSince1970)) }
            switch self {
            case .appStart(let name):
                d.append(1)
                d.append(contentsOf: [UInt8](repeating: 0, count: 7))
                d.append(Data(name.utf8))
            case .deviceQuery:
                d.append(contentsOf: [22, MeshCore.appTargetVersion])
            case .setDeviceTime(let date):
                d.append(6); u32(secs(date))
            case .getContacts:
                d.append(4)
            case .syncNextMessage:
                d.append(10)
            case .getChannel(let i):
                d.append(contentsOf: [31, UInt8(clamping: i)])
            case .setChannel(let i, let name, let secret):
                d.append(contentsOf: [32, UInt8(clamping: i)])
                d.append(MeshCore.padded(name, 32))
                d.append(secret.prefix(16))
                if secret.count < 16 { d.append(Data(count: 16 - secret.count)) }
            case .sendChannelText(let ch, let text, let at):
                d.append(contentsOf: [3, 0, UInt8(clamping: ch)]); u32(secs(at)); d.append(Data(text.utf8))
            case .sendText(let to, let text, let at, let attempt):
                d.append(contentsOf: [2, 0, UInt8(clamping: attempt)]); u32(secs(at))
                d.append(to.prefix(6)); d.append(Data(text.utf8))
            case .sendSelfAdvert(let flood):
                d.append(contentsOf: [7, flood ? 1 : 0])
            case .getBatteryAndStorage:
                d.append(20)
            case .setName(let name):
                d.append(8); d.append(Data(String(decoding: Data(name.utf8).prefix(31), as: UTF8.self).utf8))
            case .setRadio(let f, let bw, let sf, let cr):
                d.append(11)
                u32(UInt32((f * 1000).rounded())); u32(UInt32((bw * 1000).rounded()))
                d.append(contentsOf: [UInt8(clamping: sf), UInt8(clamping: cr)])
            case .setTxPower(let p):
                d.append(contentsOf: [12, UInt8(bitPattern: Int8(clamping: p))])
            case .setPosition(let c):
                d.append(14)
                u32(UInt32(bitPattern: Int32((c.latitude * 1e6).rounded())))
                u32(UInt32(bitPattern: Int32((c.longitude * 1e6).rounded())))
            case .setOtherParams(let manual, let tele, let loc, let acks):
                d.append(contentsOf: [38, manual, tele, loc, acks])
            case .removeContact(let key):
                d.append(15); d.append(key.prefix(32))
            case .resetPath(let key):
                d.append(13); d.append(key.prefix(32))
            case .reboot:
                d.append(19); d.append(Data("reboot".utf8))
            case .setPIN(let pin):
                d.append(37); u32(pin)
            case .login(let key, let pw):
                d.append(26); d.append(key.prefix(32)); d.append(Data(pw.utf8.prefix(15)))
            case .logout(let key):
                d.append(29); d.append(key.prefix(32))
            case .statusRequest(let key):
                d.append(27); d.append(key.prefix(32))
            case .remoteCommand(let to, let cmd, let at):
                d.append(contentsOf: [2, 1, 0]); u32(secs(at)); d.append(to.prefix(6)); d.append(Data(cmd.utf8))
            case .sendChannelData(let ch, let dt, let payload):
                d.append(contentsOf: [62, UInt8(clamping: ch), 0xFF, UInt8(dt & 0xFF), UInt8(dt >> 8)])
                d.append(payload.prefix(MeshCore.maxChannelData))
            case .trace(let tag, let hashes):
                d.append(36); u32(tag); u32(0); d.append(0)   // auth 0, flags 0 = 1-byte hashes
                d.append(contentsOf: hashes)
            case .addContact(let c):
                d.append(9); d.append(MeshCore.contactRecord(c))
            }
            return d
        }
    }

    /// A contact as CMD_ADD_UPDATE_CONTACT reads it (MyMesh::updateContactFromFrame,
    /// v1.17.1): the same record RESP_CONTACT carries (writeContactRespFrame, which
    /// `contact(_:)` below decodes) minus the code byte: key (32), type, flags,
    /// out_path_len, out_path (64), name (32, null-padded), last advert (4), lat, lon
    /// (4 + 4, x1e6). The firmware's trailing lastmod is optional: leaving it out
    /// (144 bytes with the command code) lets the node stamp the contact with its own clock.
    static func contactRecord(_ c: Contact) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func i32(_ v: Double) { u32(UInt32(bitPattern: Int32(clamping: Int64((v * 1e6).rounded())))) }
        d.append(c.publicKey.prefix(publicKeySize))
        if d.count < publicKeySize { d.append(Data(count: publicKeySize - d.count)) }
        d.append(c.kind.rawValue)
        d.append(c.flags)
        // out_path_len: 0xFF = no known route (flood); else hash size - 1 in the top
        // 2 bits and the hash count in the low 6, as `hopCount` reads it back.
        let size = min(max(c.pathHashSize, 1), 3)
        if let n = c.pathLength {
            let count = max(0, min(n, 63, maxPathSize / size))
            d.append(UInt8((size - 1) << 6 | count))
            let path = c.path.prefix(count * size)
            d.append(path)
            d.append(Data(count: maxPathSize - path.count))
        } else {
            d.append(0xFF)
            d.append(Data(count: maxPathSize))
        }
        d.append(padded(c.name, 32))
        u32(c.lastAdvert.map { UInt32(clamping: Int64($0.timeIntervalSince1970)) } ?? 0)
        i32(c.position?.latitude ?? 0)
        i32(c.position?.longitude ?? 0)
        return d
    }

    static func padded(_ s: String, _ n: Int) -> Data {
        var d = Data(String(decoding: Data(s.utf8).prefix(n - 1), as: UTF8.self).utf8)
        d.append(Data(count: n - d.count))
        return d
    }

    // MARK: Frames (firmware -> app)

    public struct SelfInfo: Equatable, Sendable {
        public var advertType: UInt8
        public var txPower: Int
        public var maxTxPower: Int
        public var publicKey: Data
        public var position: Coordinate?
        public var multiAcks: UInt8 = 0
        /// 0 = don't share position in adverts, 1 = share.
        public var advertLocationPolicy: UInt8 = 0
        public var telemetryModes: UInt8 = 0
        /// Bit 0 set = contacts are added by hand, clear = automatically.
        public var manualAddContacts: UInt8 = 0
        /// Radio: MHz, kHz, spreading factor, coding rate.
        public var frequency: Double
        public var bandwidth: Double
        public var spreadingFactor: Int
        public var codingRate: Int
        public var name: String
    }

    public struct DeviceInfo: Equatable, Sendable {
        public var firmwareCode: Int
        public var maxContacts: Int
        public var maxChannels: Int
        public var buildDate: String
        public var manufacturer: String
        public var version: String
    }

    public struct Contact: Equatable, Sendable, Codable {
        public enum Kind: UInt8, Sendable, Codable { case none = 0, chat = 1, repeater = 2, room = 3, sensor = 4 }
        public var publicKey: Data
        public var kind: Kind
        public var flags: UInt8
        /// Hops to it, or nil when unknown (flood).
        public var pathLength: Int?
        /// The route to it: one hash per repeater, from us outward (bytes per hash in `pathHashSize`).
        public var path: Data = Data()
        public var pathHashSize: Int = 1
        public var name: String
        public var lastAdvert: Date?
        public var position: Coordinate?
        public var lastModified: Date?

        enum CodingKeys: String, CodingKey {
            case publicKey, kind, flags, pathLength, path, pathHashSize, name, lastAdvert, position, lastModified
        }

        public init(publicKey: Data, kind: Kind, flags: UInt8, pathLength: Int?, name: String, lastAdvert: Date?,
                    position: Coordinate?, lastModified: Date?) {
            self.publicKey = publicKey; self.kind = kind; self.flags = flags; self.pathLength = pathLength
            self.name = name; self.lastAdvert = lastAdvert; self.position = position; self.lastModified = lastModified
        }

        /// Tolerates contacts saved before `path` existed.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            publicKey = try c.decode(Data.self, forKey: .publicKey)
            kind = try c.decode(Kind.self, forKey: .kind)
            flags = try c.decode(UInt8.self, forKey: .flags)
            pathLength = try c.decodeIfPresent(Int.self, forKey: .pathLength)
            path = try c.decodeIfPresent(Data.self, forKey: .path) ?? Data()
            pathHashSize = try c.decodeIfPresent(Int.self, forKey: .pathHashSize) ?? 1
            name = try c.decode(String.self, forKey: .name)
            lastAdvert = try c.decodeIfPresent(Date.self, forKey: .lastAdvert)
            position = try c.decodeIfPresent(Coordinate.self, forKey: .position)
            lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified)
        }

        /// The 6-byte prefix messages and sends use.
        public var prefix: Data { publicKey.prefix(6) }
        public var shortID: String { publicKey.prefix(4).map { String(format: "%02x", $0) }.joined() }
    }

    public struct Message: Equatable, Sendable {
        public enum Origin: Hashable, Sendable, Codable {
            /// A direct message from a contact (first 6 bytes of its key).
            case contact(Data)
            case channel(Int)
        }
        public var origin: Origin
        /// Hops it travelled, nil when it came by a direct route.
        public var hops: Int?
        public var textType: UInt8
        public var sent: Date
        public var snr: Double?
        public var text: String
        /// Room server posts (textType 2, "signed"): the first 4 bytes of the public
        /// key of the member who wrote it. The origin is the room itself.
        public var author: Data? = nil
    }

    public enum Frame: Equatable, Sendable {
        case ok
        case error(code: Int?)
        case contactsStart(count: Int)
        case contact(Contact)
        case endOfContacts
        case selfInfo(SelfInfo)
        /// A direct message is on its way: `ack` matches a later `.sendConfirmed`.
        case sent(flood: Bool, ack: UInt32, timeout: UInt32)
        case message(Message)
        case currentTime(Date)
        case noMoreMessages
        case battery(millivolts: Int, usedKB: Int?, totalKB: Int?)
        case deviceInfo(DeviceInfo)
        case channelInfo(index: Int, name: String, secret: Data)
        /// A known contact advertised again.
        case advert(publicKey: Data)
        case newAdvert(Contact)
        case sendConfirmed(ack: UInt32, roundTripMs: UInt32)
        /// Messages are waiting: send `.syncNextMessage`.
        case messagesWaiting
        /// A raw packet heard on air, with its signal.
        case rxLog(snr: Double, rssi: Int, raw: Data)
        case loginResult(prefix: Data, ok: Bool, isAdmin: Bool)
        case status(prefix: Data, RepeaterStatus)
        case trace(TraceResult)
        case channelData(channel: Int, dataType: UInt16, payload: Data, snr: Double, hops: Int?)
        /// The node dropped a contact to make room for a new one (PUSH_CODE_CONTACT_DELETED).
        case contactDeleted(publicKey: Data)
        case other(code: UInt8, Data)
    }

    /// A repeater's status reply (examples/simple_repeater RepeaterStats).
    public struct RepeaterStatus: Equatable, Sendable {
        public var batteryMillivolts: Int
        public var txQueue: Int
        public var noiseFloor: Int
        public var lastRSSI: Int
        public var packetsReceived: UInt32
        public var packetsSent: UInt32
        public var airtimeSeconds: UInt32
        public var uptimeSeconds: UInt32
        public var sentFlood: UInt32, sentDirect: UInt32
        public var receivedFlood: UInt32, receivedDirect: UInt32
        public var errors: Int
        public var lastSNR: Double
        public var directDuplicates: Int, floodDuplicates: Int
        public var receiveAirtimeSeconds: UInt32?
        public var receiveErrors: UInt32?
    }

    /// A trace that came back: each hop's hash and how well it heard the packet,
    /// plus how well we heard the last hop.
    public struct TraceResult: Equatable, Sendable {
        public struct Hop: Equatable, Sendable {
            public var hash: Data
            public var snr: Double
        }
        public var tag: UInt32
        public var hops: [Hop]
        public var finalSNR: Double
    }

    /// The out-and-back route for tracing a repeater or room server: our route to
    /// it, the node itself, then the route back (1-byte hashes).
    public static func tracePath(to c: Contact) -> [UInt8]? {
        guard c.kind == .repeater || c.kind == .room, let me = c.publicKey.first else { return nil }
        let size = max(c.pathHashSize, 1)
        let out = stride(from: 0, to: c.path.count, by: size).map { c.path[c.path.startIndex + $0] }
        return out + [me] + out.reversed()
    }

    public struct DecodeError: Error, Equatable {}

    public static func decode(_ d: Data) throws -> Frame {
        var r = Reader(Array(d))
        let code = try r.u8()
        switch code {
        case 0: return .ok
        case 1: return .error(code: r.left > 0 ? Int(try r.u8()) : nil)
        case 2: return .contactsStart(count: Int(try r.u32()))
        case 3, 0x8A:
            let c = try contact(&r)
            return code == 3 ? .contact(c) : .newAdvert(c)
        case 4: return .endOfContacts
        case 5:
            let type = try r.u8(), tx = Int(try r.i8()), maxTx = Int(try r.i8())
            let key = try r.bytes(publicKeySize)
            let lat = try r.i32(), lon = try r.i32()
            let acks = try r.u8(), locPolicy = try r.u8(), tele = try r.u8(), manual = try r.u8()
            let freq = Double(try r.u32()) / 1000, bw = Double(try r.u32()) / 1000
            let sf = Int(try r.u8()), cr = Int(try r.u8())
            let name = String(decoding: r.rest(), as: UTF8.self)
            let pos = (lat == 0 && lon == 0) ? nil : Coordinate(latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6)
            return .selfInfo(SelfInfo(advertType: type, txPower: tx, maxTxPower: maxTx, publicKey: Data(key), position: pos,
                                      multiAcks: acks, advertLocationPolicy: locPolicy, telemetryModes: tele,
                                      manualAddContacts: manual,
                                      frequency: freq, bandwidth: bw, spreadingFactor: sf, codingRate: cr, name: name))
        case 6:
            let flood = try r.u8() == 1
            return .sent(flood: flood, ack: try r.u32(), timeout: try r.u32())
        case 7, 0x10:
            var snr: Double?
            if code == 0x10 { snr = Double(try r.i8()) / 4; _ = try r.bytes(2) }
            let from = Data(try r.bytes(6))
            let path = try r.u8(), type = try r.u8(), ts = try r.u32()
            // Signed (room server posts): the author's 4-byte key prefix comes first
            // (MyMesh::queueMessage's `extra`, the sender_prefix of onSignedMessageRecv).
            let author = type == 2 ? Data(try r.bytes(4)) : nil
            return .message(Message(origin: .contact(from), hops: hopCount(path), textType: type,
                                     sent: Date(timeIntervalSince1970: TimeInterval(ts)), snr: snr,
                                     text: String(decoding: r.rest(), as: UTF8.self), author: author))
        case 8, 0x11:
            var snr: Double?
            if code == 0x11 { snr = Double(try r.i8()) / 4; _ = try r.bytes(2) }
            let ch = Int(try r.u8()), path = try r.u8(), type = try r.u8(), ts = try r.u32()
            return .message(Message(origin: .channel(ch), hops: hopCount(path), textType: type,
                                     sent: Date(timeIntervalSince1970: TimeInterval(ts)), snr: snr,
                                     text: String(decoding: r.rest(), as: UTF8.self)))
        case 9: return .currentTime(Date(timeIntervalSince1970: TimeInterval(try r.u32())))
        case 10: return .noMoreMessages
        case 12:
            let mv = Int(try r.u16())
            let used = r.left >= 4 ? Int(try r.u32()) : nil
            let total = r.left >= 4 ? Int(try r.u32()) : nil
            return .battery(millivolts: mv, usedKB: used, totalKB: total)
        case 13:
            let fw = Int(try r.u8()), maxContacts = Int(try r.u8()) * 2, maxChannels = Int(try r.u8())
            _ = try r.bytes(4)   // BLE PIN: never surfaced
            let date = cString(try r.bytes(12)), maker = cString(try r.bytes(40)), ver = cString(try r.bytes(20))
            return .deviceInfo(DeviceInfo(firmwareCode: fw, maxContacts: maxContacts, maxChannels: maxChannels,
                                          buildDate: date, manufacturer: maker, version: ver))
        case 18:
            let i = Int(try r.u8())
            let name = cString(try r.bytes(32))
            return .channelInfo(index: i, name: name, secret: Data(try r.bytes(16)))
        case 0x80: return .advert(publicKey: Data(try r.bytes(publicKeySize)))
        case 0x8F: return .contactDeleted(publicKey: Data(try r.bytes(publicKeySize)))
        case 0x82: return .sendConfirmed(ack: try r.u32(), roundTripMs: try r.u32())
        case 0x83: return .messagesWaiting
        case 0x88:
            let snr = Double(try r.i8()) / 4, rssi = Int(try r.i8())
            return .rxLog(snr: snr, rssi: rssi, raw: Data(r.rest()))
        case 0x1B:
            let snr = Double(try r.i8()) / 4
            _ = try r.bytes(2)
            let ch = Int(try r.u8()), pathLen = try r.u8(), dt = try r.u16(), len = Int(try r.u8())
            let payload = Data(try r.bytes(len))
            return .channelData(channel: ch, dataType: dt, payload: payload, snr: snr,
                                hops: hopCount(pathLen))
        case 0x89:
            _ = try r.u8()
            let pathLen = Int(try r.u8()), flags = try r.u8()
            let tag = try r.u32(); _ = try r.u32()
            let size = 1 << Int(flags & 0x03)
            let hashes = try r.bytes(pathLen)
            let snrs = try r.bytes(pathLen / size).map { Double(Int8(bitPattern: $0)) / 4 }
            let final = Double(try r.i8()) / 4
            let hops = snrs.indices.map { TraceResult.Hop(hash: Data(hashes[($0 * size)..<(($0 + 1) * size)]), snr: snrs[$0]) }
            return .trace(TraceResult(tag: tag, hops: hops, finalSNR: final))
        case 0x85, 0x86:
            let perms = try r.u8()
            let prefix = Data(try r.bytes(6))
            return .loginResult(prefix: prefix, ok: code == 0x85, isAdmin: code == 0x85 && perms & 1 != 0)
        case 0x87:
            _ = try r.u8()
            let prefix = Data(try r.bytes(6))
            func i16() throws -> Int { Int(Int16(bitPattern: try r.u16())) }
            let s = RepeaterStatus(batteryMillivolts: Int(try r.u16()), txQueue: Int(try r.u16()), noiseFloor: try i16(),
                                   lastRSSI: try i16(), packetsReceived: try r.u32(), packetsSent: try r.u32(),
                                   airtimeSeconds: try r.u32(), uptimeSeconds: try r.u32(),
                                   sentFlood: try r.u32(), sentDirect: try r.u32(), receivedFlood: try r.u32(), receivedDirect: try r.u32(),
                                   errors: Int(try r.u16()), lastSNR: Double(try i16()) / 4,
                                   directDuplicates: Int(try r.u16()), floodDuplicates: Int(try r.u16()),
                                   receiveAirtimeSeconds: r.left >= 4 ? try r.u32() : nil,
                                   receiveErrors: r.left >= 4 ? try r.u32() : nil)
            return .status(prefix: prefix, s)
        default: return .other(code: code, Data(r.rest()))
        }
    }

    /// An encoded path_len byte -> hops: the low 6 bits count the hops, the top 2 are
    /// the hash size minus 1 (0x45 is 5 hops of 2-byte hashes). 0xFF: sent by flood, unknown.
    static func hopCount(_ pathLen: UInt8) -> Int? {
        pathLen == 0xFF ? nil : Int(pathLen & 63)
    }

    static func contact(_ r: inout Reader) throws -> Contact {
        let key = Data(try r.bytes(publicKeySize))
        let kind = Contact.Kind(rawValue: try r.u8()) ?? .none
        let flags = try r.u8(), pathLen = try r.u8()
        let pathBytes = try r.bytes(maxPathSize)
        let hashCount = hopCount(pathLen) ?? 0, hashSize = pathLen == 0xFF ? 1 : Int(pathLen >> 6) + 1
        let name = cString(try r.bytes(32))
        let advert = try r.u32()
        var pos: Coordinate?, mod: UInt32?
        if r.left >= 8 {
            let lat = try r.i32(), lon = try r.i32()
            if lat != 0 || lon != 0 { pos = Coordinate(latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6) }
            if r.left >= 4 { mod = try r.u32() }
        }
        var c = Contact(publicKey: key, kind: kind, flags: flags, pathLength: pathLen == 0xFF ? nil : hashCount,
                        name: name, lastAdvert: advert == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(advert)),
                        position: pos, lastModified: mod.flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0)) })
        c.path = Data(pathBytes.prefix(min(hashCount * hashSize, maxPathSize)))
        c.pathHashSize = hashSize
        return c
    }

    static func cString(_ b: [UInt8]) -> String {
        String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }

    struct Reader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }
        var left: Int { b.count - i }
        mutating func u8() throws -> UInt8 { guard i < b.count else { throw DecodeError() }; defer { i += 1 }; return b[i] }
        mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard left >= n else { throw DecodeError() }
            defer { i += n }
            return Array(b[i..<i + n])
        }
        mutating func u16() throws -> UInt16 { let x = try bytes(2); return UInt16(x[0]) | UInt16(x[1]) << 8 }
        mutating func u32() throws -> UInt32 {
            let x = try bytes(4)
            return UInt32(x[0]) | UInt32(x[1]) << 8 | UInt32(x[2]) << 16 | UInt32(x[3]) << 24
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func rest() -> [UInt8] { defer { i = b.count }; return Array(b[i...]) }
    }
}
