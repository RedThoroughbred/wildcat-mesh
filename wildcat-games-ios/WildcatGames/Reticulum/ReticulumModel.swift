import Foundation
import Observation
import UserNotifications
import WildcatRadioCore
#if canImport(Darwin)
import Darwin
#endif

/// Reticulum (beta) in the app: the real RNS + LXMF stack running in the embedded Python
/// (ReticulumRuntime), reached through the RNode's Bluetooth link. Start and stop it, announce, see
/// who announced, exchange messages. The rules (what may start, what is kept, how an event reads)
/// are the core's `Reticulum`; this class wires them to Python, the Keychain, the save file and
/// the block list.
@MainActor
@Observable
final class ReticulumModel {
    /// One per process, like Reticulum itself.
    static let shared = ReticulumModel()

    enum Phase: Equatable {
        case idle, launching, starting, running, stopped

        var word: String {
            switch self {
            case .idle: return "Not started"
            case .launching: return "Starting Python…"
            case .starting: return "Starting Reticulum…"
            case .running: return "Running"
            case .stopped: return "Stopped"
            }
        }
        var isBusy: Bool { self == .launching || self == .starting }
    }

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var address: String?
    private(set) var identityHash: String?
    private(set) var versions: String?
    private(set) var interfaces: [Reticulum.InterfaceState] = []
    /// The people heard and every conversation: saved (see `bookURL`).
    private(set) var book = Reticulum.Book()
    private(set) var log: [String] = []
    private(set) var lastAnnounce: Date?
    private(set) var lastHeartbeat: Date?
    private(set) var heartbeats: [Date] = []
    /// Why the last start didn't happen, in plain words.
    private(set) var lastStartError: String?
    /// Where the identity key lives this run.
    private(set) var identityStore = "—"
    /// The settings the running Reticulum was started with.
    private(set) var radio: Reticulum.RadioSettings?

    // Settings for the next start.
    var displayName: String {
        didSet { if !isSample { defaults.set(displayName, forKey: Self.displayNameKey) } }
    }
    /// The name the running stack announces: the first start's, until the app is reopened.
    private(set) var announcedName: String?
    /// Off only in the simulator test, which has no RNode: a connected RNode otherwise always takes part.
    var useRNode = true
    /// The internet link: a Reticulum node the person typed the address of (RNS's TCP client
    /// interface). Off until they turn it on; Wildcat ships no addresses.
    var internetOn: Bool {
        didSet { if !isSample { defaults.set(internetOn, forKey: Self.internetOnKey) } }
    }
    var internetHost: String {
        didSet { if !isSample { defaults.set(internetHost, forKey: Self.internetHostKey) } }
    }
    var internetPort: String {
        didSet { if !isSample { defaults.set(internetPort, forKey: Self.internetPortKey) } }
    }
    /// The link the running stack was started with.
    private(set) var internet: Reticulum.InternetLink?
    var opportunistic = false
    var heartbeat = false

    // Measurements.
    private(set) var memoryBeforeMB: Double?
    private(set) var memoryRunningMB: Double?
    private(set) var pythonReadyMs: Int?
    private(set) var reticulumMs: Int?
    private(set) var lxmfMs: Int?

    /// The conversation on screen (its messages are read as they arrive).
    var openPeer: String? {
        didSet { if let openPeer { markRead(openPeer) } }
    }
    var isForeground = true
    /// Blocks and the word filter: every incoming message and name passes through it.
    @ObservationIgnored var safety: Safety?

    static let logLimit = 400
    static let displayNameKey = "reticulum.displayName"
    static let lastSettingsKey = "reticulum.radioSettings"
    static let internetOnKey = "reticulum.internet.on"
    static let internetHostKey = "reticulum.internet.host"
    static let internetPortKey = "reticulum.internet.port"
    /// The port Reticulum's own examples use for a TCP node.
    static let defaultInternetPort = "4242"
    static let defaultName = "Wildcat"
    static let internetInterfaceName = "Internet link"
    private let runtime: ReticulumRuntime
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bookURL: URL?
    @ObservationIgnored private let saver = Debouncer(.seconds(3))
    @ObservationIgnored private weak var link: RNodeLink?
    @ObservationIgnored var onEvent: ((Reticulum.Event) -> Void)?
    /// Posts a notification (tests replace it).
    @ObservationIgnored var notify: (Reticulum.Message, String, String) -> Void = ReticulumModel.post

