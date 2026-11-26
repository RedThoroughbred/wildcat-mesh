import Foundation

/// The radio log on disk (Library/Caches/wildcat-log.txt), for pulling from a
/// test phone with `xcrun devicectl device copy from … --domain-type appDataContainer`.
///
/// Light on purpose: lines are buffered and written every few seconds off the
/// main thread, and past ~1 MB the file rolls over to wildcat-log.1.txt (one
/// old file kept), so it never grows without end.
@MainActor
enum DebugLog {
    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("wildcat-log.txt")
    static var previousURL: URL { url.deletingLastPathComponent().appendingPathComponent("wildcat-log.1.txt") }
    static let maxBytes: UInt64 = 1_000_000
    static let flushEvery: Duration = .seconds(3)

    private static var buffer: [String] = []
    private static var flushing: Task<Void, Never>?
    private static let queue = DispatchQueue(label: "wildcat.debuglog", qos: .utility)

    static func append(_ line: String) {
        buffer.append(line)
        if buffer.count >= 200 { flush(); return }
        guard flushing == nil else { return }
        flushing = Task { @MainActor in
            try? await Task.sleep(for: flushEvery)
            flushing = nil
            flush()
        }
    }

    /// Writes what's buffered (the next save on the log's own queue).
    static func flush() {
        guard !buffer.isEmpty else { return }
        let data = Data(buffer.joined().utf8)
        buffer = []
        let url = url, old = previousURL, limit = maxBytes
        queue.async { write(data, to: url, rollingTo: old, limit: limit) }
    }

    /// Waits for queued writes (tests).
    static func wait() { queue.sync {} }

    nonisolated static func write(_ data: Data, to url: URL, rollingTo old: URL, limit: UInt64) {
        let fm = FileManager.default
        // File size only (resource values), so no file-timestamp API is touched (privacy manifest).
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, UInt64(size) + UInt64(data.count) > limit {
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            try? data.write(to: url, options: .atomic)
        }
    }
}
