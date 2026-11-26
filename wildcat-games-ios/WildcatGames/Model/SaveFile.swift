import Foundation
import os

/// Reading and writing the app's JSON save files safely.
///
/// A file that exists but can't be read is moved aside to "<name>.bad-<time>"
/// before anything else is saved, so a bug or a newer format never silently
/// wipes someone's chats. Writes go through one serial queue, in order, off
/// the main thread.
enum SaveFile {
    private static let queue = DispatchQueue(label: "wildcat.savefile", qos: .utility)
    private static let log = Logger(subsystem: "com.thebench.wildcatgames", category: "save")

    /// The saved value, or nil when there's no file (or it was unreadable and has been set aside).
    static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            let aside = setAside(url)
            log.error("unreadable \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public); kept as \(aside?.lastPathComponent ?? "?", privacy: .public)")
            return nil
        }
    }

    /// Moves `url` to "<name>.bad-<unix time>" next to it. Returns the new place.
    @discardableResult
    static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bad-\(Int(now.timeIntervalSince1970))")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Encodes and writes on the save queue (the value is a copy taken now, on the caller's thread).
    static func write<T: Encodable>(_ value: T, to url: URL, encoder: @escaping @Sendable () -> JSONEncoder = { JSONEncoder() }) {
        let box = UncheckedBox(value)
        queue.async {
            do {
                try encoder().encode(box.value).write(to: url, options: .atomic)
            } catch {
                log.error("save \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Encodes and writes now (going to the background), after any queued writes.
    static func writeNow<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder()) {
        guard let data = try? encoder.encode(value) else { return }
        queue.sync { try? data.write(to: url, options: .atomic) }
    }

    /// Waits for queued writes (tests).
    static func flush() { queue.sync {} }
}

/// A value copied into the save queue; value types only, never touched again by the caller.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// Runs `work` at most once per `delay`: the first call starts the clock,
/// later calls within it ride along (so a steady stream still saves).
@MainActor
final class Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(_ delay: Duration) { self.delay = delay }

    func schedule(_ work: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.task = nil
            work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