    /// `bookURL` nil keeps nothing on disk (tests); the default is the app's own save file.
    init(runtime: ReticulumRuntime = .shared, defaults: UserDefaults = .standard, bookURL: URL? = ReticulumModel.defaultBookURL()) {
        self.runtime = runtime
        self.defaults = defaults
        self.bookURL = bookURL
        displayName = defaults.string(forKey: Self.displayNameKey) ?? Self.defaultName
        internetOn = defaults.bool(forKey: Self.internetOnKey)
        internetHost = defaults.string(forKey: Self.internetHostKey) ?? ""
        internetPort = defaults.string(forKey: Self.internetPortKey) ?? Self.defaultInternetPort
        if let bookURL, var saved = SaveFile.load(Reticulum.Book.self, from: bookURL) {
            // Whatever was on its way when the app last closed never got its answer.
            saved.interrupt()
            book = saved
        }
    }

    /// Not started yet, or stopped: Reticulum itself stays in the process after a stop, and a new
    /// start attaches its interfaces again (the bridge's `restart`).
    var canStart: Bool { phase == .idle || phase == .stopped }
    var isRunning: Bool { phase == .running }
    /// The RNode's interface is up: messages can go out.
    var radioOnline: Bool { interfaces.contains { $0.isRNode && $0.online } }
    /// The internet link is connected to its node.
    var internetOnline: Bool { interfaces.contains { !$0.isRNode && $0.online } }
    /// Something can carry a message right now.
    var anyLinkOnline: Bool { interfaces.contains { $0.online } }

    // MARK: Internet link

    /// What is typed for the internet link, checked. nil while the link is off.
    var typedInternetLink: Result<Reticulum.InternetLink, Reticulum.InternetLinkProblem>? {
        internetOn ? Reticulum.internetLink(host: internetHost, port: internetPort) : nil
    }

    /// What a start would use right now, or the plain reason it can't happen.
    func startPlan(_ link: RNodeLink?) -> Result<Reticulum.StartPlan, StartRefusal> {
        var net: Reticulum.InternetLink?
        switch typedInternetLink {
        case .success(let l): net = l
        case .failure(let problem): return .failure(StartRefusal(line: problem.line))
        case nil: net = nil
        }
        let connected = useRNode && (link?.state.isReady ?? false)
        switch Reticulum.startPlan(rnodeConnected: connected, device: link?.session.device ?? RNode.DeviceInfo(),
                                   settings: plannedSettings(link)?.settings, internet: net) {
        case .success(let plan): return .success(plan)
        case .failure(.noRNode): return .failure(StartRefusal(line: "Connect an RNode, or turn on the internet link."))
        case .failure(let problem): return .failure(StartRefusal(line: problem.line))
        }
    }

    // MARK: Radio settings

