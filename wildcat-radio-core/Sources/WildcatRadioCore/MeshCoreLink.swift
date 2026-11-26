#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import Observation

/// The phone's Bluetooth link to its own MeshCore companion node. Sends one
/// command at a time (the protocol's rule), matches each answer, and keeps
/// pulling messages whenever the node says some are waiting.
@MainActor
@Observable
public final class MeshCoreLink: NSObject {
    public enum State: Equatable, Sendable {
        case poweredOff, unauthorized, idle, scanning
        case connecting(String)
        case syncing(String)
        case ready(String)
        case failed(String)

        public var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    public struct Discovered: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var rssi: Int
    }

    static let serviceID = CBUUID(string: MeshCore.service)
    static let rxID = CBUUID(string: MeshCore.rx)
    static let txID = CBUUID(string: MeshCore.tx)
    static let lastNodeKey = "meshcore.lastNode"
    static let timeout: TimeInterval = 5

    public private(set) var state: State = .idle
    public private(set) var discovered: [Discovered] = []
    public private(set) var session = MeshCoreSession()
    /// Running the pretend practice node (no radio).
    public private(set) var isDemo = false
    public var onEvent: ((MeshCoreSession.Event) -> Void)?
    @ObservationIgnored private var listeners: [(MeshCoreSession.Event) -> Void] = []
    /// Several parts of the app can listen (chat, bridge, hunts).
    public func addListener(_ l: @escaping (MeshCoreSession.Event) -> Void) { listeners.append(l) }
    private func emit(_ e: MeshCoreSession.Event) {
        onEvent?(e)
        for l in listeners { l(e) }
    }
    public var onDiagnostic: ((String) -> Void)?

    /// The phone's Bluetooth for this link (`.notStarted` until it's first needed).
    public private(set) var bluetooth: BluetoothStatus = .notStarted

    /// Created on first use (Find, Connect, Reconnect, or a saved auto-reconnect),
    /// so a fresh install sees no Bluetooth prompt at launch.
    @ObservationIgnored private var central: CBCentralManager?
    /// What to do once Bluetooth reports it's on (a tap that came before it was ready).
    @ObservationIgnored private var pending: Pending?
    private enum Pending { case scan, connect(UUID) }
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var rx: CBCharacteristic?
    @ObservationIgnored private(set) var queue: [MeshCore.Command] = []
    @ObservationIgnored private(set) var inflight: MeshCore.Command?
    @ObservationIgnored private var inflightSince: Date?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var startupLeft = 0
    @ObservationIgnored private let defaults: UserDefaults
    /// The pretend node's traffic while practising, and its clock.
    @ObservationIgnored private var practice: MeshCorePractice?
    @ObservationIgnored private var practiceTimer: Timer?
    /// The link's clock (tests set their own; the timers only decide how often it's read).
    @ObservationIgnored public var clock: () -> Date = { Date() }
    /// Tests put a pretend node here: it gets each command's bytes in place of the
    /// Bluetooth write, and answers through `receive`.
    @ObservationIgnored var wire: ((Data) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if BluetoothStatus.isDenied {
            bluetooth = .unauthorized
            state = .unauthorized
        } else if wantsReconnect, lastNodeID != nil {
            // Connected before, so Bluetooth is already allowed: bring the node back.
            startBluetooth()
        }
    }

