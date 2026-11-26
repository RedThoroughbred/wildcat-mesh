import Foundation
import Observation

// MARK: - Manifest

/// The firmware list Wildcat publishes (`tools/firmware_manifest.py` writes it from the official
/// GitHub releases): per network, the newest stable release and the newest version Wildcat has
/// been tested with. Version numbers, dates, release pages and a short summary. No download links.
struct FirmwareManifest: Codable, Equatable {
    struct Release: Codable, Equatable {
        /// Dotted numbers for comparison: "2.7.26", "1.17.1".
        var version: String
        /// What an official build reports: "2.7.26.54e0d8d", "v1.17.1-d929643".
        var full: String?
        var tag: String?
        var name: String?
        /// "2026-06-24".
        var date: String?
        /// The official release page.
        var url: String?
        /// The first lines of the release notes, plain text.
        var summary: String?
    }

    struct Tested: Codable, Equatable {
        /// "2.7.x" (any 2.7 release) or "1.17.1".
        var version: String
        var note: String?
    }

    struct Network: Codable, Equatable {
        var repo: String?
        var latest: Release
        var tested: Tested?
        var role: String?
    }

    var schema: Int
    var generated: String?
    var networks: [String: Network]

    /// The newest format this build understands. A higher one is still read if its fields fit.
    static let schema = 1

    func network(_ n: MeshNetwork) -> Network? { networks[n.rawValue] }

    static func decode(_ data: Data) throws -> FirmwareManifest {
        try JSONDecoder().decode(FirmwareManifest.self, from: data)
    }
}

extension FirmwareManifest.Release {
    /// The release page, only if it's a plain https link.
    var pageURL: URL? {
        guard let url, let u = URL(string: url), u.scheme == "https", u.host != nil else { return nil }
        return u
    }

    /// "24 Jun 2026" from "2026-06-24" (nil if it isn't a date).
    var dateText: String? {
        guard let date, let d = FirmwareFormat.day.date(from: String(date.prefix(10))) else { return nil }
        // A calendar day, not an instant: shown in UTC so it never slips to the day before.
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = FirmwareFormat.day.timeZone
        return d.formatted(style)
    }
}

enum FirmwareFormat {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Versions

/// A firmware version as numbers, read from whatever a node or a release says:
/// Meshtastic "2.7.15.567b8ea", MeshCore "v1.17.1-d929643", "v1.17.1", "1.17.1 (14 Aug 2026)".
/// Up to three numeric parts; the rest (a commit, a date) is kept as `build` and never compared.
struct FirmwareVersion: Comparable, Hashable, CustomStringConvertible {
    let numbers: [Int]
    let build: String?

    init?(_ text: String?) {
        guard let parsed = Self.parse(text, wildcard: false) else { return nil }
        numbers = parsed.numbers
        build = parsed.build
    }

    /// A tested version: "2.7.x" means every 2.7 release, so only its numbers are compared.
    init?(pattern text: String?) {
        guard let parsed = Self.parse(text, wildcard: true) else { return nil }
        numbers = parsed.numbers
        build = nil
    }

    init(_ numbers: [Int], build: String? = nil) {
        self.numbers = numbers
        self.build = build
    }

    /// "2.7.15".
    var description: String { numbers.map(String.init).joined(separator: ".") }

    static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool { compare(a.numbers, b.numbers) < 0 }
    static func == (a: FirmwareVersion, b: FirmwareVersion) -> Bool { compare(a.numbers, b.numbers) == 0 }
    func hash(into h: inout Hasher) {
        var n = numbers
        while n.last == 0 { n.removeLast() }
        h.combine(n)
    }

    /// Within what `tested` covers: compares only as many parts as `tested` has
    /// (2.7.26 is within "2.7.x"; 1.17.2 is not within "1.17.1").
    func isWithin(_ tested: FirmwareVersion) -> Bool {
        Self.compare(Array(numbers.prefix(tested.numbers.count)), tested.numbers) <= 0
    }

