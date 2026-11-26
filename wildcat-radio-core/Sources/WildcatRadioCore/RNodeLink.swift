#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import Observation

/// The phone's Bluetooth link to an RNode (Reticulum LoRa modem). Finds RNodes by their
/// Nordic UART service and "RNode" name, connects, lets iOS pair (the RNode insists on an
/// encrypted, PIN-paired link), then runs `RNodeSession.startup` one command at a time.
///
/// Pairing, on a board with no screen: `rnodeconf -p <port>` opens a 35 s pairing window and
/// prints the six-digit PIN on the serial console; connecting from the phone inside that
/// window makes iOS ask for the PIN. The firmware drops the link once right after a
/// successful pairing; this link reconnects by itself. Bonded phones reconnect without a PIN.
///
/// Everything iOS tells this link also goes to `RNodeBLELog` (a file in Documents) when that
/// is on, so a failed pairing can be read back event by event.
@MainActor
@Observable
public final class RNodeLink: NSObject {
    public enum State: Equatable, Sendable {
        case poweredOff, unauthorized, idle, scanning
        case connecting(String)
        /// Connected; pairing if needed, then reading the RNode.
        case starting(String)
        case ready(String)
        case failed(String)

        public var isReady: Bool { if case .ready = self { return true } else { return false } }
        public var isBusy: Bool {
            switch self {
            case .connecting, .starting: return true
            default: return false
            }
        }
    }