    /// Creates the Bluetooth manager (iOS asks for permission the first time).
    public func startBluetooth() {
        guard central == nil else { return }
        bluetooth = .starting
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// The manager when Bluetooth is on; otherwise starts it and remembers `then` for when it is.
    private func poweredOn(else then: Pending) -> CBCentralManager? {
        startBluetooth()
        if let central, central.state == .poweredOn { return central }
        pending = then
        return nil
    }

    private func note(_ s: String) { onDiagnostic?("MeshCore " + s) }

    /// Reconnect by itself: on by connecting, off by tapping Disconnect.
    public var wantsReconnect: Bool {
        get { defaults.bool(forKey: "meshcore.autoReconnect") }
        set { defaults.set(newValue, forKey: "meshcore.autoReconnect") }
    }

    public var lastNodeID: UUID? { defaults.string(forKey: Self.lastNodeKey).flatMap(UUID.init(uuidString:)) }

    // MARK: Control

    /// Looks for nodes; if Bluetooth is still starting, it scans as soon as it's on.
    public func scan() {
        guard let central = poweredOn(else: .scan) else { return }
        discovered = []
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceID], options: nil)
    }

    public func stopScan() {
        if case .scan = pending { pending = nil }
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    public func connect(_ id: UUID) {
        guard let central = poweredOn(else: .connect(id)) else { return }
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            state = .failed("Node not found. Scan again.")
            return
        }
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting(p.name ?? "MeshCore")
        central.connect(p, options: nil)
    }

    public func reconnectLast() {
        if let id = lastNodeID { connect(id) }
    }

    /// A pretend node for practice, App Review and screenshots, its made-up mesh
    /// placed around `center` (the phone's last position; nil: a public park).
    /// `timer: false` leaves the clock to the caller's `tick()` (tests).
    public func startDemo(center: Coordinate? = nil, timer: Bool = true) {
        pending = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(to: .idle)
        let now = clock()
        session = MeshCoreSession.demo(now: now, center: center)
        session.keepsRaw = keepsRawPackets
        isDemo = true
        state = .ready("Practice Node")
        emit(.ready)
        practice = MeshCorePractice(now: now, center: center)
        guard timer else { return }
        practiceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Practice: where the player is now (the practice fox's signal follows it).
    /// Without it the hunt pretends you walk towards the fox once you ping it.
    public func setPracticeLocation(_ c: Coordinate?) { practice?.walker = c }

    /// The practice node's hidden fox (a repeater to hunt), while practising.
    public var practiceFox: MeshCore.Contact? {
        isDemo ? session.contacts[MeshCorePractice.key(MeshCorePractice.fox.byte)] : nil
    }

    /// One second of the link's life: the practice node's traffic, and direct
    /// messages that need sending again or giving up. The timers call it.
    public func tick() {
        if isDemo, var p = practice {
            let frames = p.step(now: clock(), session: session)
            practice = p
            for f in frames { process(f) }
        }
        let (events, follow) = session.tick(now: clock())
        for e in events { emit(e) }
        for c in follow { enqueue(c) }
    }

    public func disconnect() {
        if !isDemo { wantsReconnect = false }
        pending = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(to: .idle)
    }

    /// Sends a text to a channel (0 = Public); returns the chat it made. The chat and
    /// the packet carry the same timestamp, which is how its repeats are recognised.
    @discardableResult
    public func send(text: String, channel: Int) -> UUID {
        let t = text.utf8Prefix(MeshCore.maxTextBytes)
        let now = Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
        let id = session.sent(t, to: .channel(channel), at: now)
        enqueue(.sendChannelText(channel: channel, text: t, at: now))
        return id
    }

    /// Sends a direct message to a contact (adding it to the node first if it was only
    /// heard). Its chat's `delivery` follows it: `.delivery` events report sending again,
    /// on air, delivered or failed; unconfirmed sends are retried, the last by flood.
    @discardableResult
    public func send(text: String, to contact: MeshCore.Contact) -> UUID {
        let t = text.utf8Prefix(MeshCore.maxTextBytes)
        let now = clock()
        let at = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let (id, commands) = session.sendDirect(t, to: contact, at: at, now: now)
        for c in commands { enqueue(c) }
        return id
    }

    /// Puts a contact in the node's own table (CMD_ADD_UPDATE_CONTACT): for someone
    /// only heard while auto-add is off. Direct messages do it by themselves.
    public func addContact(_ c: MeshCore.Contact) { enqueue(.addContact(c)) }

    /// Marks a sent chat as a line the bridge carried over (and from where).
    public func setBridged(_ origin: BridgeOrigin, on id: UUID) { session.setBridged(origin, on: id) }

    /// Keep each message's raw packet (a debug setting; saves get bigger).
    public var keepsRawPackets = false {
        didSet { session.keepsRaw = keepsRawPackets }
    }

    /// Creates a private channel with a fresh random key in the first free slot (1-7).
    @discardableResult
    public func addChannel(named name: String, secret given: Data? = nil) -> Int? {
        guard let i = (1..<max(session.device?.maxChannels ?? 8, 2)).first(where: { session.channels[$0] == nil }) else { return nil }
        var secret = Data(count: 16)
        for k in 0..<16 { secret[k] = UInt8.random(in: 0...255) }
        if let given, given.count == 16 { secret = given }
        enqueue(.setChannel(index: i, name: name, secret: secret))
        enqueue(.getChannel(index: i))
        return i
    }

    /// Clears a channel slot.
    public func deleteChannel(_ index: Int) {
        guard index > 0 else { return }
        session.forget(channel: index)
        enqueue(.setChannel(index: index, name: "", secret: Data(count: 16)))
    }

    // MARK: Settings (each re-reads the node's info after)

    public func rename(_ name: String) { enqueue(.setName(name)); refreshSelf() }
    public func setRadio(frequency: Double, bandwidth: Double, spreadingFactor: Int, codingRate: Int) {
        enqueue(.setRadio(frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate))
        refreshSelf()
    }
    public func setTxPower(_ dbm: Int) { enqueue(.setTxPower(dbm)); refreshSelf() }
    public func setPosition(_ c: Coordinate) { enqueue(.setPosition(c)); refreshSelf() }
    public func setSharesPosition(_ on: Bool) { setOther { $0.advertLocationPolicy = on ? 1 : 0 } }
    public func setAutoAddContacts(_ on: Bool) { setOther { $0.manualAddContacts = on ? ($0.manualAddContacts & ~1) : ($0.manualAddContacts | 1) } }
    public func removeContact(_ c: MeshCore.Contact) { session.forget(contact: c.publicKey); enqueue(.removeContact(publicKey: c.publicKey)) }
    public func resetPath(_ c: MeshCore.Contact) { enqueue(.resetPath(publicKey: c.publicKey)); enqueue(.getContacts) }
    public func reboot() { enqueue(.reboot) }

    // MARK: Repeaters

    public func login(_ c: MeshCore.Contact, password: String) { enqueue(.login(publicKey: c.publicKey, password: password)) }
    public func logout(_ c: MeshCore.Contact) { enqueue(.logout(publicKey: c.publicKey)) }
    public func requestStatus(_ c: MeshCore.Contact) { enqueue(.statusRequest(publicKey: c.publicKey)) }
    /// Floods a binary datagram on a channel (e.g. a Wildcat Geo Gift). False when too big.
    @discardableResult
    public func sendData(_ payload: Data, channel: Int, dataType: UInt16 = MeshCore.wildcatDataType) -> Bool {
        guard payload.count <= MeshCore.maxChannelData else { return false }
        enqueue(.sendChannelData(channel: channel, dataType: dataType, payload: payload))
        return true
    }

    /// Traces the route to a repeater or room server; returns the tag its `.trace` result carries.
    @discardableResult
    public func trace(_ c: MeshCore.Contact) -> UInt32? {
        guard let hashes = MeshCore.tracePath(to: c) else { return nil }
        let tag = UInt32.random(in: 1...UInt32.max)
        enqueue(.trace(tag: tag, hashes: hashes))
        return tag
    }

    /// Sends a CLI command; the reply arrives as a chat with textType 1 from that contact.
    public func remoteCommand(_ c: MeshCore.Contact, _ command: String) {
        var chat = MeshCoreSession.Chat(id: UUID(), direction: .sent, origin: .contact(c.prefix), text: command, at: Date())
        chat.textType = 1
        session.appendChat(chat)
        enqueue(.remoteCommand(to: c.prefix, command: command, at: Date()))
    }
    /// Bluetooth PIN (6 digits; 0 = the firmware's default behaviour).
    public func setPIN(_ pin: UInt32) { enqueue(.setPIN(pin)) }
    public func refreshSelf() { enqueue(.appStart(name: "Wildcat")) }

    private func setOther(_ change: (inout MeshCore.SelfInfo) -> Void) {
        guard var me = session.me else { return }
        change(&me)
        enqueue(.setOtherParams(manualAddContacts: me.manualAddContacts, telemetryModes: me.telemetryModes,
                                advertLocationPolicy: me.advertLocationPolicy, multiAcks: me.multiAcks))
        refreshSelf()
    }

    /// Restores saved chats and contacts into the live session (after `.ready`).
    public func restore(chats: [MeshCoreSession.Chat], contacts: [MeshCore.Contact]) {
        session.restore(chats: chats, contacts: contacts)
    }

    public func advertise(flood: Bool = true) { enqueue(.sendSelfAdvert(flood: flood)) }
    public func refreshBattery() { enqueue(.getBatteryAndStorage) }

    // MARK: Queue

    public func enqueue(_ c: MeshCore.Command) {
        if isDemo {
            // The practice node answers like a real one (nothing goes on air).
            guard var p = practice else { return }
            let frames = p.command(c, session: session, now: clock())
            practice = p
            var answered = false
            for f in frames {
                if !answered, MeshCoreSession.completes(c, with: f) {
                    answered = true
                    answer(c, with: f)
                }
                process(f)
            }
            return
        }
        queue.append(c)
        pump()
    }

    private func pump() {
        guard inflight == nil, !queue.isEmpty, let write = writer else { return }
        let c = queue.removeFirst()
        inflight = c
        inflightSince = Date()
        note("→ \(c.label) (\(c.data.count) bytes)")
        write(c.data)
    }

    /// Where a command's bytes go: the node's RX characteristic, or a test's `wire`.
    private var writer: ((Data) -> Void)? {
        if let wire { return wire }
        guard let peripheral, let rx else { return nil }
        return { peripheral.writeValue($0, for: rx, type: .withResponse) }
    }

    /// A frame's bytes from the node (tests; Bluetooth notifications come in the same way).
    func receive(_ data: Data) { handle(data) }

    private func finishInflight() {
        inflight = nil
        inflightSince = nil
        if startupLeft > 0 {
            startupLeft -= 1
            if startupLeft == 0 {
                session.markReady()
                state = .ready(session.me?.name.nonEmpty ?? peripheral?.name ?? "MeshCore")
                note("ready: \(session.contacts.count) contacts, \(session.channels.count) channels")
                emit(.ready)
            }
        }
        pump()
    }

    /// Applies the node's answer to `command` (contacts added, a direct message's ack)
    /// and sends whatever it calls for.
    private func answer(_ command: MeshCore.Command, with frame: MeshCore.Frame) {
        let (events, follow) = session.answered(command, with: frame, now: clock())
        for e in events { emit(e) }
        for c in follow { enqueue(c) }
    }

    private func checkTimeout() {
        guard let since = inflightSince, Date().timeIntervalSince(since) > Self.timeout else { return }
        note("no answer to \(inflight.map { String(describing: $0) } ?? "?"), moving on")
        finishInflight()
    }

    private func reset(to newState: State) {
        isDemo = false
        practiceTimer?.invalidate()
        practiceTimer = nil
        practice = nil
        watchdog?.invalidate()
        watchdog = nil
        peripheral = nil
        rx = nil
        queue = []
        inflight = nil
        inflightSince = nil
        startupLeft = 0
        session = MeshCoreSession()
        session.keepsRaw = keepsRawPackets
        state = newState
    }

    private func handle(_ data: Data) {
        guard let frame = try? MeshCore.decode(data) else {
            note("undecodable frame \(data.prefix(1).map { String(format: "%02x", $0) }.joined())")
            return
        }
        switch frame {
        case .error(let code): note("← error \(code.map(String.init) ?? "?") for \(inflight?.label ?? "?")")
        case .ok: note("← ok")
        case .rxLog, .contact, .contactsStart, .advert: break   // every advert heard: too many to log
        case .message: note("← message")
        case .channelInfo(let i, let name, _): note("← channel \(i) \(name.isEmpty ? "(empty)" : name)")
        case .selfInfo(let s): note("← self info \(s.name)")
        case .deviceInfo(let d): note("← device \(d.version)")
        case .endOfContacts: note("← \(session.contacts.count) contacts")
        default: note("← frame \(data.first.map { String(format: "0x%02x", $0) } ?? "?")")
        }
        process(frame)
    }

    /// Applies a frame from the node (or the practice node) and follows it up.
    private func process(_ frame: MeshCore.Frame) {
        let (events, follow) = session.handle(frame, now: clock())
        if isDemo, events.contains(where: { if case .message = $0 { return true } else { return false } }) {
            session.trimChats(keepingPerConversation: MeshCorePractice.keepPerChat)
        }
        for e in events { emit(e) }
        if isDemo { return }   // no queue: the practice node answers at once
        // Follow-ups repeat nothing queued or in flight, except that a frame answering
        // the command in flight finishes it: the next sync after a message answered a
        // sync must go out, or the rest of the node's queue waits for its next push.
        let done = inflight.flatMap { MeshCoreSession.completes($0, with: frame) ? $0 : nil }
        for c in follow where !(queue.contains(c) || (done == nil && inflight == c)) { queue.append(c) }
        if let c = done {
            answer(c, with: frame)
            finishInflight()
        } else {
            pump()
        }
    }
}

extension MeshCoreLink: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
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
                } else if wantsReconnect, peripheral == nil, state == .idle || { if case .failed = state { return true } else { return false } }() {
                    reconnectLast()
                }
            case .unknown, .resetting:
                break   // wait for a real answer; keep any pending tap
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
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "MeshCore"
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            if let i = discovered.firstIndex(where: { $0.id == id }) { discovered[i].rssi = rssi }
            else { discovered.append(Discovered(id: id, name: name, rssi: rssi)) }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            defaults.set(peripheral.identifier.uuidString, forKey: Self.lastNodeKey)
            wantsReconnect = true
            state = .syncing(peripheral.name ?? "MeshCore")
            note("connected")
            peripheral.discoverServices([Self.serviceID])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Could not connect."
        MainActor.assumeIsolated { reset(to: .failed(message)) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
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

extension MeshCoreLink: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
                reset(to: .failed("Not a MeshCore companion node."))
                return
            }
            peripheral.discoverCharacteristics([Self.rxID, Self.txID], for: s)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let chars = service.characteristics ?? []
            rx = chars.first { $0.uuid == Self.rxID }
            guard rx != nil, let tx = chars.first(where: { $0.uuid == Self.txID }) else {
                reset(to: .failed("The node didn't offer MeshCore's RX/TX characteristics."))
                return
            }
            // Pairing (the PIN prompt) happens here if the node requires it.
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message {
                reset(to: .failed("Couldn't subscribe: \(message). If asked for a PIN, try 123456."))
                return
            }
            guard characteristic.uuid == Self.txID, characteristic.isNotifying else { return }
            note("max write: \(peripheral.maximumWriteValueLength(for: .withResponse)) with response, \(peripheral.maximumWriteValueLength(for: .withoutResponse)) without")
            let steps = MeshCoreSession.startup()
            startupLeft = steps.count
            queue = steps + queue
            // A second subscribe (re-pairing) must not leave the first timer running.
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkTimeout()
                    self?.tick()
                }
            }
            pump()
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message {
                note("write failed: \(message)")
                finishInflight()
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value ?? Data()
        MainActor.assumeIsolated {
            guard error == nil, characteristic.uuid == Self.txID, !value.isEmpty else { return }
            handle(value)
        }
    }
}
#endif