    /// Missing parts count as 0: 1.17 == 1.17.0.
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func parse(_ text: String?, wildcard: Bool) -> (numbers: [Int], build: String?)? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= 64 else { return nil }
        if let dash = s.range(of: "-v", options: [.caseInsensitive]), s.lowercased().hasPrefix("companion") {
            s = String(s[dash.upperBound...])   // a release tag: "companion-v1.17.1"
        }
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        var numbers: [Int] = []
        var rest = Substring(s)
        while numbers.count < 3 {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            // Short runs only (no overflow); a run running into letters is a commit hash, not a part.
            guard !digits.isEmpty, digits.count <= 4, let n = Int(digits) else { break }
            let after = rest.dropFirst(digits.count)
            if let c = after.first, c.isLetter { break }
            numbers.append(n)
            rest = after
            if rest.first == "." { rest = rest.dropFirst() } else { break }
            if wildcard, let c = rest.first, c == "x" || c == "X" || c == "*" { rest = rest.dropFirst(); break }
        }
        guard numbers.count >= 2 else { return nil }
        let build = rest.trimmingCharacters(in: CharacterSet(charactersIn: ".-+_ ()").union(.whitespaces))
        return (numbers, build.isEmpty ? nil : build)
    }
}

// MARK: - Verdict

/// What the check says about one node, in words for the Firmware section.
struct FirmwareVerdict: Equatable {
    enum Status: Equatable {
        /// A practice node: pretend firmware, nothing to update.
        case practice
        /// The node didn't say, or said something that isn't a version.
        case unknown
        case updateAvailable
        /// Newer than the latest stable release: a pre-release (alpha or beta) build.
        case aheadOfStable
        /// The latest stable, but newer than Wildcat has been tested with.
        case newerThanTested
        case upToDate
    }

    var status: Status
    /// "Up to date", "Update available: 2.7.15 → 2.7.26".
    var headline: String
    /// One or two plain sentences under it.
    var detail: String?
    /// The node runs something newer than Wildcat has been tested with.
    var untested: Bool = false

    /// Worth a mark on the menu row.
    var wantsAttention: Bool { status == .updateAvailable }

    /// Compares `current` (what the node reports) with the list.
    static func evaluate(_ network: MeshNetwork, current: String?, practice: Bool,
                         manifest: FirmwareManifest) -> FirmwareVerdict {
        let entry = manifest.network(network)
        let latest = entry.flatMap { FirmwareVersion($0.latest.version) }
        let tested = entry?.tested.flatMap { FirmwareVersion(pattern: $0.version) }
        let testedText = entry?.tested?.version ?? ""

        if practice {
            return FirmwareVerdict(status: .practice, headline: "Practice node: pretend firmware",
                                   detail: "Nothing to update. Connect a real \(network.name) node to check its firmware.")
        }
        guard let latest else {
            return FirmwareVerdict(status: .unknown, headline: "No \(network.name) release in the list",
                                   detail: "Try again later.")
        }
        guard let mine = FirmwareVersion(current) else {
            let said = current.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            return FirmwareVerdict(status: .unknown, headline: "Unknown version",
                                   detail: (said.map { "The node reports \"\($0)\". " } ?? "The node didn't report its version. ")
                                       + "The latest stable \(network.name) release is \(latest).")
        }
        let untested = tested.map { !mine.isWithin($0) } ?? false
        let latestUntested = tested.map { !latest.isWithin($0) } ?? false
        let testedLine = "Newer than Wildcat has been tested with (\(testedText)). It should work; if something doesn't, tell us."

        if mine < latest {
            var detail = "\(latest) is the latest stable \(network.name) release."
            if latestUntested { detail += " Wildcat has been tested up to \(testedText)." }
            return FirmwareVerdict(status: .updateAvailable, headline: "Update available: \(mine) → \(latest)",
                                   detail: detail, untested: untested)
        }
        if mine > latest {
            return FirmwareVerdict(status: .aheadOfStable, headline: "Newer than the latest stable (\(latest))",
                                   detail: "A pre-release (alpha or beta) build." + (untested ? " " + testedLine : ""),
                                   untested: untested)
        }
        if untested {
            return FirmwareVerdict(status: .newerThanTested, headline: "Up to date, newer than Wildcat has tested",
                                   detail: testedLine, untested: true)
        }
        return FirmwareVerdict(status: .upToDate, headline: "Up to date",
                               detail: "\(latest) is the latest stable \(network.name) release.")
    }
}

