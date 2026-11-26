import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// RNode: Mark Qvist's LoRa modem for the Reticulum network (markqvist/RNode_Firmware).
/// A phone talks to it as a *host*: KISS frames (`FEND command payload FEND`), the same
/// bytes over Bluetooth LE (Nordic UART service) as over USB serial. Constants follow
/// `RNS/Utilities/rnodeconf.py` (class KISS, class ROM) and `RNS/Interfaces/RNodeInterface.py`,
/// checked frame by frame against firmware 1.86 on a RAK4631 WisBlock
/// (`Tests/.../Fixtures/rnode-wisblock.json`, captured with `capture_rnode.py`).
///
/// Phase 1 is read and configure only: nothing here transmits a packet.
public enum RNode {
    // MARK: Bluetooth

    /// Nordic UART service, as `BLEConnection.UART_SERVICE_UUID` in RNS (both desktop and Android).
    public static let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Host -> RNode (write).
    public static let rx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// RNode -> host (notify).
    public static let tx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    /// The firmware names the device "RNode XXXX" (last two bytes of an MD5 of its BLE address).
    /// MeshCore companion nodes use the same UART service, so the name is how to tell them apart.
    public static let namePrefix = "RNode"
    /// `rnodeconf -p` (CMD_BT_CTRL 0x02) opens pairing for this long (BT_PAIRING_TIMEOUT 35000).
    public static let pairingWindow: TimeInterval = 35
    /// Bluetooth PINs the firmware generates are six digits (`random(899999)+100000`).
    public static let pinDigits = 6

    // MARK: Wire constants

    /// RSSI bytes travel as `rssi + 157` (firmware `rssi_offset`, RNS `RSSI_OFFSET`).
    public static let rssiOffset = 157
    /// The firmware's host MTU: the most payload a KISS data frame carries.
    public static let hostMTU = 508
    /// Bytes `CMD_ROM_READ` answers with (EEPROM_RESERVED).
    public static let eepromSize = 200
    /// Reticulum refuses firmware older than this (`REQUIRED_FW_VER_MAJ/MIN`).
    public static let minimumFirmware = (major: 1, minor: 52)

    public enum KISS {
        public static let fend: UInt8 = 0xC0
        public static let fesc: UInt8 = 0xDB
        public static let tfend: UInt8 = 0xDC
        public static let tfesc: UInt8 = 0xDD

        public static let data: UInt8 = 0x00
        public static let frequency: UInt8 = 0x01
        public static let bandwidth: UInt8 = 0x02
        public static let txPower: UInt8 = 0x03
        public static let spreadingFactor: UInt8 = 0x04
        public static let codingRate: UInt8 = 0x05
        public static let radioState: UInt8 = 0x06
        public static let radioLock: UInt8 = 0x07
        public static let detect: UInt8 = 0x08
        public static let leave: UInt8 = 0x0A
        public static let shortTermAirtimeLimit: UInt8 = 0x0B
        public static let longTermAirtimeLimit: UInt8 = 0x0C
        public static let ready: UInt8 = 0x0F
        public static let statRX: UInt8 = 0x21
        public static let statTX: UInt8 = 0x22
        public static let statRSSI: UInt8 = 0x23
        public static let statSNR: UInt8 = 0x24
        public static let statChannel: UInt8 = 0x25
        public static let statPhy: UInt8 = 0x26
        public static let statBattery: UInt8 = 0x27
        public static let statCSMA: UInt8 = 0x28
        public static let statTemperature: UInt8 = 0x29
        public static let blink: UInt8 = 0x30
        public static let random: UInt8 = 0x40
        public static let bluetoothControl: UInt8 = 0x46
        public static let board: UInt8 = 0x47
        public static let platform: UInt8 = 0x48
        public static let mcu: UInt8 = 0x49
        public static let firmwareVersion: UInt8 = 0x50
        public static let romRead: UInt8 = 0x51
        public static let romWrite: UInt8 = 0x52
        public static let reset: UInt8 = 0x55
        public static let deviceHash: UInt8 = 0x56
        public static let deviceSignature: UInt8 = 0x57
        public static let hashes: UInt8 = 0x60
        public static let bluetoothPIN: UInt8 = 0x62
        public static let error: UInt8 = 0x90
        public static let unknown: UInt8 = 0xFE

        public static let detectRequest: UInt8 = 0x73
        public static let detectResponse: UInt8 = 0x46
        public static let radioStateOff: UInt8 = 0x00
        public static let radioStateOn: UInt8 = 0x01
        public static let radioStateAsk: UInt8 = 0xFF
        /// Asking for a one-byte setting (TX power, SF, CR) is sending 0xFF.
        public static let ask: UInt8 = 0xFF

        /// KISS escaping: FESC -> FESC TFESC, FEND -> FESC TFEND.
        public static func escape(_ bytes: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + 2)
            for b in bytes {
                switch b {
                case fend: out += [fesc, tfend]
                case fesc: out += [fesc, tfesc]
                default: out.append(b)
                }
            }
            return out
        }

