import Foundation
import WildcatRadioCore

/// A phone-hosted hunt on disk, so the host can carry on after closing the app
/// (or iOS closing it): the referee with every hunter and reading, the invite
/// hunters scanned (code, channel, fox, host, time limit), and when it was saved.
/// Only a hunt in the lobby or live, saved in the last 12 hours, comes back.
struct HostedHuntSave: Codable, Equatable {
    static let currentVersion = 1
    /// A save older than this is a different day's hunt: it's dropped, not restored.
    static let maxAge: TimeInterval = 12 * 3600
    static let fileName = "hosted-hunt.json"

    var version = HostedHuntSave.currentVersion
    var savedAt: Date
    var referee: FoxReferee
    var invite: HuntInvite?

    /// Application Support/hosted-hunt.json (the folder is made if it isn't there).
    static var defaultURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Worth picking up at `now`: this format, a hunt in the lobby or live, saved within `maxAge`.
    func isRestorable(at now: Date) -> Bool {
        guard version == Self.currentVersion, let phase = referee.hunt?.phase, phase != .ended else { return false }
        return abs(now.timeIntervalSince(savedAt)) <= Self.maxAge
    }

    /// The save to restore at `now`, or nil. A finished or stale save is deleted; one that
    /// can't be read is set aside (never a crash, never restored).
    static func load(from url: URL, now: Date) -> HostedHuntSave? {
        guard let save = SaveFile.load(HostedHuntSave.self, from: url, decoder: decoder()) else { return nil }
        guard save.isRestorable(at: now) else {
            remove(at: url)
            return nil
        }
        return save
    }

    /// Writes in the background (after any earlier writes).
    func write(to url: URL) { SaveFile.write(self, to: url, encoder: Self.encoder) }

    /// Writes now (the app is going to the background).
    func writeNow(to url: URL) { SaveFile.writeNow(self, to: url, encoder: Self.encoder()) }

    /// Deletes the save, after any queued writes (so a late write can't bring it back).
    static func remove(at url: URL) {
        SaveFile.flush()
        try? FileManager.default.removeItem(at: url)
    }

    @Sendable static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        // Readings come from radios: a NaN must never make the save fail.
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }
}