// MARK: - The check

/// Fetches the firmware list, **only when the user taps Check for updates**: Wildcat makes no
/// other network requests except to a Den the user types. A plain GET of a public file, with no
/// identifiers, cookies or cache (ephemeral session), and a short timeout. The last list and when
/// it came are kept so the answer is still there next time, offline.
@MainActor
@Observable
final class FirmwareCheck {
    enum State: Equatable {
        case idle
        case checking
        case failed(String)
    }

    /// Where Wildcat publishes the list.
    static let defaultURL = URL(string: "https://redthoroughbred.github.io/wildcat/firmware.json")!
    static let manifestKey = "firmware.manifest"
    static let checkedKey = "firmware.checked"
    /// A firmware list is a few kilobytes; anything far bigger isn't one.
    static let maxBytes = 256 * 1024

    private(set) var manifest: FirmwareManifest?
    private(set) var checked: Date?
    private(set) var state: State = .idle

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let load: (URL) async throws -> (Data, URLResponse)

    init(defaults: UserDefaults = .standard, load: ((URL) async throws -> (Data, URLResponse))? = nil) {
        self.defaults = defaults
        self.load = load ?? Self.fetch
        if let d = defaults.data(forKey: Self.manifestKey), let m = try? FirmwareManifest.decode(d) {
            manifest = m
            checked = defaults.object(forKey: Self.checkedKey) as? Date
        }
    }

    var isChecking: Bool { state == .checking }

    /// The list's address. Debug builds only: `-FirmwareManifestURL <url or path>` points it
    /// elsewhere (a local file, before the site copy is published). Release builds always use the site.
    static var manifestURL: URL {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "FirmwareManifestURL"), !s.isEmpty {
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
            if let u = URL(string: s) { return u }
        }
        #endif
        return defaultURL
    }

    /// What the check says about a node (nil until a list has been fetched).
    func verdict(_ network: MeshNetwork, current: String?, practice: Bool) -> FirmwareVerdict? {
        manifest.map { FirmwareVerdict.evaluate(network, current: current, practice: practice, manifest: $0) }
    }

    func check(now: Date = Date()) async {
        guard state != .checking else { return }
        state = .checking
        do {
            let (data, response) = try await load(Self.manifestURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw CheckError.status(http.statusCode)
            }
            guard data.count <= Self.maxBytes else { throw CheckError.notAList }
            guard let m = try? FirmwareManifest.decode(data) else { throw CheckError.notAList }
            manifest = m
            checked = now
            defaults.set(data, forKey: Self.manifestKey)
            defaults.set(now, forKey: Self.checkedKey)
            state = .idle
        } catch {
            state = .failed(Self.message(error))
        }
    }

    enum CheckError: Error { case status(Int), notAList }

    static func message(_ error: Error) -> String {
        switch error {
        case CheckError.status(let code): return "The Wildcat website answered \(code). Try again later."
        case CheckError.notAList: return "That wasn't a firmware list Wildcat can read. Try again later, or update Wildcat."
        case let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code):
            return "No internet connection. Try again when you have one."
        case let e as URLError where e.code == .timedOut: return "The Wildcat website didn't answer. Try again later."
        default: return "Couldn't get the firmware list. Try again later."
        }
    }

    /// One plain GET: ephemeral (no cookies, cache or credentials kept), a generic user agent
    /// instead of the device's, and a short timeout.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "WildcatMesh", "Accept": "application/json", "Accept-Language": "en"]
        return URLSession(configuration: c)
    }()

    private static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.httpShouldHandleCookies = false
        return try await session.data(for: r)
    }
}