    public struct Discovered: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var rssi: Int
        /// Named like the firmware names RNodes; other UART devices (MeshCore nodes) aren't.
        public var isRNode: Bool { name.uppercased().hasPrefix(RNode.namePrefix.uppercased()) }
    }

    static let serviceID = CBUUID(string: RNode.service)
    static let rxID = CBUUID(string: RNode.rx)
    static let txID = CBUUID(string: RNode.tx)
    static let lastNodeKey = "rnode.lastNode"
    static let lastNameKey = "rnode.lastName"
    static let reconnectKey = "rnode.autoReconnect"
    /// An RNode answers in milliseconds; this is for a dropped frame.
    static let timeout: TimeInterval = 2
    /// Reconnects after the firmware's post-pairing drop (and a lost link) before giving up.
    static let maxReconnects = 3

    public static let pairingHelp = "Pairing didn't finish. Put the RNode in pairing mode (rnodeconf -p, or its pairing button), then connect again within 35 seconds and type the 6-digit PIN it shows on the serial console."

    /// iOS's "Peer removed pairing information" at connect time: the phone still holds keys for
    /// this board from an earlier life (a reflash wipes the board's copy) and never gets as far
    /// as asking for a PIN. Settings lists the board under the name iOS remembers, which is
    /// the old one when it differs from what the RNode advertises now.
    public static func staleBondHelp(remembered: String?, advertised: String?) -> String {
        let old = remembered.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let now = advertised.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let entry: String
        if let old, let now, old.caseInsensitiveCompare(now) != .orderedSame {
            entry = "“\(old)”. That is this board's old name: it calls itself \(now) now, but iOS still lists it as \(old)"
        } else if let name = old ?? now {
            entry = "“\(name)”"
        } else {
            entry = "this RNode"
        }
        return "Your iPhone remembers this RNode from before it was flashed, but the RNode no longer has the keys. "
            + "Open Settings → Bluetooth and, under My Devices, find \(entry). Tap the ⓘ beside it, then Forget This Device. "
            + "Leave the other entries alone, then connect again here."
    }

    /// The name to show for a board: what it advertises now, else what it advertised when it was
    /// last connected, else the name iOS has cached (which can be from before a reflash).
    public static func displayName(advertised: String?, stored: String?, cached: String?) -> String {
        for candidate in [advertised, stored, cached] {
            if let n = candidate?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        }
        return "RNode"
    }

    /// Whether `error` is iOS reporting a bond the peer no longer has (CBError 14).
    nonisolated static func isStaleBond(_ error: Error?) -> Bool {
        guard let e = error as NSError? else { return false }
        return e.domain == CBErrorDomain && e.code == CBError.peerRemovedPairingInformation.rawValue
    }

    public private(set) var state: State = .idle
    public private(set) var discovered: [Discovered] = []
    public private(set) var session = RNodeSession()
    /// The phone's Bluetooth for this link.
    public private(set) var bluetooth: BluetoothStatus = .notStarted
    /// iOS reported the link encrypted and paired (we got past the notify subscription).
    public private(set) var pairedAt: Date?
    public var onEvent: ((RNodeSession.Event) -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    @ObservationIgnored private var listeners: [(RNodeSession.Event) -> Void] = []
    public func addListener(_ l: @escaping (RNodeSession.Event) -> Void) { listeners.append(l) }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var pending: Pending?
    private enum Pending: CustomStringConvertible {
        case scan, connect(UUID)
        var description: String {
            switch self {
            case .scan: return "scan"
            case .connect(let id): return "connect(\(id.uuidString))"
            }
        }
    }
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var rx: CBCharacteristic?
    @ObservationIgnored private var decoder = RNode.Decoder()
    @ObservationIgnored private(set) var queue: [RNode.Command] = []
    @ObservationIgnored private(set) var inflight: RNode.Command?
    @ObservationIgnored private var inflightSince: Date?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var reconnects = 0
    /// Names heard in advertisements since the app started, by Bluetooth identifier.
    @ObservationIgnored private var advertisedNames: [UUID: String] = [:]
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var sawFirstValue = false
    @ObservationIgnored private var sawFirstWrite = false
    @ObservationIgnored private var sawFirstWriteAck = false
    @ObservationIgnored private let defaults: UserDefaults
    /// The file diary of every Bluetooth event (`RNodeBLELog.shared`, on in DEBUG builds).
    @ObservationIgnored public let diagnosticLog: RNodeBLELog
    /// The link's clock (tests set their own).
    @ObservationIgnored public var clock: () -> Date = { Date() }
    /// Tests put a pretend RNode here: it gets each command's bytes in place of the Bluetooth write.
    @ObservationIgnored var wire: ((Data) -> Void)?

    public init(defaults: UserDefaults = .standard, log: RNodeBLELog = .shared) {
        self.defaults = defaults
        self.diagnosticLog = log
        super.init()
        log.beginSession()
        if BluetoothStatus.isDenied {
            bluetooth = .unauthorized
            state = .unauthorized
        }
        trace("link init: authorization=\(RNodeBLELog.name(CBManager.authorization)) isDenied=\(BluetoothStatus.isDenied) state=\(state) lastNode=\(lastNodeID?.uuidString ?? "none") \(lastNodeName ?? "") wantsReconnect=\(wantsReconnect)")
    }

    /// Creates the Bluetooth manager (iOS asks for permission the first time).
    public func startBluetooth() {
        guard central == nil else { return }
        bluetooth = .starting
        trace("startBluetooth: creating CBCentralManager on main (authorization=\(RNodeBLELog.name(CBManager.authorization)))")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func poweredOn(else then: Pending) -> CBCentralManager? {
        startBluetooth()
        if let central, central.state == .poweredOn { return central }
        trace("central not powered on (\(central.map { RNodeBLELog.name($0.state) } ?? "nil")); pending \(then)")
        pending = then
        return nil
    }

    private func note(_ s: String) {
        diagnosticLog.log("note: " + s)
        onDiagnostic?("RNode " + s)
    }

    /// A line only the file gets.
    private func trace(_ s: String) { diagnosticLog.log(s) }

    private func emit(_ e: RNodeSession.Event) {
        onEvent?(e)
        for l in listeners { l(e) }
    }

    /// Reconnect by itself: on by connecting, off by tapping Disconnect.
    public var wantsReconnect: Bool {
        get { defaults.bool(forKey: Self.reconnectKey) }
        set { defaults.set(newValue, forKey: Self.reconnectKey) }
    }

    public var lastNodeID: UUID? { defaults.string(forKey: Self.lastNodeKey).flatMap(UUID.init(uuidString:)) }
    /// "RNode 1F2A": the last one connected, for the reconnect button.
    public var lastNodeName: String? { defaults.string(forKey: Self.lastNameKey) }

    // MARK: Control

    /// Looks for RNodes (any Nordic UART device; `Discovered.isRNode` tells them from MeshCore nodes).
    public func scan() {
        guard let central = poweredOn(else: .scan) else { return }
        discovered = []
        trace("scan: state \(state) → scanning; scanForPeripherals(withServices: [\(Self.serviceID)])")
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceID], options: nil)
    }

    public func stopScan() {
        trace("stopScan (state=\(state), pending=\(String(describing: pending)))")
        if case .scan = pending { pending = nil }
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    public func connect(_ id: UUID) {
        guard let central = poweredOn(else: .connect(id)) else { return }
        let known = central.retrievePeripherals(withIdentifiers: [id])
        let inUse = central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
        trace("connect \(id.uuidString): retrievePeripherals → \(known.count) [\(known.map(RNodeBLELog.describe).joined(separator: "; "))]; "
              + "NUS peripherals iOS already has connected: \(inUse.count) [\(inUse.map(RNodeBLELog.describe).joined(separator: "; "))]")
        guard let p = known.first else {
            trace("connect: iOS doesn't know that identifier; state → failed")
            state = .failed("RNode not found. Scan again.")
            return
        }
        central.stopScan()
        reconnects = 0
        begin(p, how: "connect() via retrievePeripherals")
    }

    /// The board's name for the screen (`displayName`): never iOS's cached name when a newer one is known.
    private func name(for p: CBPeripheral) -> String {
        Self.displayName(advertised: advertisedNames[p.identifier],
                         stored: p.identifier == lastNodeID ? lastNodeName : nil,
                         cached: p.name)
    }

    private func begin(_ p: CBPeripheral, how: String) {
        guard let central else { trace("begin: no central, ignoring (\(how))"); return }
        peripheral = p
        p.delegate = self
        trace("central.connect \(RNodeBLELog.describe(p)) (\(how)); state \(state) → connecting")
        state = .connecting(name(for: p))
        central.connect(p, options: nil)
    }

    public func reconnectLast() {
        trace("reconnectLast: \(lastNodeID?.uuidString ?? "no last node") \(lastNodeName ?? "")")
        if let id = lastNodeID { connect(id) }
    }

    /// Tells the RNode the host left, then drops the link. No reconnecting until the next connect.
    public func disconnect() {
        trace("disconnect() by the user: peripheral=\(peripheral.map(RNodeBLELog.describe) ?? "nil") rx=\(rx != nil)")
        wantsReconnect = false
        pending = nil
        if let peripheral, let rx, peripheral.state == .connected {
            trace("writing leave to RX before cancelling")
            peripheral.writeValue(RNode.Command.leave.data, for: rx, type: writeType(rx))
        }
        if let peripheral {
            trace("cancelPeripheralConnection \(peripheral.identifier.uuidString)")
            central?.cancelPeripheralConnection(peripheral)
        }
        reset(to: .idle)
    }

    // MARK: Settings (the RNode answers each with the value it now has)

    public func refreshParameters() { for c in RNodeSession.parameterReads { enqueue(c) } }
    public func refreshCounters() { enqueue(.statRX); enqueue(.statTX) }
    public func setFrequency(hz: UInt32) { enqueue(.setFrequency(hz: hz)) }
    public func setBandwidth(hz: UInt32) { enqueue(.setBandwidth(hz: hz)) }
    public func setTxPower(_ dBm: Int) { enqueue(.setTxPower(dBm: UInt8(clamping: dBm))) }
    public func setSpreadingFactor(_ sf: Int) { enqueue(.setSpreadingFactor(UInt8(clamping: sf))) }
    public func setCodingRate(_ cr: Int) { enqueue(.setCodingRate(UInt8(clamping: cr))) }
    public func setRadio(on: Bool) { enqueue(.setRadioState(on: on)) }
    /// All five at once, in the order Reticulum sets them. The radio switch needs the first four.
    public func setAll(frequencyHz: UInt32, bandwidthHz: UInt32, txPower: Int, spreadingFactor: Int, codingRate: Int) {
        setFrequency(hz: frequencyHz)
        setBandwidth(hz: bandwidthHz)
        setTxPower(txPower)
        setSpreadingFactor(spreadingFactor)
        setCodingRate(codingRate)
    }
    /// Empties the console's heard list (`RNodeSession.clearHeard`).
    public func clearHeard() { session.clearHeard(now: clock()) }

    // MARK: Host mode: the Reticulum stack drives the RNode

    /// A host program on this phone (the Reticulum stack) is driving the RNode through this link:
    /// its bytes go to the RNode as they are, and everything the RNode sends goes back to it. The
    /// console's own commands stop while a host is attached; the session still decodes the stream,
    /// so the console keeps showing settings, signal and what's heard.
    public private(set) var hostAttached = false
    /// The host can talk to the RNode now: attached, and the link up and through its startup.
    public var hostConnected: Bool { hostAttached && state.isReady }
    @ObservationIgnored private var hostBytes: ((Data) -> Void)?
    @ObservationIgnored private var hostConnection: ((Bool) -> Void)?
    @ObservationIgnored private var reportedHostConnected = false
    @ObservationIgnored private var hostPending = Data()
    @ObservationIgnored private var hostAwaitingAck = false
    /// The most bytes one Bluetooth write carries (tests set one; otherwise what iOS negotiated).
    @ObservationIgnored var hostChunk: Int?

    /// Hands the RNode to a host. `onBytes` gets everything the RNode sends while the host is
    /// connected; `onConnected` is told whenever `hostConnected` changes (and once now).
    public func attachHost(onBytes: @escaping (Data) -> Void, onConnected: @escaping (Bool) -> Void) {
        hostBytes = onBytes
        hostConnection = onConnected
        hostAttached = true
        // Console reads still queued would interleave with the host's own commands.
        queue.removeAll()
        note("Reticulum attached: the console stops sending commands")
        reportedHostConnected = !hostConnected
        updateHostConnection()
    }

    /// Takes the RNode back from the host. The console reads the settings it left behind.
    public func detachHost() {
        guard hostAttached else { return }
        hostAttached = false
        hostBytes = nil
        hostPending.removeAll()
        hostAwaitingAck = false
        let tell = hostConnection
        hostConnection = nil
        reportedHostConnected = false
        tell?(false)
        note("Reticulum detached")
        if state.isReady { refreshParameters() }
    }

    /// Bytes from the host for the RNode, sent in Bluetooth-sized writes. Dropped while the link
    /// isn't ready: the host's RNode interface notices the link went away and starts over.
    public func hostWrite(_ data: Data) {
        guard hostConnected, !data.isEmpty else { return }
        hostPending.append(data)
        flushHostWrites()
    }

    private func flushHostWrites() {
        guard !hostPending.isEmpty else { return }
        if let wire {
            let size = max(1, hostChunk ?? 20)
            while !hostPending.isEmpty {
                let n = min(size, hostPending.count)
                wire(Data(hostPending.prefix(n)))
                hostPending.removeFirst(n)
            }
            return
        }
        guard let peripheral, let rx else { return }
        let type = writeType(rx)
        let size = max(20, hostChunk ?? peripheral.maximumWriteValueLength(for: type))
        while !hostPending.isEmpty {
            if type == .withoutResponse {
                // iOS has room for more: peripheralIsReady(toSendWriteWithoutResponse:) resumes.
                guard peripheral.canSendWriteWithoutResponse else { return }
            } else if hostAwaitingAck {
                return
            }
            let n = min(size, hostPending.count)
            peripheral.writeValue(Data(hostPending.prefix(n)), for: rx, type: type)
            hostPending.removeFirst(n)
            if type == .withResponse { hostAwaitingAck = true }
        }
    }

    private func updateHostConnection() {
        let now = hostConnected
        guard now != reportedHostConnected else { return }
        reportedHostConnected = now
        if !now {
            hostPending.removeAll()
            hostAwaitingAck = false
        }
        trace("host connected: \(now)")
        hostConnection?(now)
    }

    // MARK: Queue

    public func enqueue(_ c: RNode.Command) {
        if hostAttached {
            note("skipped \(c.label): Reticulum is driving the RNode")
            return
        }
        queue.append(c)
        pump()
    }

    private func pump() {
        guard inflight == nil, !queue.isEmpty, let write = writer else { return }
        let c = queue.removeFirst()
        note("→ \(c.label)")
        write(c.data)
        if c.reply == nil {
            pump()
        } else {
            inflight = c
            inflightSince = clock()
        }
    }

    private var writer: ((Data) -> Void)? {
        if let wire { return wire }
        guard let peripheral, let rx else { return nil }
        return { [weak self] data in
            guard let self else { return }
            let type = self.writeType(rx)
            if !self.sawFirstWrite {
                self.sawFirstWrite = true
                self.trace("writeValue \(data.count) bytes to RX \(rx.uuid.uuidString) type=\(type == .withResponse ? "withResponse" : "withoutResponse") "
                           + "peripheral state=\(RNodeBLELog.name(peripheral.state)) (first write; the note: → lines list the rest)")
            }
            peripheral.writeValue(data, for: rx, type: type)
        }
    }

    private func writeType(_ c: CBCharacteristic) -> CBCharacteristicWriteType {
        c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    }

    /// Bytes from the RNode (Bluetooth notifications, or a test's pretend RNode). A connected host
    /// gets them as they are; the console decodes them either way.
    func receive(_ data: Data) {
        if hostConnected { hostBytes?(data) }
        for frame in decoder.feed(data) { handle(frame) }
    }

    /// The link is up and subscribed: start the conversation. (Tests call this in place of Bluetooth.)
    func startSession() {
        trace("startSession: \(RNodeSession.startup.count) startup commands, \(queue.count) queued")
        decoder = RNode.Decoder()
        session = RNodeSession()
        session.begin()
        queue = RNodeSession.startup + queue
        inflight = nil
        pump()
    }

    func checkTimeout() {
        guard let since = inflightSince, let c = inflight, clock().timeIntervalSince(since) > Self.timeout else { return }
        if c == .detect {
            note("no answer to detect")
            fail("No answer. Is this an RNode with Bluetooth enabled (rnodeconf -b)? Reticulum (rnsd) may be holding it.")
            return
        }
        if let read = c.readBack {
            // A lost answer would leave the screen showing the old value: ask once what the RNode has.
            note("no answer to \(c.label), reading it back")
            queue.insert(read, at: 0)
        } else {
            note("no answer to \(c.label), moving on")
        }
        finishInflight()
    }

    private func finishInflight() {
        inflight = nil
        inflightSince = nil
        pump()
    }

    private func handle(_ frame: RNode.Frame) {
        switch frame {
        case .eeprom(let d): note("← EEPROM \(d.count) bytes")
        case .data(let d): note("← packet \(d.count) bytes")
        case .channelStats, .phyStats, .csma, .battery, .rssi, .snr, .temperature: break
        default: note("← \(frame)")
        }
        let events = session.handle(frame, now: clock())
        if let c = inflight, RNodeSession.completes(c, with: frame) { finishInflight() }
        for e in events {
            switch e {
            case .detected(false):
                fail("That's not an RNode (it didn't answer detect).")
            case .ready:
                reconnects = 0
                trace("state \(state) → ready")
                state = .ready(peripheral.map(name(for:)) ?? lastNodeName ?? "RNode")
                note("ready: \(session.productText ?? "unknown board"), fw \(session.device.firmwareVersion ?? "?")")
                updateHostConnection()
            default: break
            }
            emit(e)
        }
    }

    private func fail(_ message: String) {
        trace("fail: \"\(message)\" peripheral=\(peripheral.map(RNodeBLELog.describe) ?? "nil"); wantsReconnect off, cancelling")
        wantsReconnect = false
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(to: .failed(message))
    }

    private func reset(to newState: State) {
        trace("reset: state \(state) → \(newState) (inflight=\(inflight?.label ?? "none"), queued=\(queue.count), reconnects=\(reconnects))")
        watchdog?.invalidate()
        watchdog = nil
        peripheral = nil
        rx = nil
        queue = []
        inflight = nil
        inflightSince = nil
        connectedAt = nil
        sawFirstValue = false
        sawFirstWrite = false
        sawFirstWriteAck = false
        decoder = RNode.Decoder()
        session = RNodeSession()
        state = newState
        updateHostConnection()
    }

    /// Whether `error` is the link going away (the disconnect callback follows and may reconnect).
    nonisolated static func isLinkDrop(_ error: Error) -> Bool {
        let e = error as NSError
        guard e.domain == CBErrorDomain else { return false }
        return [CBError.connectionTimeout.rawValue, CBError.peripheralDisconnected.rawValue,
                CBError.connectionFailed.rawValue].contains(e.code)
    }

    /// Whether `error` is iOS saying the link isn't paired/encrypted (the RNode wants a PIN).
    nonisolated static func isPairingError(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == CBATTErrorDomain {
            return [CBATTError.insufficientAuthentication.rawValue, CBATTError.insufficientEncryption.rawValue,
                    CBATTError.insufficientAuthorization.rawValue, CBATTError.insufficientEncryptionKeySize.rawValue].contains(e.code)
        }
        if e.domain == CBErrorDomain {
            return e.code == CBError.peerRemovedPairingInformation.rawValue || e.code == CBError.encryptionTimedOut.rawValue
        }
        return e.localizedDescription.localizedCaseInsensitiveContains("pair")
            || e.localizedDescription.localizedCaseInsensitiveContains("authentication")
            || e.localizedDescription.localizedCaseInsensitiveContains("encryption")
    }
}