        /// One frame: `FEND command escaped-payload FEND`.
        public static func frame(_ command: UInt8, _ payload: [UInt8]) -> Data {
            Data([fend, command] + escape(payload) + [fend])
        }
    }

    // MARK: Commands (host -> RNode)

    public enum Command: Equatable, Sendable {
        public enum Bluetooth: UInt8, Sendable { case off = 0x00, on = 0x01, pair = 0x02 }

        /// CMD_DETECT with DETECT_REQ; a real RNode answers DETECT_RESP.
        case detect
        case firmwareVersion
        case platform
        case mcu
        case board
        /// The 200 reserved EEPROM bytes: product, model, serial, signature, saved config.
        case readEEPROM
        case deviceHash
        /// CMD_HASHES: `expected` is the firmware hash the EEPROM was signed for, else the running one.
        case firmwareHash(expected: Bool)
        case getFrequency
        case setFrequency(hz: UInt32)
        case getBandwidth
        case setBandwidth(hz: UInt32)
        case getTxPower
        case setTxPower(dBm: UInt8)
        case getSpreadingFactor
        case setSpreadingFactor(UInt8)
        case getCodingRate
        case setCodingRate(UInt8)
        case getRadioState
        /// On needs frequency, bandwidth, TX power and SF set first (the firmware's radio lock).
        case setRadioState(on: Bool)
        case statRX
        case statTX
        case statRSSI
        /// Can the modem take another packet (its queue isn't full)?
        case ready
        case random
        /// "Host left": the RNode forgets the last RSSI/SNR and unblanks its display.
        case leave
        /// CMD_BT_CTRL: off, on, or open pairing for 35 s. Saves the on/off choice to EEPROM.
        case bluetooth(Bluetooth)

        public var commandByte: UInt8 {
            switch self {
            case .detect: return KISS.detect
            case .firmwareVersion: return KISS.firmwareVersion
            case .platform: return KISS.platform
            case .mcu: return KISS.mcu
            case .board: return KISS.board
            case .readEEPROM: return KISS.romRead
            case .deviceHash: return KISS.deviceHash
            case .firmwareHash: return KISS.hashes
            case .getFrequency, .setFrequency: return KISS.frequency
            case .getBandwidth, .setBandwidth: return KISS.bandwidth
            case .getTxPower, .setTxPower: return KISS.txPower
            case .getSpreadingFactor, .setSpreadingFactor: return KISS.spreadingFactor
            case .getCodingRate, .setCodingRate: return KISS.codingRate
            case .getRadioState, .setRadioState: return KISS.radioState
            case .statRX: return KISS.statRX
            case .statTX: return KISS.statTX
            case .statRSSI: return KISS.statRSSI
            case .ready: return KISS.ready
            case .random: return KISS.random
            case .leave: return KISS.leave
            case .bluetooth: return KISS.bluetoothControl
            }
        }

        /// The payload before escaping. Four-byte values are big-endian, as the firmware reads them.
        public var payload: [UInt8] {
            func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
            switch self {
            case .detect: return [KISS.detectRequest]
            case .firmwareVersion, .platform, .mcu, .board, .readEEPROM, .statRX, .statTX, .statRSSI, .ready, .random: return [0x00]
            case .deviceHash: return [0x01]
            case .firmwareHash(let expected): return [expected ? 0x01 : 0x02]
            case .getFrequency, .getBandwidth: return [0, 0, 0, 0]
            case .setFrequency(let hz), .setBandwidth(let hz): return be32(hz)
            case .getTxPower, .getSpreadingFactor, .getCodingRate: return [KISS.ask]
            case .setTxPower(let v), .setSpreadingFactor(let v), .setCodingRate(let v): return [v]
            case .getRadioState: return [KISS.radioStateAsk]
            case .setRadioState(let on): return [on ? KISS.radioStateOn : KISS.radioStateOff]
            case .leave: return [0xFF]
            case .bluetooth(let b): return [b.rawValue]
            }
        }

        /// The bytes to write to the RNode.
        public var data: Data { KISS.frame(commandByte, payload) }

        /// For a command that sets a value: the command that reads that value back.
        public var readBack: Command? {
            switch self {
            case .setFrequency: return .getFrequency
            case .setBandwidth: return .getBandwidth
            case .setTxPower: return .getTxPower
            case .setSpreadingFactor: return .getSpreadingFactor
            case .setCodingRate: return .getCodingRate
            case .setRadioState: return .getRadioState
            default: return nil
            }
        }

        /// The command byte of the frame that answers this, or nil when nothing comes back.
        public var reply: UInt8? {
            switch self {
            case .leave, .bluetooth: return nil
            default: return commandByte
            }
        }

        /// For logs.
        public var label: String {
            switch self {
            case .detect: return "detect"
            case .firmwareVersion: return "firmware version"
            case .platform: return "platform"
            case .mcu: return "mcu"
            case .board: return "board"
            case .readEEPROM: return "read EEPROM"
            case .deviceHash: return "device hash"
            case .firmwareHash(let e): return e ? "expected firmware hash" : "firmware hash"
            case .getFrequency: return "get frequency"
            case .setFrequency(let hz): return "set frequency \(hz) Hz"
            case .getBandwidth: return "get bandwidth"
            case .setBandwidth(let hz): return "set bandwidth \(hz) Hz"
            case .getTxPower: return "get TX power"
            case .setTxPower(let v): return "set TX power \(v) dBm"
            case .getSpreadingFactor: return "get SF"
            case .setSpreadingFactor(let v): return "set SF \(v)"
            case .getCodingRate: return "get CR"
            case .setCodingRate(let v): return "set CR \(v)"
            case .getRadioState: return "get radio state"
            case .setRadioState(let on): return on ? "radio on" : "radio off"
            case .statRX: return "stat rx"
            case .statTX: return "stat tx"
            case .statRSSI: return "stat rssi"
            case .ready: return "ready?"
            case .random: return "random"
            case .leave: return "leave"
            case .bluetooth(let b): return "bluetooth \(b)"
            }
        }
    }

    // MARK: Frames (RNode -> host)

    public enum Frame: Equatable, Sendable {
        case detect(Bool)
        case firmwareVersion(major: UInt8, minor: UInt8)
        case platform(UInt8)
        case mcu(UInt8)
        case board(UInt8)
        case eeprom(Data)
        case deviceHash(Data)
        case firmwareHash(expected: Bool, Data)
        case frequency(UInt32)
        case bandwidth(UInt32)
        /// 0xFF means not set yet.
        case txPower(UInt8)
        /// 0 means not set yet.
        case spreadingFactor(UInt8)
        case codingRate(UInt8)
        case radioState(Bool)
        case radioLock(Bool)
        case statRX(UInt32)
        case statTX(UInt32)
        /// dBm of the last packet heard. Before any packet (or after `leave`) the firmware's
        /// sentinel decodes to -36: only trust it when a packet follows (`RNodeSession` does).
        case rssi(Int)
        /// dB of the last packet heard, in quarter-dB steps.
        case snr(Double)
        case channelStats(ChannelStats)
        case phyStats(PhyStats)
        case csma(CSMA)
        case battery(Battery)
        /// Celsius, nil when the firmware's reading is out of its -30…90 range.
        case temperature(Int?)
        case ready(Bool)
        case random(UInt8)
        case error(ErrorCode)
        case reset(UInt8)
        /// The six-digit PIN the RNode shows while pairing (CMD_BT_PIN).
        case bluetoothPIN(UInt32)
        /// A LoRa packet the RNode received.
        case data(Data)
        case unknown(command: UInt8, payload: Data)

        /// Parses an unescaped frame. Wrong lengths become `.unknown`: nothing here traps.
        public init(command: UInt8, payload: Data) {
            let p = [UInt8](payload)
            func u32() -> UInt32? {
                guard p.count == 4 else { return nil }
                return UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
            }
            func one() -> UInt8? { p.count == 1 ? p[0] : nil }
            let unknown = Frame.unknown(command: command, payload: payload)
            switch command {
            case KISS.data: self = .data(payload)
            case KISS.detect: self = one().map { .detect($0 == KISS.detectResponse) } ?? unknown
            case KISS.firmwareVersion: self = p.count == 2 ? .firmwareVersion(major: p[0], minor: p[1]) : unknown
            case KISS.platform: self = one().map(Frame.platform) ?? unknown
            case KISS.mcu: self = one().map(Frame.mcu) ?? unknown
            case KISS.board: self = one().map(Frame.board) ?? unknown
            case KISS.romRead: self = .eeprom(payload)
            case KISS.deviceHash: self = p.count == 32 ? .deviceHash(payload) : unknown
            case KISS.hashes:
                guard p.count == 33, p[0] == 1 || p[0] == 2 else { self = unknown; return }
                self = .firmwareHash(expected: p[0] == 1, Data(p[1...]))
            case KISS.frequency: self = u32().map(Frame.frequency) ?? unknown
            case KISS.bandwidth: self = u32().map(Frame.bandwidth) ?? unknown
            case KISS.txPower: self = one().map(Frame.txPower) ?? unknown
            case KISS.spreadingFactor: self = one().map(Frame.spreadingFactor) ?? unknown
            case KISS.codingRate: self = one().map(Frame.codingRate) ?? unknown
            case KISS.radioState: self = one().map { .radioState($0 != 0) } ?? unknown
            case KISS.radioLock: self = one().map { .radioLock($0 != 0) } ?? unknown
            case KISS.statRX: self = u32().map(Frame.statRX) ?? unknown
            case KISS.statTX: self = u32().map(Frame.statTX) ?? unknown
            case KISS.statRSSI: self = one().map { .rssi(Int($0) - RNode.rssiOffset) } ?? unknown
            case KISS.statSNR: self = one().map { .snr(Double(Int8(bitPattern: $0)) * 0.25) } ?? unknown
            case KISS.statChannel: self = ChannelStats(payload: p).map(Frame.channelStats) ?? unknown
            case KISS.statPhy: self = PhyStats(payload: p).map(Frame.phyStats) ?? unknown
            case KISS.statCSMA: self = p.count == 3 ? .csma(CSMA(band: p[0], minimum: p[1], maximum: p[2])) : unknown
            case KISS.statBattery: self = p.count == 2 ? .battery(Battery(rawState: p[0], percent: Int(min(100, p[1])))) : unknown
            case KISS.statTemperature:
                guard let b = one() else { self = unknown; return }
                let t = Int(b) - 120
                self = .temperature((-30...90).contains(t) ? t : nil)
            case KISS.ready: self = one().map { .ready($0 == 1) } ?? unknown
            case KISS.random: self = one().map(Frame.random) ?? unknown
            case KISS.error: self = one().map { .error(ErrorCode($0)) } ?? unknown
            case KISS.reset: self = one().map(Frame.reset) ?? unknown
            case KISS.bluetoothPIN: self = u32().map(Frame.bluetoothPIN) ?? unknown
            default: self = unknown
            }
        }

        /// The command byte this frame came with.
        public var commandByte: UInt8 {
            switch self {
            case .detect: return KISS.detect
            case .firmwareVersion: return KISS.firmwareVersion
            case .platform: return KISS.platform
            case .mcu: return KISS.mcu
            case .board: return KISS.board
            case .eeprom: return KISS.romRead
            case .deviceHash: return KISS.deviceHash
            case .firmwareHash: return KISS.hashes
            case .frequency: return KISS.frequency
            case .bandwidth: return KISS.bandwidth
            case .txPower: return KISS.txPower
            case .spreadingFactor: return KISS.spreadingFactor
            case .codingRate: return KISS.codingRate
            case .radioState: return KISS.radioState
            case .radioLock: return KISS.radioLock
            case .statRX: return KISS.statRX
            case .statTX: return KISS.statTX
            case .rssi: return KISS.statRSSI
            case .snr: return KISS.statSNR
            case .channelStats: return KISS.statChannel
            case .phyStats: return KISS.statPhy
            case .csma: return KISS.statCSMA
            case .battery: return KISS.statBattery
            case .temperature: return KISS.statTemperature
            case .ready: return KISS.ready
            case .random: return KISS.random
            case .error: return KISS.error
            case .reset: return KISS.reset
            case .bluetoothPIN: return KISS.bluetoothPIN
            case .data: return KISS.data
            case .unknown(let c, _): return c
            }
        }
    }

    // MARK: Decoder

    /// Turns a byte stream (serial, or Bluetooth notifications of any size) into frames.
    /// Keeps its place between calls: a 200-byte EEPROM frame arrives in several notifications.
    public struct Decoder: Sendable {
        /// Longer than any firmware frame (display reads are 1024). Anything longer is dropped.
        public static let maxPayload = 1024

        private var inFrame = false
        private var escaped = false
        private var command: UInt8?
        private var payload: [UInt8] = []
        /// Frames dropped for being too long.
        public private(set) var dropped = 0

        public init() {}

        public mutating func feed(_ data: Data) -> [Frame] {
            var out: [Frame] = []
            for b in data {
                if b == KISS.fend {
                    if inFrame, let c = command { out.append(Frame(command: c, payload: Data(payload))) }
                    inFrame = true
                    escaped = false
                    command = nil
                    payload = []
                    continue
                }
                guard inFrame else { continue }
                guard let _ = command else { command = b; continue }
                if escaped {
                    escaped = false
                    payload.append(b == KISS.tfend ? KISS.fend : b == KISS.tfesc ? KISS.fesc : b)
                } else if b == KISS.fesc {
                    escaped = true
                } else {
                    payload.append(b)
                }
                if payload.count > Self.maxPayload {
                    inFrame = false
                    command = nil
                    payload = []
                    dropped += 1
                }
            }
            return out
        }
    }

    // MARK: Boards (rnodeconf's tables)

    public struct Model: Equatable, Sendable {
        public let minHz: UInt32
        public let maxHz: UInt32
        public let maxTxPower: Int
        /// As rnodeconf prints it: "779 - 928 MHz".
        public let band: String
        public let chip: String

        public var range: ClosedRange<UInt32> { minHz...maxHz }
    }

    public static let products: [UInt8: String] = [
        0x03: "RNode", 0xF0: "Hombrew RNode", 0xE0: "LilyGO T-Beam", 0xEA: "LilyGO T-Beam Supreme",
        0xD0: "LilyGO T-Deck", 0xB2: "LilyGO LoRa32 v1.0", 0xB0: "LilyGO LoRa32 v2.0", 0xB1: "LilyGO LoRa32 v2.1",
        0xC0: "Heltec LoRa32 v2", 0xC1: "Heltec LoRa32 v3", 0xC3: "Heltec LoRa32 v4", 0x15: "LilyGO T-Echo",
        0x10: "RAK4631", 0x20: "openCom XL", 0xC2: "Heltec Mesh Node T114", 0xEB: "Seeed XIAO ESP32S3 Wio-SX1262",
    ]

    public static let models: [UInt8: Model] = [
        0xA4: Model(minHz: 410_000_000, maxHz: 525_000_000, maxTxPower: 14, band: "410 - 525 MHz", chip: "SX1278"),
        0xA9: Model(minHz: 820_000_000, maxHz: 1_020_000_000, maxTxPower: 17, band: "820 - 1020 MHz", chip: "SX1276"),
        0xA1: Model(minHz: 410_000_000, maxHz: 525_000_000, maxTxPower: 22, band: "410 - 525 MHz", chip: "SX1268"),
        0xA6: Model(minHz: 820_000_000, maxHz: 1_020_000_000, maxTxPower: 22, band: "820 - 960 MHz", chip: "SX1262"),
        0xA5: Model(minHz: 410_000_000, maxHz: 525_000_000, maxTxPower: 17, band: "410 - 525 MHz", chip: "SX1278"),
        0xAA: Model(minHz: 820_000_000, maxHz: 1_020_000_000, maxTxPower: 17, band: "820 - 960 MHz", chip: "SX1276"),
        0xAC: Model(minHz: 2_400_000_000, maxHz: 2_500_000_000, maxTxPower: 20, band: "2.4 - 2.5 GHz", chip: "SX1280"),
        0xA2: Model(minHz: 410_000_000, maxHz: 525_000_000, maxTxPower: 17, band: "410 - 525 MHz", chip: "SX1278"),
        0xA7: Model(minHz: 820_000_000, maxHz: 1_020_000_000, maxTxPower: 17, band: "820 - 1020 MHz", chip: "SX1276"),
        0xA3: Model(minHz: 410_000_000, maxHz: 525_000_000, maxTxPower: 17, band: "410 - 525 MHz", chip: "SX1278"),
        0xA8: Model(minHz: 820_000_000, maxHz: 1_020_000_000, maxTxPower: 17, band: "820 - 1020 MHz", chip: "SX1276"),
        0xB3: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 17, band: "420 - 520 MHz", chip: "SX1278"),
        0xB8: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 17, band: "850 - 950 MHz", chip: "SX1276"),
        0xB4: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 17, band: "420 - 520 MHz", chip: "SX1278"),
        0xB9: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 17, band: "850 - 950 MHz", chip: "SX1276"),
        0x04: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 17, band: "420 - 520 MHz", chip: "SX1278"),
        0x09: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 17, band: "850 - 950 MHz", chip: "SX1276"),
        0xBA: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 17, band: "420 - 520 MHz", chip: "SX1278"),
        0xBB: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 17, band: "850 - 950 MHz", chip: "SX1276"),
        0xC4: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 17, band: "420 - 520 MHz", chip: "SX1278"),
        0xC9: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 17, band: "850 - 950 MHz", chip: "SX1276"),
        0xC5: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 22, band: "420 - 520 MHz", chip: "SX1268"),
        0xCA: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 22, band: "850 - 950 MHz", chip: "SX1262"),
        0xC8: Model(minHz: 860_000_000, maxHz: 930_000_000, maxTxPower: 28, band: "850 - 950 MHz", chip: "SX1262"),
        0xC6: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 22, band: "420 - 520 MHz", chip: "SX1268"),
        0xC7: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 22, band: "850 - 950 MHz", chip: "SX1262"),
        0xE4: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 17, band: "420 - 520 MHz", chip: "SX1278"),
        0xE9: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 17, band: "850 - 950 MHz", chip: "SX1276"),
        0xD4: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 22, band: "420 - 520 MHz", chip: "SX1268"),
        0xD9: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 22, band: "850 - 950 MHz", chip: "SX1262"),
        0xDB: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 22, band: "420 - 520 MHz", chip: "SX1268"),
        0xDC: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 22, band: "850 - 950 MHz", chip: "SX1262"),
        0xE3: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 22, band: "420 - 520 MHz", chip: "SX1268"),
        0xE8: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 22, band: "850 - 950 MHz", chip: "SX1262"),
        0x11: Model(minHz: 430_000_000, maxHz: 510_000_000, maxTxPower: 22, band: "430 - 510 MHz", chip: "SX1262"),
        0x12: Model(minHz: 779_000_000, maxHz: 928_000_000, maxTxPower: 22, band: "779 - 928 MHz", chip: "SX1262"),
        0x13: Model(minHz: 430_000_000, maxHz: 510_000_000, maxTxPower: 22, band: "430 - 510 MHz", chip: "SX1262 + SX1280"),
        0x14: Model(minHz: 779_000_000, maxHz: 928_000_000, maxTxPower: 22, band: "779 - 928 MHz", chip: "SX1262 + SX1280"),
        0x16: Model(minHz: 779_000_000, maxHz: 928_000_000, maxTxPower: 22, band: "430 - 510 Mhz", chip: "SX1262"),
        0x17: Model(minHz: 779_000_000, maxHz: 928_000_000, maxTxPower: 22, band: "779 - 928 Mhz", chip: "SX1262"),
        0x21: Model(minHz: 820_000_000, maxHz: 960_000_000, maxTxPower: 22, band: "820 - 960 MHz", chip: "SX1262 + SX1280"),
        0xDE: Model(minHz: 420_000_000, maxHz: 520_000_000, maxTxPower: 22, band: "420 - 520 MHz", chip: "SX1262"),
        0xDD: Model(minHz: 850_000_000, maxHz: 950_000_000, maxTxPower: 22, band: "850 - 950 MHz", chip: "SX1262"),
        0xFE: Model(minHz: 100_000_000, maxHz: 1_100_000_000, maxTxPower: 17, band: "(Band capabilities unknown)", chip: "Unknown"),
        0xFF: Model(minHz: 100_000_000, maxHz: 1_100_000_000, maxTxPower: 14, band: "(Band capabilities unknown)", chip: "Unknown"),
    ]

    public static let platforms: [UInt8: String] = [0x90: "AVR", 0x80: "ESP32", 0x70: "NRF52"]
    public static let mcus: [UInt8: String] = [
        0x91: "ATmega1284P", 0x92: "ATmega2560", 0x81: "Espressif Systems ESP32", 0x71: "Nordic Semiconductor nRF52840",
    ]
    public static let boards: [UInt8: String] = [
        0x31: "RNode", 0x32: "Homebrew", 0x33: "T-Beam", 0x3B: "T-Deck", 0x34: "Huzzah32", 0x35: "Generic ESP32",
        0x36: "LoRa32 v2.0", 0x37: "LoRa32 v2.1", 0x43: "T-Echo", 0x51: "RAK4631", 0x3C: "Heltec T114", 0x3E: "XIAO ESP32S3",
    ]

    // MARK: EEPROM

    /// What `rnodeconf` saved in the RNode's EEPROM when it was provisioned: who the board is,
    /// a checksum and the vendor's (or the owner's) signature over that, plus the TNC-mode
    /// config if one was saved. Layout: rnodeconf `class ROM`.
    public struct EEPROM: Equatable, Sendable {
        public static let infoLockByte: UInt8 = 0x73
        public static let confOKByte: UInt8 = 0x73
        public static let minimumSize = 0xA8

        public let bytes: [UInt8]

        /// Needs at least the info block and the saved config (0xA8 bytes); the firmware sends 200.
        public init?(_ data: Data) {
            guard data.count >= Self.minimumSize else { return nil }
            bytes = [UInt8](data)
        }

        private func be32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }

        /// The info lock byte is set: product, model, serial and signature are meaningful.
        public var isProvisioned: Bool { bytes[0x9B] == Self.infoLockByte }
        public var product: UInt8 { bytes[0x00] }
        public var model: UInt8 { bytes[0x01] }
        public var hardwareRevision: UInt8 { bytes[0x02] }
        public var serial: Data { Data(bytes[0x03..<0x07]) }
        /// "00:00:00:03", as rnodeconf prints it.
        public var serialLine: String { serial.map { String(format: "%02x", $0) }.joined(separator: ":") }
        /// When rnodeconf provisioned it (big-endian seconds).
        public var made: Date { Date(timeIntervalSince1970: TimeInterval(be32(0x07))) }
        /// MD5 over product, model, hardware revision, serial and made.
        public var checksum: Data { Data(bytes[0x0B..<0x1B]) }
        /// 128 bytes: RSA-PSS over the checksum by the vendor's key, or the owner's local key.
        public var signature: Data { Data(bytes[0x1B..<0x9B]) }
        /// Some signature was written (not blank EEPROM).
        public var hasSignature: Bool {
            !signature.allSatisfy { $0 == 0xFF } && !signature.allSatisfy { $0 == 0x00 }
        }
        /// The checksum matches the info it covers (nil where MD5 isn't available).
        public var checksumValid: Bool? {
            #if canImport(CryptoKit)
            return Data(Insecure.MD5.hash(data: Data(bytes[0x00..<0x0B]))) == checksum
            #else
            return nil
            #endif
        }
        /// Radio settings saved for TNC mode (the RNode runs on its own, no host), if any.
        public var tncConfiguration: TNCConfiguration? {
            guard bytes[0xA7] == Self.confOKByte else { return nil }
            return TNCConfiguration(spreadingFactor: Int(bytes[0x9C]), codingRate: Int(bytes[0x9D]), txPower: Int(bytes[0x9E]),
                                    bandwidthHz: be32(0x9F), frequencyHz: be32(0xA3))
        }
        /// Bluetooth switched on with `rnodeconf -b` (nil when the dump is too short to say).
        public var bluetoothEnabled: Bool? { bytes.count > 0xB0 ? bytes[0xB0] == 0x73 : nil }
    }

    public struct TNCConfiguration: Equatable, Sendable {
        public var spreadingFactor: Int
        public var codingRate: Int
        public var txPower: Int
        public var bandwidthHz: UInt32
        public var frequencyHz: UInt32
    }

    /// What the app can say about the EEPROM signature. Validating it needs the signing key
    /// (`rnodeconf` holds the vendor keys and the owner's local key); the app checks the checksum
    /// and whether a signature is there.
    public enum SignatureState: Equatable, Sendable {
        /// No info lock: the EEPROM was never provisioned.
        case unprovisioned
        /// The checksum doesn't match the info it covers.
        case checksumMismatch
        /// Provisioned, checksum fine, no signature written.
        case unsigned
        /// Provisioned, checksum fine, a signature is present (vendor or local; verify with rnodeconf).
        case signed

        public var word: String {
            switch self {
            case .unprovisioned: return "Not provisioned"
            case .checksumMismatch: return "Checksum mismatch"
            case .unsigned: return "Unsigned"
            case .signed: return "Signed"
            }
        }

        public var detail: String {
            switch self {
            case .unprovisioned: return "Run rnodeconf --autoinstall to provision it."
            case .checksumMismatch: return "The EEPROM's own checksum is wrong. Reflash with rnodeconf."
            case .unsigned: return "Checksum OK. rnodeconf can sign it."
            case .signed: return "Checksum OK. rnodeconf --info validates the signature against its keys."
            }
        }
    }

    // MARK: Device info

    /// Everything read once after connecting, and the lines `rnodeconf --info` would print for it.
    public struct DeviceInfo: Equatable, Sendable {
        public var firmwareMajor: UInt8?
        public var firmwareMinor: UInt8?
        public var platform: UInt8?
        public var mcu: UInt8?
        public var board: UInt8?
        public var eeprom: EEPROM?
        public var deviceHash: Data?
        public var firmwareHash: Data?
        public var expectedFirmwareHash: Data?

        public init() {}

        /// "1.86" (the minor version padded to two digits, as rnodeconf does).
        public var firmwareVersion: String? {
            guard let firmwareMajor else { return nil }
            return String(format: "%d.%02d", Int(firmwareMajor), Int(firmwareMinor ?? 0))
        }
        /// Reticulum needs at least 1.52.
        public var firmwareIsCurrentEnough: Bool? {
            guard let firmwareMajor else { return nil }
            let minor = Int(firmwareMinor ?? 0)
            return Int(firmwareMajor) > RNode.minimumFirmware.major
                || (Int(firmwareMajor) == RNode.minimumFirmware.major && minor >= RNode.minimumFirmware.minor)
        }
        /// The running firmware is the one the EEPROM was signed for.
        public var firmwareHashMatches: Bool? {
            guard let firmwareHash, let expectedFirmwareHash else { return nil }
            return firmwareHash == expectedFirmwareHash
        }
        public var isProvisioned: Bool { eeprom?.isProvisioned ?? false }
        public var model: Model? { eeprom.flatMap { $0.isProvisioned ? RNode.models[$0.model] : nil } }
        /// "RAK4631".
        public var productName: String? { eeprom.flatMap { $0.isProvisioned ? RNode.products[$0.product] : nil } }
        /// "779 - 928 MHz".
        public var bandLabel: String? { model?.band }
        /// "779–928 MHz", for screens.
        public var bandText: String? { model?.band.replacingOccurrences(of: " - ", with: "–") }
        public var modemChip: String? { model?.chip }
        public var frequencyRange: ClosedRange<UInt32>? { model?.range }
        public var maxTxPower: Int? { model?.maxTxPower }
        public var platformName: String? { platform.flatMap { RNode.platforms[$0] } }
        public var mcuName: String? { mcu.flatMap { RNode.mcus[$0] } }
        public var boardName: String? { board.flatMap { RNode.boards[$0] } }
        /// "10:12:51": product, model and board codes.
        public var codes: String? {
            guard let e = eeprom, e.isProvisioned else { return nil }
            return [e.product, e.model].map { String(format: "%02x", $0) }.joined(separator: ":")
                + (board.map { String(format: ":%02x", $0) } ?? "")
        }
        /// "RAK4631 779 - 928 MHz (10:12:51)", the first line of `rnodeconf --info`.
        public var productLine: String? {
            guard let e = eeprom, e.isProvisioned, let codes else { return nil }
            let product = RNode.products[e.product] ?? String(format: "Unknown product %02x", e.product)
            let band = RNode.models[e.model]?.band ?? "(Band capabilities unknown)"
            return "\(product) \(band) (\(codes))"
        }
        public var signatureState: SignatureState {
            guard let e = eeprom, e.isProvisioned else { return .unprovisioned }
            if e.checksumValid == false { return .checksumMismatch }
            return e.hasSignature ? .signed : .unsigned
        }
        /// "779.0 MHz - 928.0 MHz", as rnodeconf prints it (Python float text).
        public var frequencyRangeLine: String? {
            model.map { "\(Double($0.minHz) / 1e6) MHz - \(Double($0.maxHz) / 1e6) MHz" }
        }

        /// The "Device info:" block of `rnodeconf --info`, line for line, except the signature
        /// line says what the app can check. `timeZone` is for the manufactured date (local time
        /// in rnodeconf).
        public func infoLines(timeZone: TimeZone = .current) -> [String] {
            guard let e = eeprom, e.isProvisioned, let productLine else { return ["EEPROM is invalid, no further information available"] }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var lines = [
                "Product            : \(productLine)",
                "Device signature   : \(signatureState.word)",
                "Firmware version   : \(firmwareVersion ?? "unknown")",
                "Hardware revision  : \(Int(e.hardwareRevision))",
                "Serial number      : \(e.serialLine)",
                "Modem chip         : \(modemChip ?? "Unknown")",
                "Frequency range    : \(frequencyRangeLine ?? "unknown")",
                "Max TX power       : \(maxTxPower ?? 0) dBm",
                "Manufactured       : \(f.string(from: e.made))",
            ]
            if let c = e.tncConfiguration {
                lines.append("Device mode        : TNC")
                lines.append("  Frequency        : \(Double(c.frequencyHz) / 1e6) MHz")
                lines.append("  Bandwidth        : \(Double(c.bandwidthHz) / 1e3) KHz")
                lines.append("  TX power         : \(c.txPower) dBm")
                lines.append("  Spreading factor : \(c.spreadingFactor)")
                lines.append("  Coding rate      : \(c.codingRate)")
            } else {
                lines.append("Device mode        : Normal (host-controlled)")
            }
            return lines
        }
    }

    // MARK: Radio parameters

    /// The five LoRa settings the host sets, and whether the radio is on. nil means the RNode
    /// hasn't been given that setting since it booted (frequency/bandwidth/SF/CR 0, TX power 0xFF).
    public struct RadioParameters: Equatable, Sendable {
        public var frequencyHz: UInt32?
        public var bandwidthHz: UInt32?
        public var txPower: Int?
        public var spreadingFactor: Int?
        public var codingRate: Int?
        public var radioOn: Bool?

        public init(frequencyHz: UInt32? = nil, bandwidthHz: UInt32? = nil, txPower: Int? = nil,
                    spreadingFactor: Int? = nil, codingRate: Int? = nil, radioOn: Bool? = nil) {
            self.frequencyHz = frequencyHz
            self.bandwidthHz = bandwidthHz
            self.txPower = txPower
            self.spreadingFactor = spreadingFactor
            self.codingRate = codingRate
            self.radioOn = radioOn
        }

        /// What Reticulum accepts (RNodeInterface): 137 MHz–3 GHz, 7.8–1625 kHz, 0–37 dBm, SF 5–12, CR 5–8.
        public static let frequencyLimits: ClosedRange<UInt32> = 137_000_000...3_000_000_000
        public static let bandwidthLimits: ClosedRange<UInt32> = 7_800...1_625_000
        /// The bandwidths an SX126x/SX127x modem can do.
        public static let bandwidths: [UInt32] = [7_800, 10_400, 15_600, 20_800, 31_250, 41_700, 62_500, 125_000, 250_000, 500_000]
        public static let spreadingFactors = 5...12
        public static let codingRates = 5...8
        public static let txPowerLimits = 0...37

        /// The firmware's radio lock: it won't turn the radio on until frequency, bandwidth,
        /// TX power and SF are set (CR defaults to 5 if left).
        public var canTurnOn: Bool { frequencyHz != nil && bandwidthHz != nil && txPower != nil && spreadingFactor != nil }
        public var isComplete: Bool { canTurnOn && codingRate != nil }
        public var frequencyMHz: Double? { frequencyHz.map { Double($0) / 1e6 } }
        public var bandwidthKHz: Double? { bandwidthHz.map { Double($0) / 1e3 } }
        /// 22 dBm -> 158.489 mW.
        public var txPowerMilliwatts: Double? { txPower.map { pow(10, Double($0) / 10) } }
        public var bitrateKbps: Double? {
            guard let spreadingFactor, let bandwidthHz, let codingRate else { return nil }
            return RNode.bitrateKbps(spreadingFactor: spreadingFactor, bandwidthHz: bandwidthHz, codingRate: codingRate)
        }

        public enum Problem: Equatable, Sendable {
            case frequencyOutsideLimits
            /// Outside what this board's model is built for.
            case frequencyOutsideBand(ClosedRange<UInt32>)
            case bandwidthUnsupported
            case spreadingFactorOutOfRange
            case codingRateOutOfRange
            case txPowerOutOfRange
            case txPowerAboveModel(max: Int)

            public var text: String {
                switch self {
                case .frequencyOutsideLimits: return "Frequency must be between 137 and 3000 MHz."
                case .frequencyOutsideBand(let r): return "This board is built for \(Double(r.lowerBound) / 1e6)–\(Double(r.upperBound) / 1e6) MHz."
                case .bandwidthUnsupported: return "Bandwidth must be one LoRa supports: " + RadioParameters.bandwidths.map { RNode.kHzText($0) }.joined(separator: ", ") + " kHz."
                case .spreadingFactorOutOfRange: return "Spreading factor must be 5 to 12."
                case .codingRateOutOfRange: return "Coding rate must be 4/5 to 4/8."
                case .txPowerOutOfRange: return "TX power must be 0 to 37 dBm."
                case .txPowerAboveModel(let max): return "This board can do at most \(max) dBm."
                }
            }
        }

        /// What's wrong with a proposed setting, if anything. Pass the board's model to check its band.
        public static func problems(frequencyHz: UInt32? = nil, bandwidthHz: UInt32? = nil, spreadingFactor: Int? = nil,
                                    codingRate: Int? = nil, txPower: Int? = nil, model: Model? = nil) -> [Problem] {
            var out: [Problem] = []
            if let f = frequencyHz {
                if !frequencyLimits.contains(f) { out.append(.frequencyOutsideLimits) }
                else if let m = model, !m.range.contains(f) { out.append(.frequencyOutsideBand(m.range)) }
            }
            if let b = bandwidthHz, !bandwidths.contains(b) { out.append(.bandwidthUnsupported) }
            if let sf = spreadingFactor, !spreadingFactors.contains(sf) { out.append(.spreadingFactorOutOfRange) }
            if let cr = codingRate, !codingRates.contains(cr) { out.append(.codingRateOutOfRange) }
            if let p = txPower {
                if !txPowerLimits.contains(p) { out.append(.txPowerOutOfRange) }
                else if let m = model, p > m.maxTxPower { out.append(.txPowerAboveModel(max: m.maxTxPower)) }
            }
            return out
        }
    }

    /// On-air bitrate as RNS computes it: sf × (4/cr) / (2^sf / bw_kHz) kbps.
    public static func bitrateKbps(spreadingFactor sf: Int, bandwidthHz bw: UInt32, codingRate cr: Int) -> Double? {
        guard (5...12).contains(sf), (5...8).contains(cr), bw > 0 else { return nil }
        return Double(sf) * ((4.0 / Double(cr)) / (pow(2, Double(sf)) / (Double(bw) / 1000)))
    }

    /// "125", "62.5", "7.8": a bandwidth in kHz without trailing zeros.
    public static func kHzText(_ hz: UInt32) -> String {
        let k = Double(hz) / 1000
        return k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
    }

    /// "914.875": a frequency in MHz, three decimals, trailing zeros trimmed to at least one.
    public static func mHzText(_ hz: UInt32) -> String {
        var s = String(format: "%.3f", Double(hz) / 1e6)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s
    }

    // MARK: Stats

    /// CMD_STAT_CHTM: what the modem hears, sent by itself about once a second while the radio is on.
    public struct ChannelStats: Equatable, Sendable {
        /// Percent of the last short window this RNode spent transmitting.
        public var airtimeShort: Double
        /// Percent of the last hour.
        public var airtimeLong: Double
        /// Percent of the short window the channel was busy (anyone).
        public var channelLoadShort: Double
        public var channelLoadLong: Double
        /// dBm the receiver sees right now.
        public var rssi: Int
        /// dBm when nobody is transmitting.
        public var noiseFloor: Int
        /// dBm of interference the modem flagged, if any.
        public var interference: Int?

        public init(airtimeShort: Double, airtimeLong: Double, channelLoadShort: Double, channelLoadLong: Double,
                    rssi: Int, noiseFloor: Int, interference: Int?) {
            self.airtimeShort = airtimeShort
            self.airtimeLong = airtimeLong
            self.channelLoadShort = channelLoadShort
            self.channelLoadLong = channelLoadLong
            self.rssi = rssi
            self.noiseFloor = noiseFloor
            self.interference = interference
        }

        /// 11 bytes: four big-endian hundredths of a percent, then RSSI, noise floor and interference bytes.
        public init?(payload p: [UInt8]) {
            guard p.count == 11 else { return nil }
            func pct(_ i: Int) -> Double { Double(UInt16(p[i]) << 8 | UInt16(p[i + 1])) / 100 }
            self.init(airtimeShort: pct(0), airtimeLong: pct(2), channelLoadShort: pct(4), channelLoadLong: pct(6),
                      rssi: Int(p[8]) - RNode.rssiOffset, noiseFloor: Int(p[9]) - RNode.rssiOffset,
                      interference: p[10] == 0xFF ? nil : Int(p[10]) - RNode.rssiOffset)
        }
    }

    /// CMD_STAT_PHYPRM: the timing the modem derived from the current settings.
    public struct PhyStats: Equatable, Sendable {
        public var symbolTimeMs: Double
        public var symbolRate: Int
        public var preambleSymbols: Int
        public var preambleTimeMs: Int
        public var csmaSlotMs: Int
        public var difsMs: Int

        public init?(payload p: [UInt8]) {
            guard p.count == 12 else { return nil }
            func u16(_ i: Int) -> Int { Int(UInt16(p[i]) << 8 | UInt16(p[i + 1])) }
            symbolTimeMs = Double(u16(0)) / 1000
            symbolRate = u16(2)
            preambleSymbols = u16(4)
            preambleTimeMs = u16(6)
            csmaSlotMs = u16(8)
            difsMs = u16(10)
        }
    }

    /// CMD_STAT_CSMA: the contention window the modem is using.
    public struct CSMA: Equatable, Sendable {
        public var band: UInt8
        public var minimum: UInt8
        public var maximum: UInt8
    }

    /// CMD_STAT_BAT, sent by itself about every 5 s on boards that measure a battery.
    public struct Battery: Equatable, Sendable {
        public enum State: UInt8, Sendable { case unknown = 0, discharging = 1, charging = 2, charged = 3 }

        public var rawState: UInt8
        public var percent: Int
        public var state: State? { State(rawValue: rawState) }

        public init(rawState: UInt8, percent: Int) {
            self.rawState = rawState
            self.percent = max(0, min(100, percent))
        }

        public var stateWord: String {
            switch state {
            case .discharging?: return "Discharging"
            case .charging?: return "Charging"
            case .charged?: return "Charged"
            default: return "Unknown"
            }
        }
    }

    public enum ErrorCode: Equatable, Sendable {
        case initRadio, txFailed, eepromLocked, queueFull, memoryLow, modemTimeout
        case other(UInt8)

        public init(_ raw: UInt8) {
            switch raw {
            case 0x01: self = .initRadio
            case 0x02: self = .txFailed
            case 0x03: self = .eepromLocked
            case 0x04: self = .queueFull
            case 0x05: self = .memoryLow
            case 0x06: self = .modemTimeout
            default: self = .other(raw)
            }
        }

        public var text: String {
            switch self {
            case .initRadio: return "The radio couldn't start. Check the settings are ones this board supports."
            case .txFailed: return "A transmission failed."
            case .eepromLocked: return "The EEPROM is locked."
            case .queueFull: return "The RNode's send queue is full."
            case .memoryLow: return "The RNode is low on memory."
            case .modemTimeout: return "The modem stopped answering the RNode."
            case .other(let c): return String(format: "Hardware error 0x%02x.", c)
            }
        }
    }

    /// Reticulum's 0–100 link quality from SNR: the usable floor is -9 dB at SF7, 2 dB lower per
    /// extra SF step, and +6 dB is full marks.
    public static func signalQuality(snr: Double, spreadingFactor sf: Int) -> Double {
        guard snr.isFinite else { return 0 }
        let minimum = -9.0 - Double(sf - 7) * 2
        let span = 6.0 - minimum
        return max(0, min(100, ((snr - minimum) / span * 100 * 10).rounded() / 10))
    }
}
