import Foundation

/// The embedded CPython that runs the official Reticulum stack (RNS and LXMF, unmodified), one per
/// app process. Python gets a thread of its own, which becomes its main thread (RNS and LXMF need
/// that for their signal handlers); commands go in as JSON from any thread, events come back as
/// JSON on the main actor. The Python side is `Reticulum/python/wildcat_reticulum`; the C between
/// is `WildcatPython.c`.
///
/// Python and Reticulum start once per process. Stopping Reticulum detaches its interfaces and
/// leaves it idle; starting again attaches them (the bridge's `restart`), so nobody has to reopen
/// the app.
final class ReticulumRuntime: @unchecked Sendable {
    static let shared = ReticulumRuntime()

    /// Where the build phase (`tools/reticulum/install-python.sh`) puts Python in the bundle.
    struct Paths: Equatable {
        let home: String
        let appPackages: String
        let app: String

        static func bundle(_ bundle: Bundle = .main) -> Paths? {
            guard let r = bundle.resourcePath else { return nil }
            return Paths(home: r + "/python", appPackages: r + "/app_packages", app: r + "/app")
        }

        /// The standard library and the bridge are in place.
        var installed: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: home + "/lib/python3.13/os.py")
                && fm.fileExists(atPath: app + "/wildcat_reticulum/__init__.py")
                && fm.fileExists(atPath: appPackages + "/RNS/__init__.py")
        }
    }

    private let lock = NSLock()
    private var launched = false
    private var bridgeReady = false
    private var waiting: [String] = []
    private var writeHandler: (@Sendable (Data) -> Void)?
    private let submitQueue = DispatchQueue(label: "wildcat.reticulum.submit", qos: .userInitiated)

    /// Every event the bridge emits (a JSON object), on the main actor.
    @MainActor var onEvent: ((String) -> Void)?
    /// When `launch` ran, and when the bridge first said it was ready.
    private(set) var launchedAt: Date?
    private(set) var readyAt: Date?

    var isLaunched: Bool { lock.withLock { launched } }
    /// The bridge has said it is ready: commands run at once.
    var isReady: Bool { lock.withLock { bridgeReady } }

    /// Bytes Reticulum wants written to the RNode (called on a Python thread).
    func setRNodeWriter(_ handler: (@Sendable (Data) -> Void)?) {
        lock.withLock { writeHandler = handler }
    }

    /// Starts the interpreter and the bridge on Python's own thread. Once per process.
    @discardableResult
    func launch(paths: Paths) -> Bool {
        let first = lock.withLock { () -> Bool in
            guard !launched else { return false }
            launched = true
            launchedAt = Date()
            return true
        }
        guard first else { return false }
        wc_set_handlers(reticulumEventTrampoline, reticulumWriteTrampoline)
        let thread = Thread {
            let rc = wc_python_run(paths.home, paths.appPackages, paths.app)
            ReticulumRuntime.shared.received(#"{"event": "python_exited", "code": \#(rc)}"#)
        }
        thread.name = "python"
        // Python's main thread: a desktop-sized stack for deep imports and recursion.
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
        return true
    }

    /// Queues a command (a JSON object) for the bridge; held until the bridge is ready.
    func submit(_ json: String) {
        let now: Bool = lock.withLock {
            if bridgeReady { return true }
            waiting.append(json)
            return false
        }
        guard now else { return }
        submitQueue.async { _ = wc_python_submit(json) }
    }

    func submit(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        submit(json)
    }

    // MARK: From C (Python threads)

    fileprivate func received(_ json: String) {
        if Self.eventName(json) == "ready" {
            let held: [String] = lock.withLock {
                bridgeReady = true
                readyAt = Date()
                defer { waiting = [] }
                return waiting
            }
            submitQueue.async { for c in held { _ = wc_python_submit(c) } }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onEvent?(json) } }
    }

    fileprivate func rnodeWrite(_ data: Data) {
        let handler = lock.withLock { writeHandler }
        handler?(data)
    }

    /// The `event` of an event's JSON.
    static func eventName(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["event"] as? String
    }
}

// C callbacks can't capture context: they reach the runtime through `shared`.
private let reticulumEventTrampoline: wc_event_fn = { json in
    guard let json else { return }
    ReticulumRuntime.shared.received(String(cString: json))
}

private let reticulumWriteTrampoline: wc_bytes_fn = { bytes, length in
    guard let bytes, length > 0 else { return }
    ReticulumRuntime.shared.rnodeWrite(Data(bytes: bytes, count: length))
}
