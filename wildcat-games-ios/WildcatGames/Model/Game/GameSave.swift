import Foundation
import WildcatRadioCore

/// A Hunt game on disk (Application Support/hunt-game.json), so a player who closes the app
/// (or whom iOS closes) carries on: the whole `HuntGame`, referees and label codes included,
/// and when it was saved. A game that isn't over, saved in the last 12 hours, comes back.
struct GameSave: Codable, Equatable {
    static let currentVersion = 1
    static let maxAge: TimeInterval = 12 * 3600
    static let fileName = "hunt-game.json"

    var version = GameSave.currentVersion
    var savedAt: Date
    var game: HuntGame
    /// The hunter had no node and uses the GPS guide.
    var guide = false

    static var defaultURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Worth picking up at `now`: this format, a game not over, saved within `maxAge`.
    func isRestorable(at now: Date) -> Bool {
        guard version == Self.currentVersion, !game.isOver else { return false }
        return abs(now.timeIntervalSince(savedAt)) <= Self.maxAge
    }

    /// The save to restore at `now`, or nil. A finished or stale save is deleted; one that can't
    /// be read is set aside (never a crash, never restored).
    static func load(from url: URL, now: Date) -> GameSave? {
        guard let save = SaveFile.load(GameSave.self, from: url, decoder: HostedHuntSave.decoder()) else { return nil }
        guard save.isRestorable(at: now) else {
            remove(at: url)
            return nil
        }
        return save
    }

    func write(to url: URL) { SaveFile.write(self, to: url, encoder: HostedHuntSave.encoder) }
    func writeNow(to url: URL) { SaveFile.writeNow(self, to: url, encoder: HostedHuntSave.encoder()) }

    static func remove(at url: URL) {
        SaveFile.flush()
        try? FileManager.default.removeItem(at: url)
    }
}
