#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import Observation

/// The phone's Bluetooth link to its own Meshtastic node (one BLE client per
/// node). Follows the Meshtastic phone API: subscribe to FromNum, write
/// `want_config`, then read FromRadio until it comes back empty, again after
/// every FromNum notification.
@MainActor
@Observable
public final class MeshLink: NSObject {
    public enum State: Equatable, Sendable {
        case poweredOff
        case unauthorized
        case idle
        case scanning
        case connecting(String)
        /// Connected, downloading the node's config.
        case configuring(String)
        case ready(String)
        case failed(String)

        public var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    public struct Discovered: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var rssi: Int
    }

    public static let service = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    static let toRadio = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
    static let fromRadio = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
    /// FromRadio on older firmware.
    static let legacyFromRadio = CBUUID(string: "8BA2BCC2-EE02-4A55-A531-C525C5E454D5")
    static let fromNum = CBUUID(string: "ED9DA18B-2D0B-4A1B-9B4B-6FF5D6E2BA0F")
    /// FromNum as newer firmware lists it (read + notify), seen on a 2026 node.
    static let fromNumV2 = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")
    static let lastNodeKey = "meshlink.lastNode"

    public private(set) var state: State = .idle
    public private(set) var discovered: [Discovered] = []
    public private(set) var session = MeshSession()
    /// Every event, in order (packets, ready, my node). Set by the app.
    public var onEvent: ((MeshSession.Event) -> Void)?
    /// Each connection step, for the app's log ("services: …", errors).
    public var onDiagnostic: ((String) -> Void)?

    private func note(_ s: String) { onDiagnostic?("BLE " + s) }

    /// The phone's Bluetooth for this link.
    public private(set) var bluetooth: BluetoothStatus = .starting

    @ObservationIgnored private var central: CBCentralManager!
    /// A Find or Reconnect tap that came before Bluetooth said it was on.
    @ObservationIgnored private var pendingScan = false
    @ObservationIgnored private var pendingReconnect = false
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private var fromRadio: CBCharacteristic?
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var drainAgain = false
    /// Without a FromNum characteristic, FromRadio is polled instead.
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Reconnect by itself: on by connecting, off by tapping Disconnect.
    public var wantsReconnect: Bool {
        get { defaults.bool(forKey: "meshlink.autoReconnect") }
        set { defaults.set(newValue, forKey: "meshlink.autoReconnect") }
    }

    public var lastNodeID: UUID? {
        defaults.string(forKey: Self.lastNodeKey).flatMap(UUID.init(uuidString:))
    }

    // MARK: Control

