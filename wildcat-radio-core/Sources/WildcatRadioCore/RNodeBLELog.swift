#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// A file-backed diary of everything iOS tells the RNode link: the central's state, scan hits,
/// connects, pairing errors, service and characteristic discovery, subscribe, write and notify
/// errors, reconnects and every state change. For pairing trouble the console can't explain
/// (an RNode wants an encrypted, PIN-paired link and iOS says little about why it refused).
///
/// On by itself in DEBUG builds on iOS; in a Release build when the app is launched with
/// `-RNodeDiag`. Lines go to `Documents/rnode-ble.log` (the Files app shows it under
/// "On My iPhone > Wildcat Mesh"; `tools/rnode-diag.sh` pulls it), kept to the last ~200 KB.
public final class RNodeBLELog: @unchecked Sendable {
    public static let fileName = "rnode-ble.log"
    /// Roughly this much of the tail survives a trim.
    public static let keepBytes = 200 * 1024
    /// Trimming happens once the file is this big, so it isn't rewritten on every line.
    static let trimAt = keepBytes + 56 * 1024
    public static let argument = "-RNodeDiag"

    public static let shared = RNodeBLELog(url: defaultURL, enabled: defaultEnabled)

    /// Where the lines go; nil when the log is off.
    public let url: URL?
    public let isEnabled: Bool
    private let queue = DispatchQueue(label: "wildcat.rnode.ble-log", qos: .utility)
    private var handle: FileHandle?
    private var size = 0
    private var sessionBegun = false
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(url: URL?, enabled: Bool) {
        self.isEnabled = enabled && url != nil
        self.url = enabled ? url : nil
    }

    deinit { try? handle?.close() }

    /// `-RNodeDiag` on the launch arguments, or a DEBUG build on the phone. Never under
    /// `swift test` on the Mac unless asked, so tests don't write into ~/Documents.
    public static var defaultEnabled: Bool {
        if ProcessInfo.processInfo.arguments.contains(argument) { return true }
        #if DEBUG && os(iOS)
        return true
        #else
        return false
        #endif
    }

    public static var defaultURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    /// Why this process is logging, for the session header.
    static var reason: String {
        if ProcessInfo.processInfo.arguments.contains(argument) { return "launched with \(argument)" }
        #if DEBUG
        return "DEBUG build"
        #else
        return "release build"
        #endif
    }

    // MARK: Writing

    /// The header, once per process: when, which app build, which iOS, which phone.
    public func beginSession() {
        guard isEnabled else { return }
        queue.async { [self] in
            guard !sessionBegun else { return }
            sessionBegun = true
            let b = Bundle.main
            let app = [b.bundleIdentifier, b.infoDictionary?["CFBundleShortVersionString"] as? String,
                       (b.infoDictionary?["CFBundleVersion"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            let os = ProcessInfo.processInfo
            let header = """

            ==== RNode BLE log: session \(stamp.string(from: Date())) ====
            app: \(app.isEmpty ? "?" : app)
            os: \(os.operatingSystemVersionString) (\(Self.platform))
            device: \(Self.hardwareModel)
            log: \(Self.reason), file \(url?.path ?? "-")
            bluetooth authorization: \(Self.name(CBManager.authorization))

            """
            write(header)
        }
    }

    /// Appends one timestamped line.
    public func log(_ line: String) {
        guard isEnabled else { return }
        let now = Date()
        queue.async { [self] in
            write("\(stamp.string(from: now))  \(line)\n")
        }
    }

    /// The last `bytes` of the file (lossy if it cuts a character), after every pending line.
    public func tail(bytes: Int = 16 * 1024) -> String {
        guard isEnabled, let url else { return "" }
        return queue.sync {
            guard let data = try? Data(contentsOf: url) else { return "" }
            let slice = data.count > bytes ? data.suffix(bytes) : data[...]
            return String(decoding: slice, as: UTF8.self)
        }
    }

    /// Forgets the file (a fresh start before a pairing attempt).
    public func clear() {
        guard isEnabled, let url else { return }
        queue.sync {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
            size = 0
            sessionBegun = false
        }
    }

    private func write(_ text: String) {
        guard let url, let data = text.data(using: .utf8) else { return }
        if handle == nil { open(url) }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            return
        }
        if size > Self.trimAt { trim(url) }
    }

    private func open(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Keeps the newest `keepBytes`, from the start of a line.
    private func trim(_ url: URL) {
        try? handle?.close()
        handle = nil
        guard let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(Self.keepBytes)
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: nl)...] }
        var kept = Data("---- older lines trimmed ----\n".utf8)
        kept.append(tail)
        try? kept.write(to: url, options: .atomic)
        open(url)
    }