    /// The settings Reticulum last started with on this phone.
    var lastSettings: Reticulum.RadioSettings? {
        get { defaults.data(forKey: Self.lastSettingsKey).flatMap { try? JSONDecoder().decode(Reticulum.RadioSettings.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.lastSettingsKey) }
    }

    /// What a start on this RNode would set its radio to, and where that comes from: the person's
    /// own settings (the RNode console), never a built-in default.
    func plannedSettings(_ link: RNodeLink?) -> (settings: Reticulum.RadioSettings, source: Reticulum.SettingsSource)? {
        Reticulum.settingsForStart(rnode: link?.session.parameters ?? RNode.RadioParameters(), lastUsed: lastSettings)
    }

    /// Why a start on this RNode would be refused right now, or nil.
    func startProblem(_ link: RNodeLink?) -> Reticulum.StartProblem? {
        Reticulum.startProblem(connected: link?.state.isReady ?? false, device: link?.session.device ?? RNode.DeviceInfo(),
                               settings: plannedSettings(link)?.settings)
    }

    // MARK: Commands

    func start(link: RNodeLink?) {
        guard canStart else { return }
        lastStartError = nil
        // Reticulum ends the whole process on an RNode it refuses (firmware older than 1.52), and
        // never brings up a radio whose settings it rejects: check both here, and say why.
        let plan: Reticulum.StartPlan
        switch startPlan(link) {
        case .success(let p): plan = p
        case .failure(let why):
            lastStartError = why.line
            append("not started: \(why.line)")
            return
        }
        guard let paths = ReticulumRuntime.Paths.bundle(), paths.installed else {
            lastStartError = "Reticulum isn't in this build."
            append("not started: Python isn't in this build (tools/reticulum/fetch.sh, then build again)")
            return
        }
        memoryBeforeMB = ProcessMemory.footprintMB()
        // Python and the bridge start once per process; after a stop they are already there.
        phase = runtime.isReady ? .starting : .launching
        interfaces = []
        runtime.onEvent = { [weak self] json in self?.receive(json) }
        if plan.radio != nil, let link {
            self.link = link
            // KISS frames must reach the RNode in the order Reticulum wrote them: the main queue is
            // FIFO (separate Tasks wouldn't promise that).
            runtime.setRNodeWriter { [weak link] data in
                DispatchQueue.main.async { MainActor.assumeIsolated { link?.hostWrite(data) } }
            }
            link.attachHost(onBytes: { data in
                data.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress { wc_rnode_push(base, raw.count) }
                }
            }, onConnected: { [weak self, weak link] up in
                // The link came back (a reconnect): the same check as at the start, before
                // Reticulum talks to whatever is on the other end now.
                if up, link?.session.device.firmwareIsCurrentEnough != true {
                    wc_rnode_set_connected(0)
                    self?.refuseRNode()
                    return
                }
                wc_rnode_set_connected(up ? 1 : 0)
            })
        }
        let key = ReticulumKeychain.loadIdentity()
        identityStore = key == nil ? "new (will be saved to the Keychain)" : "Keychain"
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var command: [String: Any] = [
            "op": "start",
            "storage": Self.storageDirectory().path,
            "display_name": name.isEmpty ? Self.defaultName : String(name.prefix(32)),
            "loglevel": 4,
            "heartbeat": heartbeat,
        ]
        if let key { command["identity"] = key.hexString }
        if let net = plan.internet {
            command["tcp"] = [["name": Self.internetInterfaceName, "host": net.host, "port": net.port]]
        }
        internet = plan.internet
        if let planned = plan.radio {
            command["rnode"] = planned.command
            radio = planned
            lastSettings = planned
        } else {
            radio = nil
        }
        runtime.launch(paths: paths)
        runtime.submit(command)
        append("start: internet \(plan.internet?.line ?? "off") · rnode \(radio?.line ?? "off")")
    }

    func announce() {
        guard isRunning else { return }
        runtime.submit(["op": "announce"])
    }

    /// Sends `text` to an LXMF address (32 hex digits). Returns the local id.
    @discardableResult
    func send(to address: String, text: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, let to = Reticulum.address(address), !body.isEmpty else { return nil }
        let id = UUID().uuidString
        runtime.submit(["op": "send", "id": id, "to": to, "text": body, "method": opportunistic ? "opportunistic" : "direct"])
        return id
    }

    func stop() {
        guard isRunning else { return }
        runtime.submit(["op": "stop"])
    }

    /// The RNode that came back isn't one Reticulum accepts: stop before Reticulum asks it anything.
    private func refuseRNode() {
        let device = link?.session.device ?? RNode.DeviceInfo()
        let problem: Reticulum.StartProblem = device.firmwareIsCurrentEnough == nil ? .firmwareUnknown
            : .firmwareTooOld(have: device.firmwareVersion ?? "?")
        lastStartError = problem.line
        append("stopping: \(problem.line)")
        stop()
    }

    /// The app is leaving the foreground: save the conversations now, and ask Reticulum to save what
    /// it has learnt (paths, known destinations). iOS ends an app without telling it.
    func persist() {
        saveNow()
        guard isRunning else { return }
        runtime.submit(["op": "persist"])
    }

    // MARK: Conversations

    /// Conversations that may be shown: nobody blocked.
    var conversations: [Reticulum.Conversation] { book.conversations.filter { !hides($0.peer) } }
    /// People heard that may be shown, the most recent first.
    var heard: [Reticulum.Contact] { book.heardRecently.filter { !hides($0.hash) } }
    var unread: Int { conversations.reduce(0) { $0 + $1.unread } }

    func thread(with peer: String) -> [Reticulum.Message] { hides(peer) ? [] : book.thread(with: peer) }

    /// A name as it may be shown: the contact's announced name through the word filter, or the short address.
    func title(for peer: String) -> String {
        let t = book.contact(peer)?.title ?? Reticulum.shortAddress(peer)
        return safety?.shown(t) ?? t
    }

    /// Received text as it may be shown (the word filter); sent text as written.
    func shown(_ m: Reticulum.Message) -> String { m.incoming ? (safety?.shown(m.text) ?? m.text) : m.text }

    func hides(_ peer: String) -> Bool { safety?.hides(reticulum: peer) ?? false }

    func markRead(_ peer: String) {
        guard book.thread(with: peer).contains(where: { !$0.read }) else { return }
        book.markRead(peer: peer)
        scheduleSave()
    }