    /// Looks for nodes; if Bluetooth is still starting, it scans as soon as it's on.
    public func scan() {
        guard central.state == .poweredOn else { pendingScan = true; return }
        pendingScan = false
        discovered = []
        state = .scanning
        central.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    public func stopScan() {
        pendingScan = false
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    public func connect(_ id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            state = .failed("Node not found. Scan again.")
            return
        }
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting(p.name ?? "Node")
        note("connecting \(p.name ?? id.uuidString)")
        central.connect(p, options: nil)
    }

    /// Reconnects the node used last time, if any.
    public func reconnectLast() {
        guard let id = lastNodeID else { return }
        guard central.state == .poweredOn else { pendingReconnect = true; return }
        pendingReconnect = false
        connect(id)
    }

    public func disconnect() {
        wantsReconnect = false
        pendingScan = false
        pendingReconnect = false
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        reset(to: .idle)
    }

    /// Sends a text on `channel`, to a node for a direct message. Returns the
    /// packet id its ack/nak will carry as `requestID` (nil when not ready).
    @discardableResult
    public func send(text: String, to: NodeNum = .broadcast, channel: Int, replyID: UInt32? = nil,
                     isReaction: Bool = false) -> UInt32? {
        guard let peripheral, let toRadio, state.isReady else { return nil }
        let id = MeshCodec.newPacketID()
        let bytes = MeshCodec.textPacket(text.utf8Prefix(MeshCodec.maxTextBytes),
                                         to: to, channel: channel, id: id, replyID: replyID, isReaction: isReaction)
        peripheral.writeValue(bytes, for: toRadio, type: .withResponse)
        return id
    }

    /// Sends an app payload (PRIVATE_APP); returns its packet id.
    @discardableResult
    public func sendPrivate(_ payload: Data, to: NodeNum = .broadcast, channel: Int) -> UInt32? {
        guard let peripheral, let toRadio, state.isReady else { return nil }
        let id = MeshCodec.newPacketID()
        peripheral.writeValue(MeshCodec.privatePacket(payload, to: to, channel: channel, id: id), for: toRadio, type: .withResponse)
        return id
    }

    /// Sends an already encoded ToRadio frame (e.g. `MeshCodec.positionPacket`).
    public func send(toRadio bytes: Data) {
        guard let peripheral, let toRadio, state.isReady else { return }
        peripheral.writeValue(bytes, for: toRadio, type: .withResponse)
    }

    /// Updates what we know about the node after sending a change.
    public func updateSession(_ change: (inout MeshSession) -> Void) { change(&session) }

    /// Downloads the node's configuration again (after settings changes).
    public func resync() {
        guard let peripheral, let toRadio, state.isReady else { return }
        let keep = (session.passkey, session.passkeyTime)
        session = MeshSession()
        if let k = keep.0, let t = keep.1 { session.storePasskey(k, at: t) }
        state = .configuring(peripheral.name ?? "Node")
        note("resync")
        peripheral.writeValue(session.wantConfig, for: toRadio, type: .withResponse)
    }

    private func reset(to newState: State) {
        poll?.invalidate()
        poll = nil
        peripheral = nil
        toRadio = nil
        fromRadio = nil
        draining = false
        drainAgain = false
        session = MeshSession()
        state = newState
    }

    private func drain() {
        guard let peripheral, let fromRadio else { return }
        if draining {
            drainAgain = true
            return
        }
        draining = true
        peripheral.readValue(for: fromRadio)
    }

    private func handle(frame data: Data) {
        guard let frame = try? MeshCodec.decodeFromRadio(data) else { return }
        guard let event = session.handle(frame) else { return }
        if event == .ready {
            note("ready: \(session.nodes.count) nodes, \(session.channels.count) channels")
            state = .ready(peripheral?.name ?? "Node")
        }
        onEvent?(event)
    }
}

extension MeshLink: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetooth = BluetoothStatus(central.state)
            switch central.state {
            case .poweredOn:
                if state == .poweredOff || state == .unauthorized { state = .idle }
                if (pendingReconnect || wantsReconnect), peripheral == nil,
                   state == .idle || { if case .failed = state { return true } else { return false } }() {
                    reconnectLast()
                } else if pendingScan, peripheral == nil {
                    scan()
                }
                pendingScan = false
                pendingReconnect = false
            case .unknown, .resetting:
                break   // wait for a real answer; keep any pending tap
            case .unauthorized:
                pendingScan = false
                pendingReconnect = false
                state = .unauthorized
            default:
                pendingScan = false
                pendingReconnect = false
                reset(to: .poweredOff)
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Meshtastic"
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            if let i = discovered.firstIndex(where: { $0.id == id }) {
                discovered[i].rssi = rssi
            } else {
                discovered.append(Discovered(id: id, name: name, rssi: rssi))
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            defaults.set(peripheral.identifier.uuidString, forKey: Self.lastNodeKey)
            wantsReconnect = true
            state = .configuring(peripheral.name ?? "Node")
            note("connected, discovering services")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                           error: Error?) {
        let message = error?.localizedDescription ?? "Could not connect."
        MainActor.assumeIsolated {
            note("connect failed: \(message)")
            reset(to: .failed(message))
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                           error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == peripheral.identifier else { return }
            note("disconnected" + (message.map { ": \($0)" } ?? ""))
            reset(to: message.map { .failed($0) } ?? .idle)
            // Dropped (range, reboot), not a tap on Disconnect: wait for it to come back.
            if wantsReconnect {
                note("will reconnect when it's back in range")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.reconnectLast()
                }
            }
        }
    }
}

extension MeshLink: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            note("services: " + (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ", ")
                 + (message.map { " error: \($0)" } ?? ""))
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
                reset(to: .failed("Not a Meshtastic node."))
                return
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                       error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            let chars = service.characteristics ?? []
            note("characteristics: " + chars.map { "\($0.uuid.uuidString) [\($0.properties.rawValue)]" }.joined(separator: ", ")
                 + (message.map { " error: \($0)" } ?? ""))
            toRadio = chars.first { $0.uuid == Self.toRadio }
            fromRadio = chars.first { $0.uuid == Self.fromRadio } ?? chars.first { $0.uuid == Self.legacyFromRadio }
            let num = chars.first(where: { $0.uuid == Self.fromNum })
                ?? chars.first(where: { $0.uuid == Self.fromNumV2 && $0.properties.contains(.notify) })
            guard let toRadio, fromRadio != nil else {
                var missing: [String] = []
                if toRadio == nil { missing.append("ToRadio") }
                if fromRadio == nil { missing.append("FromRadio") }
                reset(to: .failed("The node didn't offer " + missing.joined(separator: ", ")
                                  + (message.map { " (\($0))" } ?? "") + ". Details in the Log tab."))
                return
            }
            if let num {
                peripheral.setNotifyValue(true, for: num)
            } else {
                // Some firmware doesn't list FromNum: ask for new frames every second.
                note("no FromNum; polling FromRadio every second")
                poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.drain() }
                }
            }
            peripheral.writeValue(session.wantConfig, for: toRadio, type: .withResponse)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message { note("write failed: \(message)") }
            // After want_config (and after each sent packet) there is data to read.
            if characteristic.uuid == Self.toRadio { drain() }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        let uuid = characteristic.uuid
        let value = characteristic.value ?? Data()
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message {
                note("read failed: \(message)")
                if uuid == fromRadio?.uuid { draining = false }
                return
            }
            if uuid == Self.fromNum || uuid == Self.fromNumV2 {
                drain()
            } else if uuid == fromRadio?.uuid {
                if value.isEmpty {
                    // Drained. Go again if a FromNum arrived meanwhile.
                    draining = false
                    if drainAgain {
                        drainAgain = false
                        drain()
                    }
                } else {
                    handle(frame: value)
                    if let fromRadio { peripheral.readValue(for: fromRadio) }
                }
            }
        }
    }
}
#endif