extension RNodeLink: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            trace("central state: \(RNodeBLELog.name(central.state)) authorization=\(RNodeBLELog.name(CBManager.authorization)) "
                  + "link=\(state) pending=\(String(describing: pending))")
            bluetooth = BluetoothStatus(central.state)
            switch central.state {
            case .poweredOn:
                if state == .poweredOff || state == .unauthorized { state = .idle }
                if let p = pending {
                    pending = nil
                    switch p {
                    case .scan: scan()
                    case .connect(let id): connect(id)
                    }
                }
            case .unknown, .resetting:
                break
            case .unauthorized:
                pending = nil
                state = .unauthorized
            default:
                pending = nil
                reset(to: .poweredOff)
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let cached = peripheral.name
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            if let advertised { advertisedNames[id] = advertised }
            // The scan response with the name can come after the first hit: keep a name once heard.
            let name = advertisedNames[id] ?? cached ?? "Unnamed"
            let hit = Discovered(id: id, name: name, rssi: rssi)
            trace("scan hit: \"\(name)\" \(id.uuidString) rssi=\(rssi) isRNode=\(hit.isRNode) peripheral.name=\(cached.map { "\"\($0)\"" } ?? "nil") "
                  + "state=\(RNodeBLELog.name(peripheral.state)) \(RNodeBLELog.describe(advertisement: advertisementData))")
            if let i = discovered.firstIndex(where: { $0.id == id }) {
                discovered[i].rssi = rssi
                if name != "Unnamed" { discovered[i].name = name }
            } else {
                discovered.append(hit)
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            trace("didConnect \(RNodeBLELog.describe(peripheral)) maxWrite withResponse=\(peripheral.maximumWriteValueLength(for: .withResponse)) "
                  + "withoutResponse=\(peripheral.maximumWriteValueLength(for: .withoutResponse)); state \(state) → starting; discoverServices([NUS])")
            // Before the identifier is stored: the stored name only counts for the board it belongs to.
            let shown = name(for: peripheral)
            defaults.set(peripheral.identifier.uuidString, forKey: Self.lastNodeKey)
            defaults.set(shown, forKey: Self.lastNameKey)
            wantsReconnect = true
            connectedAt = clock()
            state = .starting(shown)
            note("connected to \(shown)")
            peripheral.discoverServices([Self.serviceID])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let raw = error?.localizedDescription ?? "Could not connect."
        let staleBond = Self.isStaleBond(error)
        let remembered = peripheral.name
        MainActor.assumeIsolated {
            trace("didFailToConnect \(RNodeBLELog.describe(peripheral)) error=\(RNodeBLELog.describe(error)) "
                  + "pairingError=\(error.map(Self.isPairingError) ?? false) staleBond=\(staleBond)")
            let message: String
            if staleBond {
                // What the board advertises now, from this scan or the last connection.
                let advertised = advertisedNames[peripheral.identifier] ?? (peripheral.identifier == lastNodeID ? lastNodeName : nil)
                message = Self.staleBondHelp(remembered: remembered, advertised: advertised)
                note("iOS holds a stale bond for \(remembered ?? "this RNode"); asking to forget it")
            } else {
                message = raw
            }
            reset(to: .failed(message))
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription
        let pairing = error.map(Self.isPairingError) ?? false
        let staleBond = Self.isStaleBond(error)
        let remembered = peripheral.name
        MainActor.assumeIsolated {
            let ours = self.peripheral?.identifier == peripheral.identifier
            let wasReady = state.isReady
            let justConnected = connectedAt.map { clock().timeIntervalSince($0) < 20 } ?? false
            trace("didDisconnectPeripheral \(RNodeBLELog.describe(peripheral)) error=\(RNodeBLELog.describe(error)) "
                  + "pairingError=\(pairing) linkDrop=\(error.map(Self.isLinkDrop) ?? false) ours=\(ours) link=\(state) wasReady=\(wasReady) "
                  + "connectedFor=\(connectedAt.map { String(format: "%.1fs", clock().timeIntervalSince($0)) } ?? "-") "
                  + "pairedAt=\(pairedAt.map { "\($0)" } ?? "never") wantsReconnect=\(wantsReconnect) reconnects=\(reconnects)/\(Self.maxReconnects)")
            guard ours else { trace("not our peripheral, ignoring"); return }
            note("disconnected" + (message.map { ": \($0)" } ?? ""))
            if pairing {
                trace("pairing-class error: giving up with \(staleBond ? "staleBondHelp" : "pairingHelp"), wantsReconnect off")
                // The same stale bond can show up after the connect, when iOS turns encryption on.
                let advertised = advertisedNames[peripheral.identifier] ?? (peripheral.identifier == lastNodeID ? lastNodeName : nil)
                reset(to: .failed(staleBond ? Self.staleBondHelp(remembered: remembered, advertised: advertised) : Self.pairingHelp))
                wantsReconnect = false
                return
            }
            // The firmware drops the link once after a successful pairing; a lost link is worth
            // a few tries too. Then it's on the user.
            if wantsReconnect, reconnects < Self.maxReconnects {
                reconnects += 1
                let why = justConnected && !wasReady ? "paired or dropped during startup" : "link lost"
                note("\(why), reconnecting (\(reconnects)/\(Self.maxReconnects))")
                reset(to: .connecting(name(for: peripheral)))
                trace("reconnect \(reconnects) scheduled in 1.5 s")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard let self else { return }
                    guard case .connecting = self.state, self.peripheral == nil else {
                        self.trace("reconnect \(self.reconnects) skipped: state=\(self.state) peripheral=\(self.peripheral.map(RNodeBLELog.describe) ?? "nil")")
                        return
                    }
                    self.begin(peripheral, how: "reconnect \(self.reconnects)/\(Self.maxReconnects) with the peripheral from didDisconnect")
                }
                return
            }
            trace("not reconnecting (wantsReconnect=\(wantsReconnect), reconnects=\(reconnects))")
            reset(to: message.map { .failed($0) } ?? .idle)
        }
    }
}