    func removeConversation(with peer: String) {
        book.removeConversation(with: peer)
        scheduleSave()
    }

    // MARK: Events

    func receive(_ json: String) {
        guard let event = Reticulum.Event.decode(json) else { return }
        apply(event)
        onEvent?(event)
    }

    func apply(_ event: Reticulum.Event) {
        switch event {
        case .ready(let python):
            if let at = runtime.launchedAt, let ready = runtime.readyAt { pythonReadyMs = Int(ready.timeIntervalSince(at) * 1000) }
            phase = .starting
            append("Python \(python) ready" + (pythonReadyMs.map { " in \($0) ms" } ?? ""))
        case .identity(let key, let hash):
            let saved = ReticulumKeychain.saveIdentity(key)
            identityStore = saved ? "Keychain (new)" : "not saved: Keychain refused it"
            append("new identity \(hash.prefix(8))… " + (saved ? "saved to the Keychain" : "NOT saved"))
        case .started(let s):
            phase = .running
            lastStartError = nil
            address = s.address
            identityHash = s.identityHash
            versions = s.versions
            reticulumMs = s.reticulumMs
            lxmfMs = s.lxmfMs
            if let r = s.radio { radio = r }
            if announcedName == nil { announcedName = displayName }
            memoryRunningMB = ProcessMemory.footprintMB()
            append("started: <\(s.address)>")
        case .interfaces(let list):
            interfaces = list
        case .announce(let a):
            guard a.hash != address else { return }
            book.heard(hash: a.hash, name: a.name, hops: a.hops, stampCost: a.stampCost, at: a.at)
            scheduleSave()
        case .announced(let at):
            lastAnnounce = at
            append("announced")
        case .message(let m):
            accept(m)
        case .messageState(let id, let delivery, let failure, let detail):
            book.update(id: id, delivery: delivery, failure: failure)
            scheduleSave()
            if let detail { append("\(id.prefix(8)): \(delivery.rawValue), \(detail)") }
        case .log(let line):
            append(line)
        case .error(let message):
            append("error: \(message)")
            // A start the bridge refused: back to where a start is possible again.
            if phase.isBusy {
                lastStartError = Self.plain(message)
                releaseRNode()
                phase = address == nil ? .idle : .stopped
            }
        case .stopped:
            phase = .stopped
            interfaces = []
            releaseRNode()
            book.interrupt()
            saveNow()
            append("stopped")
        case .heartbeat(let at):
            lastHeartbeat = at
            heartbeats.append(at)
            if heartbeats.count > 500 { heartbeats.removeFirst(heartbeats.count - 500) }
        case .pythonExited(let code):
            append("Python exited (\(code))")
            if phase != .idle {
                lastStartError = "Reticulum's Python stopped (\(code)). Close Wildcat and open it again to use Reticulum."
                releaseRNode()
                interfaces = []
                phase = .idle
            }
        }
    }

    /// A message from the bridge. Incoming ones pass the block list before anything else sees
    /// them: a blocked sender's message is dropped here, never stored, never notified. A bad
    /// signature is dropped by the book itself.
    private func accept(_ m: Reticulum.Message) {
        var m = m
        if m.incoming {
            guard !hides(m.peer) else {
                append("dropped a message from a blocked sender")
                return
            }
            if m.trust == .badSignature {
                append("dropped a message with an invalid signature")
                return
            }
            m.read = isForeground && openPeer == m.peer
        }
        guard book.add(m) else { return }
        scheduleSave()
        if m.incoming, !m.read { notify(m, title(for: m.peer), shown(m)) }
    }

    private func releaseRNode() {
        link?.detachHost()
        runtime.setRNodeWriter(nil)
        wc_rnode_set_connected(0)
    }