    // MARK: Describing CoreBluetooth

    /// "nil", or the whole NSError: domain, code (named when CoreBluetooth's), description, userInfo.
    public static func describe(_ error: Error?) -> String {
        guard let error else { return "nil" }
        let e = error as NSError
        var s = "\(e.domain) code=\(e.code)"
        if let name = codeName(e) { s += " (\(name))" }
        s += " \"\(e.localizedDescription)\""
        if !e.userInfo.isEmpty {
            let pairs = e.userInfo.keys.sorted().map { "\($0): \(String(describing: e.userInfo[$0]!))" }
            s += " userInfo={\(pairs.joined(separator: ", "))}"
        }
        return s
    }

    static func codeName(_ e: NSError) -> String? {
        switch e.domain {
        case CBErrorDomain:
            // CBError.Code
            return ["unknown", "invalidParameters", "invalidHandle", "notConnected", "outOfSpace", "operationCancelled",
                    "connectionTimeout", "peripheralDisconnected", "uuidNotAllowed", "alreadyAdvertising", "connectionFailed",
                    "connectionLimitReached", "unknownDevice", "operationNotSupported", "peerRemovedPairingInformation",
                    "encryptionTimedOut", "tooManyLEPairedDevices", "leGattExceededBackgroundNotificationLimit",
                    "leGattNearBackgroundNotificationLimit"].at(e.code)
        case CBATTErrorDomain:
            // CBATTError.Code
            return ["success", "invalidHandle", "readNotPermitted", "writeNotPermitted", "invalidPdu", "insufficientAuthentication",
                    "requestNotSupported", "invalidOffset", "insufficientAuthorization", "prepareQueueFull", "attributeNotFound",
                    "attributeNotLong", "insufficientEncryptionKeySize", "invalidAttributeValueLength", "unlikelyError",
                    "insufficientEncryption", "unsupportedGroupType", "insufficientResources"].at(e.code)
        default:
            return nil
        }
    }

    public static func name(_ s: CBManagerState) -> String {
        let n = ["unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"].at(s.rawValue) ?? "?"
        return "\(n)(\(s.rawValue))"
    }

    public static func name(_ a: CBManagerAuthorization) -> String {
        let n = ["notDetermined", "restricted", "denied", "allowedAlways"].at(a.rawValue) ?? "?"
        return "\(n)(\(a.rawValue))"
    }

    public static func name(_ s: CBPeripheralState) -> String {
        let n = ["disconnected", "connecting", "connected", "disconnecting"].at(s.rawValue) ?? "?"
        return "\(n)(\(s.rawValue))"
    }

    public static func describe(_ p: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"), (.write, "write"),
            (.notify, "notify"), (.indicate, "indicate"), (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"), (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired"),
        ]
        let set = names.filter { p.contains($0.0) }.map(\.1).joined(separator: ",")
        return "0x\(String(p.rawValue, radix: 16))[\(set)]"
    }

    /// One line for a peripheral: name, identifier, state.
    public static func describe(_ p: CBPeripheral) -> String {
        "\(p.name ?? "unnamed") \(p.identifier.uuidString) state=\(name(p.state))"
    }

    /// What a scan hit advertised, for telling an RNode from the rest.
    public static func describe(advertisement ad: [String: Any]) -> String {
        var parts: [String] = []
        if let n = ad[CBAdvertisementDataLocalNameKey] as? String { parts.append("localName=\"\(n)\"") }
        if let s = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] { parts.append("services=[\(s.map(\.uuidString).joined(separator: ","))]") }
        if let s = ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID], !s.isEmpty { parts.append("overflow=[\(s.map(\.uuidString).joined(separator: ","))]") }
        if let s = ad[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID], !s.isEmpty { parts.append("solicited=[\(s.map(\.uuidString).joined(separator: ","))]") }
        if let c = ad[CBAdvertisementDataIsConnectable] as? NSNumber { parts.append("isConnectable=\(c.boolValue)") } else { parts.append("isConnectable=?") }
        if let t = ad[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { parts.append("txPower=\(t)") }
        if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data { parts.append("manufacturer=\(m.map { String(format: "%02x", $0) }.joined())") }
        if let d = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !d.isEmpty { parts.append("serviceData=\(d.count) entries") }
        return parts.joined(separator: " ")
    }

    static var platform: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "other"
        #endif
    }

    /// "iPhone15,4": the model iOS reports through uname.
    static var hardwareModel: String {
        var u = utsname()
        uname(&u)
        return withUnsafePointer(to: &u.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
}

private extension Array where Element == String {
    func at(_ i: Int) -> String? { indices.contains(i) ? self[i] : nil }
}
#endif
