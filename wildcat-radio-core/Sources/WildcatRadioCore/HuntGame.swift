import CryptoKit
import Foundation

/// Hunt for two or three friends (Small Play 2): one player hides up to three pieces, the
/// others hunt them by signal, then they swap who hides. Fastest total time wins.
///
/// Each phone keeps its own `HuntGame`. In a round this phone hides, it referees: one
/// `FoxReferee` per piece, each with its own hunt code (`huntCode(round:piece:)`, the game
/// code plus the round and piece digits: game "FOXK7", round 1, piece 2 -> "FOXK712"), so
/// the wire protocol is WG v0 unchanged and a hunter's app (or a stock client) talks to
/// each piece as to any phone-refereed hunt. In a round this phone hunts, it keeps what it
/// hears: the GO, its own finds (timed by this phone's clock from the GO), other hunters'
/// finds and the END of each piece.
///
/// Swapping who hides needs no hand-over between phones: the invite every hunter scanned
/// carries the game (pieces, rounds, limit, how a find counts), so the next hider's phone
/// starts the next round's referees itself, and the next round's hunt codes are known to
/// everyone. Each phone adds up the times it saw (`standings`).
///
/// The hider calibrates each piece while hiding it (`hide`): the reading of the hider's own
/// node right beside the piece, minus `claimMarginRSSI`, is that piece's claim line ("within
/// a few steps") instead of one fixed level for every box and every place.
///
/// Pure: no clock, no radio, no randomness; every call takes its time `t` (seconds). Codable,
/// so a phone can save the game and pick it up after a restart (the save holds the label codes:
/// keep it private to the phone).
public struct HuntGame: Sendable, Equatable, Codable {
    public static let maxPieces = 3
    public static let maxRounds = 3
    /// A claim needs the hider's reading right beside the piece minus this many dB (RSSI):
    /// about three times the hider's distance, a few steps.
    public static let claimMarginRSSI: Double = 14
    /// The same for SNR, which saturates close to a node, so the margin is smaller.
    public static let claimMarginSNR: Double = 4
    /// Calibrated claim lines stay inside these.
    public static let claimRangeRSSI: ClosedRange<Double> = -95 ... -30
    public static let claimRangeSNR: ClosedRange<Double> = -10 ... 10
    /// The claim lines of a piece the hider's node didn't hear (the referee's defaults).
    public static let defaultClaimRSSI: Double = -75
    public static let defaultClaimSNR: Double = 8
    /// From right beside a piece the hider's node should hear it louder than this; a weaker
    /// reading means a flat battery, a metal box or the wrong node.
    public static let weakRSSI: Double = -75
    /// Readings from the hider's node in this window before "Hidden here" calibrate the piece.
    public static let calibrationWindow: TimeInterval = 90
    /// A hunter who heard no END ends the round itself this long after the time limit.
    public static let endGrace: TimeInterval = 60
    /// The code a piece's referee holds until the hider types the code on its label (it can't go live with it).
    static let unknownCode = "0000"

    // MARK: Types

    public enum Role: String, Sendable, Codable {
        /// This phone hides the pieces and referees the round.
        case hider
        /// This phone hunts them.
        case hunter
    }

    public enum Stage: String, Sendable, Codable {
        /// The hider is hiding the pieces; hunters may join.
        case hiding
        case live
        case over
    }

    public struct Settings: Equatable, Sendable, Codable {
        /// 1 to `maxRounds`.
        public var rounds: Int
        /// Seconds per round from its start; nil for none.
        public var timeLimit: TimeInterval?
        public var mode: FoxReferee.Mode

        public init(rounds: Int = 2, timeLimit: TimeInterval? = 1200, mode: FoxReferee.Mode = .either) {
            self.rounds = max(1, min(HuntGame.maxRounds, rounds))
            self.timeLimit = timeLimit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.mode = mode
        }

        private enum K: String, CodingKey { case rounds, timeLimit, mode }