extension RNodeLink: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            let nus = services.first(where: { $0.uuid == Self.serviceID })
            trace("didDiscoverServices \(RNodeBLELog.describe(peripheral)) error=\(RNodeBLELog.describe(error)) "
                  + "services=[\(services.map { "\($0.uuid.uuidString)\($0.isPrimary ? "" : "(secondary)")" }.joined(separator: ", "))] NUS=\(nus != nil)")
            guard let s = nus else {
                fail("No UART service: that's not an RNode.")
                return
            }
            trace("discoverCharacteristics([RX, TX]) for NUS")
            peripheral.discoverCharacteristics([Self.rxID, Self.txID], for: s)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let chars = service.characteristics ?? []
            rx = chars.first { $0.uuid == Self.rxID }
            let tx = chars.first(where: { $0.uuid == Self.txID })
            trace("didDiscoverCharacteristics for \(service.uuid.uuidString) error=\(RNodeBLELog.describe(error)) "
                  + "[\(chars.map { "\($0.uuid.uuidString) \(RNodeBLELog.describe($0.properties)) isNotifying=\($0.isNotifying)" }.joined(separator: "; "))] "
                  + "RX(write)=\(rx.map { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) } ?? false) "
                  + "TX(notify)=\(tx.map { $0.properties.contains(.notify) || $0.properties.contains(.indicate) } ?? false)")
            guard rx != nil, let tx else {
                fail("The device didn't offer the UART RX/TX characteristics.")
                return
            }
            // The RNode's characteristics need an encrypted, PIN-paired link: iOS pairs here.
            trace("setNotifyValue(true) for TX \(tx.uuid.uuidString); peripheral state=\(RNodeBLELog.name(peripheral.state)) — iOS pairs now if the RNode asks")
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let pairing = error.map(Self.isPairingError) ?? false
        let dropped = error.map(Self.isLinkDrop) ?? false
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            trace("didUpdateNotificationState \(characteristic.uuid.uuidString) isNotifying=\(characteristic.isNotifying) "
                  + "error=\(RNodeBLELog.describe(error)) pairingError=\(pairing) linkDrop=\(dropped) peripheral state=\(RNodeBLELog.name(peripheral.state))")
            if let message {
                note("subscribe failed: \(message)")
                if pairing {
                    fail(Self.pairingHelp)
                } else if dropped || peripheral.state != .connected {
                    // The firmware drops the link right after a first pairing: the disconnect
                    // callback reconnects, so this isn't the end.
                    trace("subscribe failed because the link dropped; waiting for didDisconnect")
                } else {
                    fail("Couldn't subscribe: \(message)")
                }
                return
            }
            guard characteristic.uuid == Self.txID, characteristic.isNotifying else {
                trace("not the TX subscription we wanted (uuid match=\(characteristic.uuid == Self.txID)), ignoring")
                return
            }
            pairedAt = clock()
            trace("subscribed to TX: the link is encrypted/paired as far as iOS is concerned; starting the session")
            note("subscribed; max write \(peripheral.maximumWriteValueLength(for: .withoutResponse)) without response")
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkTimeout() }
            }
            startSession()
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { flushHostWrites() }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if hostAwaitingAck {
                hostAwaitingAck = false
                flushHostWrites()
            }
            if let message {
                trace("didWriteValue \(characteristic.uuid.uuidString) error=\(RNodeBLELog.describe(error)) "
                      + "pairingError=\(error.map(Self.isPairingError) ?? false) inflight=\(inflight?.label ?? "none")")
                note("write failed: \(message)")
                finishInflight()
            } else if !sawFirstWriteAck {
                sawFirstWriteAck = true
                trace("didWriteValue \(characteristic.uuid.uuidString): first write acknowledged, no error (later ones aren't logged)")
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value ?? Data()
        MainActor.assumeIsolated {
            if let error {
                trace("didUpdateValue \(characteristic.uuid.uuidString) error=\(RNodeBLELog.describe(error)) "
                      + "pairingError=\(Self.isPairingError(error)) \(value.count) bytes")
            } else if !sawFirstValue {
                sawFirstValue = true
                trace("didUpdateValue \(characteristic.uuid.uuidString): first notification, \(value.count) bytes (later ones aren't logged)")
            }
            guard error == nil, characteristic.uuid == Self.txID, !value.isEmpty else { return }
            receive(value)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            trace("didModifyServices \(RNodeBLELog.describe(peripheral)) invalidated=[\(invalidatedServices.map(\.uuid.uuidString).joined(separator: ", "))]")
        }
    }

    nonisolated public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        MainActor.assumeIsolated { trace("didUpdateName \(RNodeBLELog.describe(peripheral))") }
    }
}
#endif
