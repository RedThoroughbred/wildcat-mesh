import Foundation

/// What a connected RNode has told us, and where the startup conversation is:
/// connect → detect → read who it is (firmware, board, EEPROM) → read its radio settings →
/// ready. Pure logic over `RNode.Frame`s; `RNodeLink` moves the bytes.
public struct RNodeSession: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Waiting for the answer to CMD_DETECT.
        case detecting
        /// It's an RNode: reading firmware, platform, MCU, board and EEPROM.
        case readingInfo
        /// Reading frequency, bandwidth, TX power, SF, CR and radio state.
        case readingParameters
        case ready
        /// Something answered, but not with DETECT_RESP.
        case notAnRNode
    }

    /// One packet the RNode heard: when it arrived, how loud, and what its header says.
    public struct HeardPacket: Equatable, Sendable, Identifiable {
        /// Counts up from 1 per session; stable while the list trims its oldest.
        public let id: Int
        /// When the phone got it. The RNode queues packets briefly, so this is a little after
        /// it was on air.
        public let at: Date
        /// The packet's length as the RNode delivered it: the Reticulum packet, without the
        /// RNode's one-byte LoRa header.
        public let size: Int
        /// The RNode's reading for this packet. On nRF52 boards (RAK4631) the firmware reads the
        /// radio when it hands the packet over, so in a burst a packet can carry the next one's
        /// numbers: treat them as approximate when packets arrive back to back.
        public let rssi: Int?
        public let snr: Double?
        public let reading: ReticulumPacket.Reading
        /// Estimated time on air (all its LoRa frames), from the radio settings when it was heard.
        public let airtimeMs: Int?

        public init(id: Int, at: Date, size: Int, rssi: Int?, snr: Double?, reading: ReticulumPacket.Reading, airtimeMs: Int? = nil) {
            self.id = id
            self.at = at
            self.size = size
            self.rssi = rssi
            self.snr = snr
            self.reading = reading
            self.airtimeMs = airtimeMs
        }

        public var kind: ReticulumPacket.Kind { reading.kind }
        public var packet: ReticulumPacket? { reading.packet }
        /// LoRa frames it took on air: the RNode splits anything over 254 bytes in two.
        public var airFrames: Int { RNodeSession.airFrames(size) }
    }

    /// Packets heard per kind since connecting or the last clear.
    public struct HeardCounts: Equatable, Sendable {
        public private(set) var byKind: [ReticulumPacket.Kind: Int] = [:]

        public init(_ byKind: [ReticulumPacket.Kind: Int] = [:]) { self.byKind = byKind.filter { $0.value > 0 } }

        public subscript(kind: ReticulumPacket.Kind) -> Int { byKind[kind] ?? 0 }
        public var total: Int { byKind.values.reduce(0, +) }

        mutating func add(_ kind: ReticulumPacket.Kind) { byKind[kind, default: 0] += 1 }
    }

    /// The RNode's LoRa frames: a one-byte header, then up to 254 bytes of the packet; a longer
    /// packet goes as a full first frame and a second with the rest (firmware `transmit()`,
    /// SINGLE_MTU 255, HEADER_L 1). The host only ever sees the joined packet.
    public static func airFrames(_ size: Int) -> Int { size > 254 ? 2 : 1 }

    /// Bytes of each LoRa frame a packet of `size` takes on air, RNode header included.
    public static func airFrameBytes(_ size: Int) -> [Int] {
        guard size > 0 else { return [] }
        return size > 254 ? [255, size - 254 + 1] : [size + 1]
    }

    /// Estimated time on air for a packet of `size` with these settings, every frame counted.
    /// nil until the spreading factor, bandwidth, coding rate and preamble are known.
    public static func airtimeMs(size: Int, parameters p: RNode.RadioParameters, preambleSymbols: Int?) -> Int? {
        guard let sf = p.spreadingFactor, let bw = p.bandwidthKHz, let cr = p.codingRate, let preamble = preambleSymbols else { return nil }
        var total = 0
        for bytes in airFrameBytes(size) {
            guard let ms = LoRaAirtime.milliseconds(bytes: bytes, spreadingFactor: sf, bandwidthKHz: bw, codingRate: cr, preamble: preamble) else { return nil }
            total += ms
        }
        return total
    }

    public enum Event: Equatable, Sendable {
        case detected(Bool)
        case ready
        case deviceChanged
        case parametersChanged
        /// A packet was heard: `signal` has its RSSI and SNR.
        case packet(Data)
        case channelStats
        case battery
        case error(RNode.ErrorCode)
        case bluetoothPIN(UInt32)
        /// The RNode's send queue state changed (CMD_READY).
        case hostReady(Bool)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var device = RNode.DeviceInfo()
    public private(set) var parameters = RNode.RadioParameters()
    public private(set) var channel: RNode.ChannelStats?
    public private(set) var phy: RNode.PhyStats?
    public private(set) var csma: RNode.CSMA?
    public private(set) var battery: RNode.Battery?
    public private(set) var temperature: Int?
    /// RSSI (dBm) and SNR (dB) of the last packet heard.
    public private(set) var signal: (rssi: Int?, snr: Double?)?
    public private(set) var packetsHeard = 0
    /// The RNode's own counters of bytes received and sent over the air.
    public private(set) var statRX: UInt32?
    public private(set) var statTX: UInt32?
    public private(set) var lastPacketAt: Date?
    /// The last packets heard, newest first, at most `heardLimit` of them. `clearHeard` empties it.
    public private(set) var heard: [HeardPacket] = []
    /// Packets heard since connecting or the last `clearHeard`, by kind (these keep counting
    /// after `heard` is full).
    public private(set) var heardCounts = HeardCounts()
    /// When the counts began: the first packet heard, or the last clear.
    public private(set) var heardSince: Date?
    public static let heardLimit = 200
    private var heardSequence = 0
    public private(set) var lastStatsAt: Date?
    public private(set) var lastError: RNode.ErrorCode?
    public private(set) var hostReady: Bool?
    public private(set) var bluetoothPIN: UInt32?
    public private(set) var isDetected = false
    /// Setting kinds answered since connecting: startup is done when all six are in.
    private var answered: Set<UInt8> = []
    private var pendingRSSI: Int?
    private var pendingSNR: Double?

    public init() {}

    /// What to send after the Bluetooth link is up, in order.
    public static let startup: [RNode.Command] = [.detect, .firmwareVersion, .platform, .mcu, .board, .readEEPROM] + parameterReads
    /// The six settings reads; `refresh` sends them again.
    public static let parameterReads: [RNode.Command] = [.getFrequency, .getBandwidth, .getTxPower, .getSpreadingFactor,
                                                         .getCodingRate, .getRadioState]
    private static let parameterBytes: Set<UInt8> = Set(parameterReads.map(\.commandByte))

    /// The link is up: the first command (detect) is about to go.
    public mutating func begin() { phase = .detecting }

    /// Does `frame` answer `command`? (The same command byte comes back.)
    public static func completes(_ command: RNode.Command, with frame: RNode.Frame) -> Bool {
        command.reply == frame.commandByte
    }

    /// Applies a frame from the RNode and says what changed.
    public mutating func handle(_ frame: RNode.Frame, now: Date) -> [Event] {
        var events: [Event] = []
        switch frame {
        case .detect(let ok):
            isDetected = ok
            if ok {
                if phase == .idle || phase == .detecting { phase = .readingInfo }
            } else {
                phase = .notAnRNode
            }
            events.append(.detected(ok))
        case .firmwareVersion(let major, let minor):
            device.firmwareMajor = major
            device.firmwareMinor = minor
            events.append(.deviceChanged)
        case .platform(let b): device.platform = b; events.append(.deviceChanged)
        case .mcu(let b): device.mcu = b; events.append(.deviceChanged)
        case .board(let b): device.board = b; events.append(.deviceChanged)
        case .eeprom(let d):
            device.eeprom = RNode.EEPROM(d)
            if phase == .readingInfo { phase = .readingParameters }
            events.append(.deviceChanged)
        case .deviceHash(let d): device.deviceHash = d; events.append(.deviceChanged)
        case .firmwareHash(let expected, let d):
            if expected { device.expectedFirmwareHash = d } else { device.firmwareHash = d }
            events.append(.deviceChanged)
        case .frequency(let hz):
            parameters.frequencyHz = hz == 0 ? nil : hz
            events.append(.parametersChanged)
        case .bandwidth(let hz):
            parameters.bandwidthHz = hz == 0 ? nil : hz
            events.append(.parametersChanged)
        case .txPower(let v):
            parameters.txPower = v == 0xFF ? nil : Int(v)
            events.append(.parametersChanged)
        case .spreadingFactor(let v):
            parameters.spreadingFactor = v == 0 ? nil : Int(v)
            events.append(.parametersChanged)
        case .codingRate(let v):
            parameters.codingRate = v == 0 ? nil : Int(v)
            events.append(.parametersChanged)
        case .radioState(let on):
            parameters.radioOn = on
            events.append(.parametersChanged)
        case .radioLock: break
        case .statRX(let n): statRX = n
        case .statTX(let n): statTX = n
        case .rssi(let v): pendingRSSI = v
        case .snr(let v): pendingSNR = v
        case .data(let d):
            // The firmware sends RSSI, then SNR, then the packet.
            signal = (pendingRSSI, pendingSNR)
            pendingRSSI = nil
            pendingSNR = nil
            packetsHeard += 1
            lastPacketAt = now
            record(d, now: now)
            events.append(.packet(d))
        case .channelStats(let s):
            channel = s
            lastStatsAt = now
            events.append(.channelStats)
        case .phyStats(let s): phy = s
        case .csma(let c): csma = c
        case .battery(let b):
            battery = b
            events.append(.battery)
        case .temperature(let t): temperature = t
        case .ready(let ok):
            hostReady = ok
            events.append(.hostReady(ok))
        case .error(let e):
            lastError = e
            events.append(.error(e))
        case .bluetoothPIN(let pin):
            bluetoothPIN = pin
            events.append(.bluetoothPIN(pin))
        case .reset, .random, .unknown: break
        }
        if Self.parameterBytes.contains(frame.commandByte) {
            answered.insert(frame.commandByte)
            if isDetected, phase != .ready, phase != .notAnRNode, answered.isSuperset(of: Self.parameterBytes) {
                phase = .ready
                events.append(.ready)
            }
        }
        return events
    }

    private mutating func record(_ d: Data, now: Date) {
        heardSequence += 1
        let reading = ReticulumPacket.read(d)
        let airtime = Self.airtimeMs(size: d.count, parameters: parameters, preambleSymbols: phy?.preambleSymbols)
        let h = HeardPacket(id: heardSequence, at: now, size: d.count, rssi: signal?.rssi, snr: signal?.snr,
                            reading: reading, airtimeMs: airtime)
        heard.insert(h, at: 0)
        if heard.count > Self.heardLimit { heard.removeLast(heard.count - Self.heardLimit) }
        if heardSince == nil { heardSince = now }
        heardCounts.add(reading.kind)
    }

    /// Empties the heard list and its counts; `now` becomes "since when". `packetsHeard` (the
    /// all-time count) keeps going.
    public mutating func clearHeard(now: Date) {
        heard = []
        heardCounts = HeardCounts()
        heardSince = now
    }

    /// The heard list narrowed to some kinds (all of it for an empty set).
    public func heard(kinds: Set<ReticulumPacket.Kind>) -> [HeardPacket] {
        kinds.isEmpty ? heard : heard.filter { kinds.contains($0.kind) }
    }

    /// Destinations that announced themselves in the heard list, newest first: the hash, how
    /// many announces, and the latest one (its signal and hops).
    public struct Announcer: Equatable, Sendable, Identifiable {
        public let destinationHash: Data
        public let count: Int
        public let latest: HeardPacket
        public var id: Data { destinationHash }
    }

    public var announcers: [Announcer] {
        var order: [Data] = []
        var byHash: [Data: (count: Int, latest: HeardPacket)] = [:]
        for h in heard where h.kind == .announce {
            guard let hash = h.packet?.destinationHash else { continue }
            if let seen = byHash[hash] {
                byHash[hash] = (seen.count + 1, seen.latest)
            } else {
                order.append(hash)
                byHash[hash] = (1, h)
            }
        }
        return order.compactMap { hash in byHash[hash].map { Announcer(destinationHash: hash, count: $0.count, latest: $0.latest) } }
    }

    /// The RNode's name for screens: the product and band when known.
    public var productText: String? {
        guard let name = device.productName else { return nil }
        return device.bandText.map { "\(name) \($0)" } ?? name
    }
}