        /// Read through `init`, so a saved file can't bring back nonsense (zero rounds).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            self.init(rounds: try c.decode(Int.self, forKey: .rounds), timeLimit: try c.decodeIfPresent(Double.self, forKey: .timeLimit),
                      mode: try c.decode(FoxReferee.Mode.self, forKey: .mode))
        }
    }

    /// A node to hide, as the host picks it.
    public struct NewPiece: Equatable, Sendable {
        public var node: NodeNum
        public var name: String
        /// The 4 digits on its label.
        public var code: String

        public init(node: NodeNum, name: String, code: String) {
            self.node = node; self.name = name; self.code = code
        }
    }

    public struct Piece: Equatable, Sendable, Codable {
        /// 1, 2 or 3: the last digit of its hunt codes.
        public var index: Int
        public var node: NodeNum
        public var name: String
        /// The 4 digits on its label; nil on a phone that hasn't seen the label (a hunter's).
        public var code: String?
        /// Checks a typed code without knowing it (`codeCheck`).
        public var check: String
    }

    /// A reading of a piece by a node: RSSI (dBm) and/or SNR (dB).
    public struct Reading: Equatable, Sendable, Codable {
        public var rssi: Double?
        public var snr: Double?

        public init(rssi: Double? = nil, snr: Double? = nil) {
            self.rssi = rssi.flatMap { $0.isFinite ? $0 : nil }
            self.snr = snr.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    /// A piece's claim line, from what the hider's node heard right beside it.
    public struct Calibration: Equatable, Sendable, Codable {
        /// What the hider's node heard (nil: nothing, so the defaults apply).
        public var reading: Reading?
        public var claimRSSI: Double
        public var claimSNR: Double

        public init(reading: Reading?) {
            let r = reading.flatMap { $0.rssi == nil && $0.snr == nil ? nil : $0 }
            self.reading = r
            claimRSSI = r?.rssi.map { min(HuntGame.claimRangeRSSI.upperBound, max(HuntGame.claimRangeRSSI.lowerBound, $0 - HuntGame.claimMarginRSSI)) }
                ?? HuntGame.defaultClaimRSSI
            claimSNR = r?.snr.map { min(HuntGame.claimRangeSNR.upperBound, max(HuntGame.claimRangeSNR.lowerBound, $0 - HuntGame.claimMarginSNR)) }
                ?? HuntGame.defaultClaimSNR
        }

        /// The hider's node heard it weakly (or not at all) from right beside it.
        public var isWeak: Bool {
            guard let reading else { return true }
            if let rssi = reading.rssi { return rssi < HuntGame.weakRSSI }
            return false
        }

        /// A reading at or past the claim line (RSSI when known, else SNR), as the referee rules.
        public func isInZone(_ r: Reading) -> Bool {
            if let rssi = r.rssi { return rssi >= claimRSSI }
            if let snr = r.snr { return snr >= claimSNR }
            return false
        }
    }

    /// A piece the hider has put down.
    public struct Hidden: Equatable, Sendable, Codable {
        public var piece: Int
        public var t: TimeInterval
        /// Where the hider stood (nil without a GPS fix): for picking it up again.
        public var spot: Coordinate?
        /// The spot as shared with hunters for the GPS guide (moved and rounded, see `ScentGuide.shared`).
        public var sharedSpot: Coordinate?
        public var calibration: Calibration
    }

    public struct Find: Equatable, Sendable, Codable {
        public var piece: Int
        /// Seconds from the round's start.
        public var elapsed: TimeInterval
        public var proofs: [FoxReferee.Proof]
        /// Worked out from a referee's whole minutes ("T+14M"), not a clock.
        public var approximate: Bool

        public init(piece: Int, elapsed: TimeInterval, proofs: [FoxReferee.Proof] = [], approximate: Bool = false) {
            self.piece = piece; self.elapsed = elapsed; self.proofs = proofs; self.approximate = approximate
        }
    }

    /// One hunter's round.
    public struct Result: Equatable, Sendable, Codable {
        public var name: String
        public var node: NodeNum?
        public var isMe: Bool
        public var finds: [Find]

        public init(name: String, node: NodeNum? = nil, isMe: Bool = false, finds: [Find] = []) {
            self.name = name; self.node = node; self.isMe = isMe; self.finds = finds
        }
    }

    public struct Round: Equatable, Sendable, Codable {
        public var number: Int
        /// Who hides it ("" when this phone doesn't know yet).
        public var hider: String
        /// This phone's part in it.
        public var role: Role
        public var stage: Stage
        public var startedAt: TimeInterval?
        public var endedAt: TimeInterval?
        public var endReason: FoxReferee.EndReason?
        public var hidden: [Hidden] = []
        /// One referee per piece, in piece order, when this phone hides the round.
        public var referees: [FoxReferee] = []
        /// Hunters' rounds: every hunter from the referees when hiding; this phone's own and
        /// the finds it heard of when hunting.
        public var results: [Result] = []
        /// Pieces whose END this hunter heard.
        public var endedPieces: [Int] = []

        public func hidden(_ piece: Int) -> Hidden? { hidden.first { $0.piece == piece } }
    }

    /// One referee output, with the piece it is about.
    public struct Output: Equatable, Sendable {
        public var piece: Int
        public var output: FoxReferee.Output

        public init(piece: Int, output: FoxReferee.Output) { self.piece = piece; self.output = output }
    }

    public enum SetupError: Error, Equatable, Sendable {
        case badGameCode, noPieces, tooManyPieces, samePieceTwice, badLabelCode, noName
    }

    // MARK: State

    /// Tells this game apart from another with the same code (invites, saves).
    public var id: String
    /// "FOX" and one or two letters or digits, e.g. "FOXK7".
    public var code: String
    /// This phone's player name, as hunters' referees know it.
    public var me: String
    public var settings: Settings
    public var pieces: [Piece]
    public var rounds: [Round]
    public var channelName: String

    public var current: Round? { rounds.last }

    // MARK: Codes

    /// A game code: "FOX" and one or two letters or digits (room for the round and piece digits).
    public static func isValidCode(_ s: String) -> Bool {
        let u = s.uppercased()
        return u.hasPrefix("FOX") && (4...5).contains(u.count)
            && u.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The hunt code of `piece` in `round`: "FOXK7" + "1" + "2".
    public func huntCode(round: Int, piece: Int) -> String { "\(code)\(round)\(piece)" }

    /// The round and piece a hunt code is for, when it is this game's.
    public func address(of huntCode: String) -> (round: Int, piece: Int)? {
        let u = huntCode.uppercased()
        guard u.count == code.count + 2, u.hasPrefix(code),
              let round = u.dropLast().last?.wholeNumberValue, let piece = u.last?.wholeNumberValue,
              (1...settings.rounds).contains(round), pieces.contains(where: { $0.index == piece }) else { return nil }
        return (round, piece)
    }

    /// True for any of this game's hunt codes, in any round.
    public func owns(huntCode: String) -> Bool { address(of: huntCode) != nil }

    /// Looks like a game piece's hunt code (a game code plus a round and a piece digit, 1–3 each).
    public static func isPieceCode(_ s: String) -> Bool {
        let u = s.uppercased()
        guard (6...7).contains(u.count), isValidCode(String(u.dropLast(2))) else { return false }
        return u.suffix(2).allSatisfy { ("1"..."3").contains($0) }
    }

    /// Checks a typed label code without carrying the code: the first 8 bytes of
    /// SHA-256("wildcat-hunt|<game id>|<piece>|<code>"), as 16 hex digits.
    public static func codeCheck(game: String, piece: Int, code: String) -> String {
        let d = SHA256.hash(data: Data("wildcat-hunt|\(game)|\(piece)|\(code)".utf8))
        return d.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func isLabelCode(_ s: String) -> Bool { s.count == 4 && s.allSatisfy { $0.isASCII && $0.isNumber } }

    // MARK: Hosting a game

    /// A new game hosted (and hidden first) by this phone: round 1 is in `hiding`, its referees open for joins.
    public init(hosting id: String, code: String, me: String, pieces new: [NewPiece], settings: Settings,
                channelName: String = "WGHUNT", at t: TimeInterval) throws {
        let code = code.uppercased()
        guard Self.isValidCode(code) else { throw SetupError.badGameCode }
        guard !new.isEmpty else { throw SetupError.noPieces }
        guard new.count <= Self.maxPieces else { throw SetupError.tooManyPieces }
        guard Set(new.map(\.node)).count == new.count else { throw SetupError.samePieceTwice }
        guard new.allSatisfy({ Self.isLabelCode($0.code) }) else { throw SetupError.badLabelCode }
        let name = WG.sanitizedName(me)
        guard !name.isEmpty else { throw SetupError.noName }
        self.id = id
        self.code = code
        self.me = name
        self.settings = settings
        self.channelName = String(channelName.prefix(11))
        self.pieces = new.enumerated().map { i, p in
            Piece(index: i + 1, node: p.node, name: Self.pieceName(p.name, index: i + 1), code: p.code,
                  check: Self.codeCheck(game: id, piece: i + 1, code: p.code))
        }
        self.rounds = []
        rounds.append(hidingRound(1, at: t))
    }

    /// A piece's name as shown: its label, trimmed, or "PIECE n".
    static func pieceName(_ s: String, index: Int) -> String {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }
        return clean.isEmpty ? "PIECE \(index)" : String(clean.prefix(16))
    }

    private func hidingRound(_ number: Int, at t: TimeInterval) -> Round {
        var r = Round(number: number, hider: me, role: .hider, stage: .hiding)
        r.referees = pieces.map { referee(for: $0, round: number, calibration: nil, at: t) }
        return r
    }

    private func referee(for p: Piece, round: Int, calibration: Calibration?, at t: TimeInterval) -> FoxReferee {
        var r = FoxReferee()
        r.handle(.create(t: t, fox: p.node, foxCode: p.code ?? Self.unknownCode, code: huntCode(round: round, piece: p.index),
                         mode: settings.mode, thresholdRSSI: calibration?.claimRSSI ?? Self.defaultClaimRSSI,
                         thresholdSNR: calibration?.claimSNR ?? Self.defaultClaimSNR, foxLabel: p.name,
                         channelName: channelName, timeLimit: settings.timeLimit))
        return r
    }

    /// The same referee with new claim lines and label code: its events replayed with the
    /// create changed (joins made while hiding are kept; nothing is said again).
    static func rebuilt(_ r: FoxReferee, calibration: Calibration, foxCode: String) -> FoxReferee {
        FoxReferee.replay(r.events.map { e in
            guard case let .create(t, fox, _, code, mode, _, _, label, channel, limit) = e else { return e }
            return .create(t: t, fox: fox, foxCode: foxCode, code: code, mode: mode, thresholdRSSI: calibration.claimRSSI,
                           thresholdSNR: calibration.claimSNR, foxLabel: label, channelName: channel, timeLimit: limit)
        })
    }

    private func slot(_ piece: Int) -> Int? { pieces.firstIndex { $0.index == piece } }

    /// This phone hides the current round and it hasn't started.
    public var isHiding: Bool { current?.role == .hider && current?.stage == .hiding }

    /// Pieces hidden so far in the current round.
    public var hiddenCount: Int { current?.hidden.count ?? 0 }

    /// Every piece is hidden: the round can start.
    public var canStart: Bool { isHiding && pieces.allSatisfy { current?.hidden($0.index) != nil } }

    /// The label code of `piece`, typed by a hider who wasn't told it (a hunter who swapped
    /// to hide). True when it matches the piece's check.
    @discardableResult
    public mutating func learnCode(piece: Int, code typed: String) -> Bool {
        let c = typed.trimmingCharacters(in: .whitespaces)
        guard let i = slot(piece), Self.isLabelCode(c), Self.codeCheck(game: id, piece: piece, code: c) == pieces[i].check else { return false }
        pieces[i].code = c
        if isHiding, var round = current, i < round.referees.count {
            round.referees[i] = Self.rebuilt(round.referees[i], calibration: round.hidden(piece)?.calibration ?? Calibration(reading: nil), foxCode: c)
            rounds[rounds.count - 1] = round
        }
        return true
    }

    /// The hider put `piece` down at `spot` (the phone's fix, if any), where their node heard
    /// it as `reading`. Sets its claim line and the spot the guide uses (moved `offset`, see
    /// `ScentGuide.shared`). Again before the start moves it. False when the round isn't
    /// being hidden by this phone or the piece's label code isn't known yet.
    @discardableResult
    public mutating func hide(piece: Int, spot: Coordinate?, reading: Reading?,
                              offset: (bearing: Double, distance: Double) = (0, 0), at t: TimeInterval) -> Bool {
        guard isHiding, var round = current, let i = slot(piece), let label = pieces[i].code, i < round.referees.count else { return false }
        let spot = spot.flatMap { $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) <= 90 && abs($0.longitude) <= 180 ? $0 : nil }
        let cal = Calibration(reading: reading)
        let h = Hidden(piece: piece, t: t, spot: spot,
                       sharedSpot: spot.map { ScentGuide.shared($0, bearing: offset.bearing, distance: offset.distance) }, calibration: cal)
        round.hidden.removeAll { $0.piece == piece }
        round.hidden.append(h)
        round.hidden.sort { $0.piece < $1.piece }
        round.referees[i] = Self.rebuilt(round.referees[i], calibration: cal, foxCode: label)
        rounds[rounds.count - 1] = round
        return true
    }

    /// The reading to calibrate with: the median RSSI and median SNR of the hider's direct
    /// readings in the `calibrationWindow` before `t` (nil when there are none).
    public static func calibrationReading(_ samples: [(t: TimeInterval, reading: Reading)], at t: TimeInterval) -> Reading? {
        let recent = samples.filter { $0.t <= t && t - $0.t <= calibrationWindow }.map(\.reading)
        func median(_ v: [Double]) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let r = Reading(rssi: median(recent.compactMap(\.rssi)), snr: median(recent.compactMap(\.snr)))
        return r.rssi == nil && r.snr == nil ? nil : r
    }

    /// Starts the round: every piece's hunt goes live (GO to each piece's hunters).
    public mutating func start(at t: TimeInterval) -> [Output] {
        guard canStart, var round = current else { return [] }
        var out: [Output] = []
        for i in round.referees.indices { out += Self.tag(round.referees[i].handle(.start(t: t)), pieces[i].index) }
        round.stage = .live
        round.startedAt = t
        rounds[rounds.count - 1] = round
        return out + settle(at: t)
    }

    /// The pieces a hunter's command is for: the piece its hunt code names in this round (nil
    /// when it names another hunt, or another round of this game), every piece for LEAVE
    /// (it names none), the first piece for other commands naming none.
    public func pieces(forCommand text: String) -> [Int]? {
        guard current?.role == .hider, let round = current, let (verb, _) = FoxReferee.parseCommand(text) else { return nil }
        if let named = FoxReferee.huntCode(in: text) {
            guard let a = address(of: named), a.round == round.number else { return nil }
            return [a.piece]
        }
        if verb == "LEAVE" { return pieces.map(\.index) }
        return pieces.first.map { [$0.index] }
    }

    /// The piece hidden in `node`, if it is one.
    public func piece(node: NodeNum) -> Int? { pieces.first { $0.node == node }?.index }

    /// Rules on one event for one piece of a round this phone hides.
    public mutating func handle(_ event: FoxReferee.Event, piece: Int) -> [Output] {
        guard current?.role == .hider, var round = current, let i = slot(piece), i < round.referees.count else { return [] }
        let out = Self.tag(round.referees[i].handle(event), piece)
        rounds[rounds.count - 1] = round
        return out + settle(at: event.t)
    }

    /// Rules on an event for every piece (a hunter's position).
    public mutating func handleAll(_ event: FoxReferee.Event) -> [Output] {
        guard current?.role == .hider, var round = current else { return [] }
        var out: [Output] = []
        for i in round.referees.indices where i < pieces.count { out += Self.tag(round.referees[i].handle(event), pieces[i].index) }
        rounds[rounds.count - 1] = round
        return out + settle(at: event.t)
    }

    /// The host ends the round early.
    public mutating func endRound(at t: TimeInterval) -> [Output] {
        guard current?.role == .hider, current?.stage == .live else { return [] }
        return handleAll(.end(t: t))
    }

    /// Time passed: a hider's round ends on its time limit (END to every hunter); a hunter
    /// who heard no END ends it `endGrace` after the limit.
    public mutating func tick(at t: TimeInterval) -> [Output] {
        guard let round = current, round.stage == .live else { return [] }
        if round.role == .hider { return handleAll(.tick(t: t)) }
        if let deadline = deadline, t >= deadline + Self.endGrace {
            rounds[rounds.count - 1].stage = .over
            rounds[rounds.count - 1].endedAt = deadline
            rounds[rounds.count - 1].endReason = .time
        }
        return []
    }

    private static func tag(_ out: [FoxReferee.Output], _ piece: Int) -> [Output] { out.map { Output(piece: piece, output: $0) } }

    /// Refreshes a hider's results; the round is over once every piece's hunt has ended.
    private mutating func settle(at t: TimeInterval) -> [Output] {
        guard var round = current, round.role == .hider else { return [] }
        round.results = Self.results(round.referees, pieces: pieces)
        if round.stage == .live, !round.referees.isEmpty, round.referees.allSatisfy({ $0.hunt?.phase == .ended }) {
            round.stage = .over
            round.endedAt = round.referees.compactMap { $0.hunt?.endedAt }.max() ?? t
            let reasons = round.referees.compactMap { $0.hunt?.endReason }
            round.endReason = reasons.contains(.host) ? .host : reasons.contains(.time) ? .time : .allFound
        }
        rounds[rounds.count - 1] = round
        return []
    }

    /// Every hunter of a refereed round, in the order they first joined, with their finds.
    static func results(_ referees: [FoxReferee], pieces: [Piece]) -> [Result] {
        var byNode: [NodeNum: (joined: TimeInterval, result: Result)] = [:]
        for (i, r) in referees.enumerated() where i < pieces.count {
            for h in r.hunters.values.sorted(by: { ($0.joined, $0.id) < ($1.joined, $1.id) }) {
                var entry = byNode[h.id] ?? (h.joined, Result(name: h.name, node: h.id))
                entry.joined = min(entry.joined, h.joined)
                if let f = h.found {
                    entry.result.finds.append(Find(piece: pieces[i].index, elapsed: f.elapsed, proofs: f.proofs))
                }
                byNode[h.id] = entry
            }
        }
        return byNode.values.sorted { ($0.joined, $0.result.node?.raw ?? 0) < ($1.joined, $1.result.node?.raw ?? 0) }.map(\.result)
    }

    // MARK: The clock

    /// When the current round's time runs out (nil before its start or without a limit).
    public var deadline: TimeInterval? {
        guard let start = current?.startedAt, let limit = settings.timeLimit else { return nil }
        return start + limit
    }

    /// Seconds left in the current round at `t`: the whole limit before the start, frozen once
    /// over; nil without a limit. Never negative.
    public func timeRemaining(at t: TimeInterval) -> TimeInterval? {
        guard let limit = settings.timeLimit, let round = current else { return nil }
        guard let deadline else { return limit }
        return max(0, deadline - (round.stage == .over ? (round.endedAt ?? t) : t))
    }

    // MARK: Hunting a round

    /// A game joined from a hider's invite, as a hunter of the invite's round.
    public init(joining invite: Invite, me: String) {
        id = invite.game
        code = invite.code
        self.me = WG.sanitizedName(me).isEmpty ? "HUNTER" : WG.sanitizedName(me)
        settings = Settings(rounds: invite.rounds, timeLimit: invite.timeLimit, mode: invite.findMode)
        channelName = invite.channelName
        pieces = invite.pieces.map { Piece(index: $0.i, node: NodeNum($0.node), name: $0.name, code: nil, check: $0.check) }
        rounds = [Self.huntingRound(invite)]
    }

    private static func huntingRound(_ invite: Invite) -> Round {
        var r = Round(number: invite.round, hider: invite.hider, role: .hunter, stage: invite.started == nil ? .hiding : .live)
        r.startedAt = invite.started
        r.hidden = invite.pieces.map { p in
            Hidden(piece: p.i, t: 0, spot: nil, sharedSpot: p.spot,
                   calibration: { var c = Calibration(reading: nil)
                                  if let rssi = p.claimRSSI { c.claimRSSI = rssi }
                                  if let snr = p.claimSNR { c.claimSNR = snr }
                                  return c }())
        }
        return r
    }

    /// An invite for this game (a later round, or the same round again with the spots):
    /// adopts its round as a hunter, keeping every earlier round. False when it is another game.
    @discardableResult
    public mutating func merge(_ invite: Invite) -> Bool {
        guard invite.game == id else { return false }
        let fresh = Self.huntingRound(invite)
        if let last = current, last.number == invite.round {
            guard last.role == .hunter else { return true }   // this phone hides that round: nothing to learn
            var r = last
            r.hider = invite.hider
            r.hidden = fresh.hidden
            if r.startedAt == nil, let s = invite.started { r.startedAt = s; if r.stage == .hiding { r.stage = .live } }
            rounds[rounds.count - 1] = r
        } else if invite.round > (current?.number ?? 0) {
            rounds.append(fresh)
        }
        return true
    }

    /// A referee's line heard by this hunter. Returns the piece it was about (nil: not this round's).
    @discardableResult
    public mutating func heard(_ reply: WG.Reply, text: String = "", at t: TimeInterval) -> Int? {
        guard var round = current, round.role == .hunter, let named = reply.huntCode,
              let a = address(of: named), a.round == round.number else { return nil }
        let piece = a.piece
        func live(since start: TimeInterval) {
            if round.startedAt == nil { round.startedAt = start }
            if round.stage == .hiding { round.stage = .live }
        }
        switch reply {
        case .go:
            live(since: t)
        case .joined(_, _, _, let phase, _):
            if phase == .live, round.stage == .hiding { round.stage = .live }
        case .status(_, let phase, let minutes, _, _, _):
            if phase == .live { live(since: t - (Double(minutes) * 60 + 30)) }
            if phase == .ended { endPiece(piece, &round) }
        case .youFound(_, _, _, let proofs, let minutes):
            let proofs = proofs.map { p -> FoxReferee.Proof in p == .rfWitnessed ? .rfWitnessed : p == .rfAttested ? .rfAttested : .code }
            record(Find(piece: piece, elapsed: round.startedAt.map { max(0, t - $0) } ?? Double(minutes) * 60 + 30, proofs: proofs,
                        approximate: round.startedAt == nil), name: me, isMe: true, in: &round)
        case .someoneFound(_, let name, _, let minutes):
            guard name.uppercased() != me.uppercased() else { break }
            record(Find(piece: piece, elapsed: round.startedAt.map { max(0, t - $0) } ?? Double(minutes) * 60 + 30,
                        approximate: round.startedAt == nil), name: name.uppercased(), isMe: false, in: &round)
        case .ended(_, _, let found, let total):
            endPiece(piece, &round)
            if round.stage == .over {
                round.endedAt = t
                round.endReason = WG.isTimeUp(text) ? .time : (total > 0 && found == total ? .allFound : .host)
            }
        case .rejected(let verb, _, let reason):
            if verb.uppercased() == "JOIN", reason.uppercased() == "OVER" { endPiece(piece, &round) }
            if round.stage == .over, round.endedAt == nil { round.endedAt = t }
        default:
            break
        }
        rounds[rounds.count - 1] = round
        return piece
    }

    private func endPiece(_ piece: Int, _ round: inout Round) {
        if !round.endedPieces.contains(piece) { round.endedPieces.append(piece) }
        if pieces.allSatisfy({ round.endedPieces.contains($0.index) }) { round.stage = .over }
    }

    private func record(_ f: Find, name: String, isMe: Bool, in round: inout Round) {
        var i = round.results.firstIndex { $0.name == name }
        if i == nil { round.results.append(Result(name: name, isMe: isMe)); i = round.results.count - 1 }
        guard let i, !round.results[i].finds.contains(where: { $0.piece == f.piece }) else { return }
        round.results[i].finds.append(f)
        round.results[i].finds.sort { $0.piece < $1.piece }
    }

    /// A hunter with no radio starts the round's clock (the hider said go).
    public mutating func go(at t: TimeInterval) {
        guard var round = current, round.role == .hunter, round.startedAt == nil else { return }
        round.startedAt = t
        round.stage = .live
        rounds[rounds.count - 1] = round
    }

    public enum GuideClaim: Equatable, Sendable { case found, wrongCode, alreadyFound, notStarted, over, noSuchPiece }

    /// A hunter with no radio found `piece` and typed its label code: checked here against
    /// the invite's check, timed by this phone. The round is over for them once they have every piece.
    public mutating func claimByCode(piece: Int, code typed: String, at t: TimeInterval) -> GuideClaim {
        guard var round = current, round.role == .hunter, let i = slot(piece) else { return .noSuchPiece }
        if round.stage == .over { return .over }
        guard let start = round.startedAt else { return .notStarted }
        if round.results.first(where: { $0.isMe })?.finds.contains(where: { $0.piece == piece }) == true { return .alreadyFound }
        let c = typed.trimmingCharacters(in: .whitespaces)
        guard Self.isLabelCode(c), Self.codeCheck(game: id, piece: piece, code: c) == pieces[i].check else { return .wrongCode }
        record(Find(piece: piece, elapsed: max(0, t - start), proofs: [.code]), name: me, isMe: true, in: &round)
        if let mine = round.results.first(where: { $0.isMe }), mine.finds.count == pieces.count {
            round.stage = .over
            round.endedAt = t
            round.endReason = .allFound
        }
        rounds[rounds.count - 1] = round
        return .found
    }

    /// This phone's own finds in the current round.
    public var myFinds: [Find] { current?.results.first { $0.isMe }?.finds ?? [] }

    /// How often a hunter's app reports its node's readings of one piece (`WG SIG`, through
    /// `FoxTracker.reportIfDue`).
    public struct ReportPace: Equatable, Sendable {
        public var interval: TimeInterval
        /// A change this large (dB of RSSI) is reported at once (at least 5 s apart).
        public var jump: Double
    }

    /// The piece on screen, and any piece near its claim line (so a claim can lean on it),
    /// as often as a single hunt: every 30 s or on a 3 dB jump. The others every 2 minutes or
    /// on a 10 dB jump, so three pieces don't triple the hunt's airtime.
    public static func reportPace(focused: Bool, near: Bool) -> ReportPace {
        focused || near ? ReportPace(interval: 30, jump: 3) : ReportPace(interval: 120, jump: 10)
    }

    /// Within this many dB of a piece's claim line counts as near it (half that for SNR).
    public static let nearMargin: Double = 6

    /// A reading near or past `piece`'s claim line in the current round.
    public func isNear(piece: Int, reading: Reading) -> Bool {
        var cal = current?.hidden(piece)?.calibration ?? Calibration(reading: nil)
        cal.claimRSSI -= Self.nearMargin
        cal.claimSNR -= Self.nearMargin / 2
        return cal.isInZone(reading)
    }

    /// `reading` is past `piece`'s claim line in the current round (as far as this phone knows the line).
    public func isInZone(piece: Int, reading: Reading) -> Bool {
        (current?.hidden(piece)?.calibration ?? Calibration(reading: nil)).isInZone(reading)
    }

    // MARK: Rounds and totals

    /// Every round has been played.
    public var isOver: Bool { current?.stage == .over && (current?.number ?? 0) >= settings.rounds }

    /// The next round's number, once the current one is over (nil after the last).
    public var nextRoundNumber: Int? {
        guard let r = current, r.stage == .over, r.number < settings.rounds else { return nil }
        return r.number + 1
    }

    /// Who should hide next: the round's best hunter (most pieces, then fastest), who found
    /// the pieces and can pick them up. Nil when nobody hunted.
    public func suggestedHider(after round: Round) -> String? {
        let ranked = round.results.map { ($0, roundTime($0, in: round)) }
            .sorted { a, b in
                if a.0.finds.count != b.0.finds.count { return a.0.finds.count > b.0.finds.count }
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.name < b.0.name
            }
        return ranked.first?.0.name
    }

    /// This phone should hide the next round: it hunted this one and was its best hunter.
    public var shouldHideNext: Bool {
        guard let r = current, nextRoundNumber != nil, r.role == .hunter else { return false }
        return suggestedHider(after: r)?.uppercased() == me.uppercased()
    }

    /// Moves on to the next round, hidden by this phone (`iHide`, its referees open for joins)
    /// or by someone else (`hider`, as far as this phone knows). False when there is none.
    @discardableResult
    public mutating func nextRound(iHide: Bool, hider: String? = nil, at t: TimeInterval) -> Bool {
        guard let n = nextRoundNumber, let last = current else { return false }
        if iHide {
            rounds.append(hidingRound(n, at: t))
        } else {
            let who = hider ?? (last.role == .hider ? suggestedHider(after: last) : nil) ?? ""
            rounds.append(Round(number: n, hider: who, role: .hunter, stage: .hiding))
        }
        return true
    }

    /// A hunter's time in a round: when they had every piece, else the whole round (the time
    /// limit, or until it ended). `complete` when they found every piece.
    public func roundTime(_ result: Result, in round: Round) -> TimeInterval {
        if result.finds.count >= pieces.count, let last = result.finds.map(\.elapsed).max() { return last }
        if let s = round.startedAt, let e = round.endedAt { return min(max(0, e - s), settings.timeLimit ?? .infinity) }
        return settings.timeLimit ?? 0
    }

    public struct Standing: Equatable, Sendable {
        public var name: String
        public var isMe: Bool
        public var roundsHunted: Int
        public var found: Int
        public var possible: Int
        /// Seconds, every round hunted added up.
        public var time: TimeInterval
        /// Some of it from whole minutes heard over the radio.
        public var approximate: Bool

        public var averageTime: TimeInterval { roundsHunted > 0 ? time / Double(roundsHunted) : 0 }
    }

    /// Everyone who hunted a finished round, best first: the larger share of pieces found,
    /// then the shorter time per round hunted, then by name. As this phone saw it.
    public var standings: [Standing] {
        var by: [String: Standing] = [:]
        for round in rounds where round.stage == .over && round.startedAt != nil {
            for r in round.results {
                let key = r.name.uppercased()
                var s = by[key] ?? Standing(name: r.name, isMe: false, roundsHunted: 0, found: 0, possible: 0, time: 0, approximate: false)
                s.isMe = s.isMe || r.isMe
                s.roundsHunted += 1
                s.found += min(r.finds.count, pieces.count)
                s.possible += pieces.count
                s.time += roundTime(r, in: round)
                s.approximate = s.approximate || r.finds.contains(where: \.approximate)
                by[key] = s
            }
        }
        return by.values.sorted { a, b in
            let fa = Double(a.found) / Double(max(1, a.possible)), fb = Double(b.found) / Double(max(1, b.possible))
            if fa != fb { return fa > fb }
            if a.averageTime != b.averageTime { return a.averageTime < b.averageTime }
            return a.name < b.name
        }
    }
}

// MARK: - Reading a reply's hunt

extension WG.Reply {
    /// The hunt a referee's line is about (nil when it names none).
    public var huntCode: String? {
        switch self {
        case .joined(let h, _, _, _, _), .go(let h, _), .warmth(let h, _, _, _, _, _, _), .youFound(let h, _, _, _, _),
             .someoneFound(let h, _, _, _), .status(let h, _, _, _, _, _), .left(let h), .ended(let h, _, _, _):
            return h.uppercased()
        case .rejected(_, let h, _):
            return h?.uppercased()
        case .pong, .noHunt, .other:
            return nil
        }
    }
}