    /// The bridge's error text without Python's exception name in front.
    static func plain(_ message: String) -> String {
        guard let colon = message.range(of: ": "), message[..<colon.lowerBound].allSatisfy({ $0.isLetter }) else { return message }
        return String(message[colon.upperBound...])
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private static func post(_ m: Reticulum.Message, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "Reticulum"
        content.body = body
        content.sound = .default
        content.threadIdentifier = "reticulum-\(m.peer)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reticulum-\(m.id)", content: content, trigger: nil))
    }

    // MARK: Sample (screenshots)

    /// Showing pretend people and messages (`-ReticulumSample`, Debug builds): nothing is saved.
    private(set) var isSample = false
    /// The chat a sample run opens straight away.
    private(set) var sampleChat: String?

    #if DEBUG
    /// A running Reticulum with a few conversations, for screenshots and design review. No Python,
    /// no radio, nothing saved, no real people (MAYA, SAM, N0CALL).
    func loadSample(state: String?, now: Date = Date()) {
        isSample = true
        let maya = "53802fdd0123456789abcdef0123a41c", sam = "9c1e77b2aa45d0c3f6e1b2a3c4d5e6f7", call = "e4a09b6d5c3f2e1d0c9b8a7f6e5d4c3b"
        var b = Reticulum.Book()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        b.heard(hash: maya, name: "MAYA", hops: 1, stampCost: nil, at: ago(3))
        b.heard(hash: sam, name: "SAM (Sideband)", hops: 2, stampCost: nil, at: ago(18))
        b.heard(hash: call, name: "N0CALL", hops: 3, stampCost: 8, at: ago(95))
        b.heard(hash: "0f1e2d3c4b5a69788796a5b4c3d2e1f0", name: nil, hops: 4, stampCost: nil, at: ago(240))
        b.add(.init(id: "s1", incoming: false, peer: maya, text: "Made it to the overlook. Copy?", at: ago(42), delivery: .delivered))
        b.add(.init(id: "s2", incoming: true, peer: maya, text: "Loud and clear. 2 hops through the ridge node.", at: ago(40), delivery: .received, trust: .verified))
        b.add(.init(id: "s3", incoming: false, peer: maya, text: "Heading down at 4.", at: ago(12), delivery: .delivered))
        b.add(.init(id: "s4", incoming: true, peer: maya, text: "See you at the trailhead", at: ago(3), delivery: .received, trust: .verified, read: false))
        b.add(.init(id: "s5", incoming: false, peer: maya, text: "On my way", at: ago(1), delivery: .sending))
        b.add(.init(id: "s6", incoming: true, peer: sam, text: "Testing from Sideband on the Mac", at: ago(60), delivery: .received, trust: .verified))
        b.add(.init(id: "s7", incoming: false, peer: sam, text: "Got it on the iPhone", at: ago(58), delivery: .failed, failure: .noPath))
        b.add(.init(id: "s8", incoming: true, peer: "77aa55cc33ee11ff0099bb7755dd3311", text: "hello? is this the Wildcat beta", at: ago(130), delivery: .received, trust: .unknownSender))
        book = b
        displayName = "Wildcat"
        switch state {
        case "off":
            phase = .idle
        case "stopped":
            phase = .stopped
            address = "a17c0de5b3aa49f18e2d6c7b8a9f0e1d"
        default:
            phase = .running
            address = "a17c0de5b3aa49f18e2d6c7b8a9f0e1d"
            announcedName = "Wildcat"
            radio = Reticulum.RadioSettings(frequencyHz: 914_875_000, bandwidthHz: 125_000, spreadingFactor: 8, codingRate: 5, txPower: 7)
            interfaces = [.init(name: "WildcatRNodeInterface[RNode over Bluetooth]", online: true, rxBytes: 4120, txBytes: 1876)]
            lastAnnounce = ago(9)
            if state == "chat" { sampleChat = maya }
            if state == "chat-failed" { sampleChat = sam }
        }
    }
    #endif

    // MARK: Saving

    private func scheduleSave() {
        guard bookURL != nil else { return }
        saver.schedule { [weak self] in self?.write(now: false) }
    }

    func saveNow() {
        saver.cancel()
        write(now: true)
    }

    private func write(now: Bool) {
        guard let bookURL, !isSample else { return }
        if now { SaveFile.writeNow(book, to: bookURL) } else { SaveFile.write(book, to: bookURL) }
    }

    /// Conversations and people heard: Library/Application Support/Wildcat/reticulum.json. In
    /// backups like the other networks' chats, and never in Documents (which the Files app can show).
    nonisolated static func defaultBookURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Wildcat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reticulum.json")
    }

    /// RNS and LXMF state: Library/Application Support/Reticulum (not Documents, which the Files
    /// app shows). Left out of backups: it holds the ratchet keys (forward secrecy) and RNS's
    /// transport identity, and the LXMF identity they belong to never leaves this phone's Keychain,
    /// so a restored copy would be of no use and one more place for old keys to sit.
    nonisolated static func storageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var dir = base.appendingPathComponent("Reticulum", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }
}

/// The process's memory as iOS counts it against the app (phys_footprint, what Xcode's gauge shows).
enum ProcessMemory {
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// Why Reticulum can't start right now, in plain words.
struct StartRefusal: Error, Equatable {
    let line: String
}
