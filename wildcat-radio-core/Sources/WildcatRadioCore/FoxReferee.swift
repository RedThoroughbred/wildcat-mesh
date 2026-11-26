import Foundation

/// The Fox Hunt referee, ported from the Den's `foxhunt.py` so a phone can
/// referee a hunt with no Den: a deterministic state machine,
/// (state, event) -> (state', outputs). Pure: no clock, no I/O; every event
/// carries its own time `t` (seconds). Replaying `events` reproduces the hunt.
///
/// It speaks WG v0 exactly as the Den does (see `WG`), so hunters can't tell
/// a phone referee from a Den.
///
/// A hunt may have a time limit: once `startedAt + timeLimit` has passed, the
/// next event ends it (at the deadline) before anything else is ruled on, and
/// `.tick` lets a host end it on time when nothing is heard. The whole referee
/// is `Codable`, so a host can save a hunt and pick it up after a restart.
public struct FoxReferee: Sendable, Equatable {
    public static let maxBadCodes = 5
    public static let attestWindow: TimeInterval = 300
    public static let sigReplyCooldown: TimeInterval = 15
    public static let bearingWindow: TimeInterval = 600
    static let placePoints = [1: 100, 2: 70, 3: 50]

    public enum Mode: String, CaseIterable, Sendable, Codable {
        /// The 4-digit code on the box.
        case code
        /// Close enough by radio is a find.
        case signal
        /// Either one.
        case either
    }

    public enum Phase: String, Sendable, Codable { case lobby, live, ended }

    public enum Source: String, Sendable, Codable {
        /// WG text over the mesh.
        case mesh
        /// Readings from the referee's own app (never answered over the radio).
        case app
    }

    /// Why a hunt ended.
    public enum EndReason: String, Sendable, Codable {
        /// The host ended it.
        case host
        /// The time limit ran out.
        case time
        /// Every hunter still in the hunt found the fox.
        case allFound
    }

    public enum Proof: String, Sendable, Codable {
        case rfWitnessed = "rf-witnessed", rfAttested = "rf-attested", code
        var wire: String { self == .rfWitnessed ? "RF-A" : self == .rfAttested ? "RF-B" : "CODE" }
        var bonus: Int { self == .rfWitnessed ? 50 : self == .rfAttested ? 25 : 0 }
    }

    public enum Event: Equatable, Sendable, Codable {
        /// `timeLimit` (seconds) counts from the start; nil, zero, negative or not finite means no limit.
        case create(t: TimeInterval, fox: NodeNum, foxCode: String, code: String = "FOX7", mode: Mode = .code,
                    thresholdRSSI: Double = -75, thresholdSNR: Double = 8, foxLabel: String? = nil,
                    channelName: String = "WGHUNT", timeLimit: TimeInterval? = nil)
        case start(t: TimeInterval)
        case end(t: TimeInterval)
        /// Time passed with nothing heard: a live hunt past its time limit ends. A tick that
        /// changes nothing is not recorded in `events`.
        case tick(t: TimeInterval)
        /// The referee's own node heard the fox.
        case foxHeard(t: TimeInterval, node: NodeNum, position: Coordinate? = nil)
        /// The referee's own node heard a hunter's position.
        case position(t: TimeInterval, node: NodeNum, position: Coordinate)
        case join(t: TimeInterval, node: NodeNum, name: String? = nil, label: String? = nil, channel: Int? = nil,
                  src: Source = .mesh)
        case leave(t: TimeInterval, node: NodeNum, channel: Int? = nil)
        case status(t: TimeInterval, node: NodeNum, channel: Int? = nil)
        case sig(t: TimeInterval, node: NodeNum, rssi: Double? = nil, snr: Double? = nil, src: Source = .mesh,
                 hops: Int? = nil, channel: Int? = nil, label: String? = nil, position: Coordinate? = nil)
        case found(t: TimeInterval, node: NodeNum, code: String = "", relayNode: UInt32? = nil, hops: Int? = nil,
                   channel: Int? = nil, label: String? = nil, src: Source = .mesh)

        var t: TimeInterval {
            switch self {
            case .create(let t, _, _, _, _, _, _, _, _, _), .start(let t), .end(let t), .tick(let t), .foxHeard(let t, _, _),
                 .position(let t, _, _), .join(let t, _, _, _, _, _), .leave(let t, _, _), .status(let t, _, _),
                 .sig(let t, _, _, _, _, _, _, _, _), .found(let t, _, _, _, _, _, _, _):
                return t
            }
        }
    }

    /// A line to send over the radio: a direct message to `to` on `channel`.
    public struct Say: Equatable, Sendable {
        public var to: NodeNum
        public var text: String
        public var channel: Int?

        public init(to: NodeNum, text: String, channel: Int?) {
            self.to = to; self.text = text; self.channel = channel
        }
    }

    public enum Output: Equatable, Sendable {
        case say(Say)
        case created, started, ended
        case joined(NodeNum), sig(NodeNum), found(NodeNum), foundRepeat(NodeNum), badCode(NodeNum)
        case error(String)

        public var say: Say? { if case .say(let s) = self { return s } else { return nil } }
    }

    public struct Sample: Equatable, Sendable, Codable {
        public var t: TimeInterval
        public var rssi: Double?
        public var snr: Double?
        public var score: Double?
        public var src: Source
        public var hops: Int?
        public var direct: Bool
        public var position: Coordinate?
    }

    public struct Find: Equatable, Sendable, Codable {
        public var place: Int
        public var t: TimeInterval
        public var clock: String
        public var proofs: [Proof]
        public var points: Int
        public var sample: Sample?
        public var elapsed: TimeInterval
    }

    public struct Bearing: Equatable, Sendable, Codable {
        public var degrees: Double
        public var per100m: Double
        public var n: Int
        public var spread: Double
    }

    public struct Hunter: Equatable, Sendable, Codable {
        public var id: NodeNum
        public var name: String
        public var joined: TimeInterval
        public var src: Source
        public var channel: Int = 0
        public var samples: [Sample] = []
        public var best: Sample?
        public var last: Sample?
        public var prev: Sample?
        public var trend = "LISTENING"
        public var lastReply: TimeInterval = -1e9
        public var badCodes = 0
        public var position: (Coordinate, TimeInterval)? { positionAt.map { ($0.position, $0.t) } }
        var positionAt: TimedPosition?
        public var found: Find?
        public var left = false

        /// Uphill bearing from this hunter's recent direct readings, if they walked enough.
        public var bearing: Bearing? {
            let since = (last?.t ?? 0) - FoxReferee.bearingWindow
            return FoxReferee.fitBearing(samples.filter { $0.direct && $0.t >= since })
        }
    }

    struct TimedPosition: Equatable, Sendable, Codable {
        var position: Coordinate
        var t: TimeInterval
    }

    public struct Hunt: Equatable, Sendable, Codable {
        public var code: String
        public var fox: NodeNum
        var foxCode: String
        public var mode: Mode
        public var thresholdRSSI: Double
        public var thresholdSNR: Double
        public var foxName: String
        public var channelName: String
        public var phase: Phase
        public var createdAt: TimeInterval
        public var startedAt: TimeInterval?
        public var endedAt: TimeInterval?
        public var foxSeen: TimeInterval?
        var foxPosition: Coordinate?
        public var winner: String?
        /// Seconds from the start until the hunt ends on its own; nil for no limit.
        public var timeLimit: TimeInterval? = nil
        /// Why it ended, once it has.
        public var endReason: EndReason? = nil

        /// When a started hunt with a time limit runs out.
        public var deadline: TimeInterval? {
            guard let timeLimit, let startedAt else { return nil }
            return startedAt + timeLimit
        }

        /// Seconds left at `now`: the whole limit before the start, counting down while
        /// live, frozen once it has ended; nil without a limit. Never negative.
        public func timeRemaining(at now: TimeInterval) -> TimeInterval? {
            guard let timeLimit else { return nil }
            guard let deadline else { return timeLimit }
            let at = phase == .ended ? (endedAt ?? now) : now
            return max(0, deadline - at)
        }
    }

    public private(set) var hunt: Hunt?
    public private(set) var hunters: [NodeNum: Hunter] = [:]
    public private(set) var finds: [NodeNum] = []
    public private(set) var events: [Event] = []

    public init() {}

    public static func replay(_ events: [Event]) -> FoxReferee {
        var r = FoxReferee()
        for e in events { r.handle(e) }
        return r
    }

    // MARK: Entry point

    @discardableResult
    public mutating func handle(_ ev: Event) -> [Output] {
        // Past the time limit, the hunt ends (at its deadline) before this event is ruled on.
        let timeUp = isTimeUp(at: ev.t)
        if case .tick = ev, !timeUp { return [] }
        events.append(ev)
        let ending = timeUp ? endOnTime() : []
        return ending + rule(ev)
    }

    /// When the time limit runs out (nil without a limit or before the start).
    public var deadline: TimeInterval? { hunt?.deadline }

    /// Seconds left at `now` (see `Hunt.timeRemaining(at:)`); nil without a hunt or a limit.
    public func timeRemaining(at now: TimeInterval) -> TimeInterval? { hunt?.timeRemaining(at: now) }

    private func isTimeUp(at t: TimeInterval) -> Bool {
        guard isLive, let deadline else { return false }
        return t >= deadline
    }

    private mutating func endOnTime() -> [Output] {
        guard let deadline else { return [] }
        return end(deadline, reason: .time)
    }

    private mutating func rule(_ ev: Event) -> [Output] {
        switch ev {
        case let .create(t, fox, foxCode, code, mode, rssi, snr, label, channelName, timeLimit):
            return create(t: t, fox: fox, foxCode: foxCode, code: code, mode: mode, rssi: rssi, snr: snr,
                          label: label, channelName: channelName, timeLimit: timeLimit)
        case .start(let t): return start(t)
        case .end(let t): return end(t, reason: .host)
        case .tick: return []
        case let .foxHeard(t, node, pos):
            if hunt != nil, node == hunt?.fox {
                hunt?.foxSeen = t
                if let pos { hunt?.foxPosition = pos }
            }
            return []
        case let .position(t, node, pos):
            hunters[node]?.positionAt = TimedPosition(position: pos, t: t)
            return []
        case let .join(t, node, name, label, channel, src): return join(t, node, name, label, channel, src)
        case let .leave(_, node, channel):
            guard hunters[node] != nil else { return [] }
            hunters[node]?.left = true
            return [say(node, "WG OK LEAVE \(code)", channel)]
        case let .status(t, node, channel): return status(t, node, channel)
        case let .sig(t, node, rssi, snr, src, hops, channel, label, pos):
            return sig(t, node, rssi, snr, src, hops, channel, label, pos)
        case let .found(t, node, codeTyped, relay, hops, channel, label, src):
            return found(t, node, codeTyped, relay, hops, channel, label, src)
        }
    }

    // MARK: Helpers

    public var code: String { hunt?.code ?? "FOX?" }

    private func say(_ to: NodeNum, _ text: String, _ channel: Int?) -> Output {
        .say(Say(to: to, text: text.utf8Prefix(WG.maxBytes), channel: channel))
    }

    private func clock(_ t: TimeInterval) -> String {
        guard let st = hunt?.startedAt else { return "T+0M" }
        return "T+\(Int(((t - st) / 60).rounded(.down)))M"
    }

    static func isValidName(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter, s.count <= 10 else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// An explicit name wins, then the roster label, then the node's last 4 hex digits.
    static func name(_ node: NodeNum, given: String?, label: String?) -> String {
        if let given, isValidName(given) { return given.uppercased() }
        let clean = (label ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        let cut = String(clean.prefix(10)).uppercased()
        return cut.isEmpty ? String(node.id.suffix(4)).uppercased() : cut
    }

    private var foxName: String { hunt.map { $0.foxName.isEmpty ? String($0.fox.id.suffix(4)) : $0.foxName } ?? "" }
    private var isLive: Bool { hunt?.phase == .live }
    private var activeCount: Int { hunters.values.filter { !$0.left }.count }

    private mutating func hunter(_ node: NodeNum, _ t: TimeInterval, name: String? = nil, src: Source = .mesh,
                                 channel: Int? = nil, label: String? = nil) -> Hunter {
        var h = hunters[node] ?? Hunter(id: node, name: Self.name(node, given: name, label: label), joined: t, src: src)
        h.left = false
        if let name, Self.isValidName(name) { h.name = name.uppercased() }
        if let channel { h.channel = channel }
        hunters[node] = h
        return h
    }

    private func thresholdOK(_ s: Sample) -> Bool {
        guard let h = hunt else { return false }
        if let rssi = s.rssi { return rssi >= h.thresholdRSSI }
        if let snr = s.snr { return snr >= h.thresholdSNR }
        return false
    }

    private func attested(_ h: Hunter, _ t: TimeInterval) -> Sample? {
        h.samples.filter { t - $0.t <= Self.attestWindow && $0.direct && thresholdOK($0) }
            .max { ($0.score ?? -1) < ($1.score ?? -1) }
    }

    /// Hunters who are told things over the radio.
    private var radioHunters: [Hunter] {
        hunters.values.filter { !$0.left && $0.src == .mesh }.sorted { $0.joined < $1.joined }
    }

    // MARK: Host events

    private mutating func create(t: TimeInterval, fox: NodeNum, foxCode: String, code: String, mode: Mode,
                                 rssi: Double, snr: Double, label: String?, channelName: String,
                                 timeLimit: TimeInterval?) -> [Output] {
        guard foxCode.count == 4, foxCode.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return [.error("the fox code must be 4 digits")]
        }
        hunt = Hunt(code: code, fox: fox, foxCode: foxCode, mode: mode, thresholdRSSI: rssi, thresholdSNR: snr,
                    foxName: Self.name(fox, given: nil, label: label), channelName: String(channelName.prefix(11)),
                    phase: .lobby, createdAt: t,
                    timeLimit: timeLimit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        hunters = [:]
        finds = []
        return [.created]
    }

    private mutating func start(_ t: TimeInterval) -> [Output] {
        guard hunt?.phase == .lobby else { return [] }
        hunt?.phase = .live
        hunt?.startedAt = t
        return radioHunters.map { say($0.id, "WG GO \(code) HUNT IS LIVE · FOX \(foxName) · SIG <rssi> <snr> · FOUND <code>", $0.channel) }
            + [.started]
    }

    private mutating func end(_ t: TimeInterval, reason: EndReason) -> [Output] {
        guard let h = hunt, h.phase != .ended else { return [] }
        hunt?.phase = .ended
        hunt?.endedAt = t
        hunt?.endReason = reason
        let found = finds.compactMap { hunters[$0] }
        hunt?.winner = found.first?.name
        var line = "WG END \(code) " + (found.first.map { "\($0.name) WINS " } ?? "NO FINDS ") + "\(found.count)/\(activeCount) FOUND"
        // A hint after the "·": the END grammar is unchanged, so every hunter still reads it.
        if reason == .time { line += " · \(WG.timeUpHint)" }
        return radioHunters.map { say($0.id, line, $0.channel) } + [.ended]
    }

    // MARK: Hunter events

    private mutating func join(_ t: TimeInterval, _ node: NodeNum, _ name: String?, _ label: String?,
                               _ channel: Int?, _ src: Source) -> [Output] {
        guard let h0 = hunt else { return [say(node, "WG NO JOIN NO HUNT", channel)] }
        if h0.phase == .ended { return [say(node, "WG NO JOIN \(code) OVER", channel)] }
        let h = hunter(node, t, name: name, src: src, channel: channel, label: label)
        let phase = isLive ? "LIVE" : "LOBBY"
        return [say(h.id, "WG OK JOIN \(code) \(h.name) \(activeCount) HUNTING \(phase) FOX \(foxName) · SIG <rssi> <snr> · FOUND <code>", h.channel),
                .joined(h.id)]
    }

    private func status(_ t: TimeInterval, _ node: NodeNum, _ channel: Int?) -> [Output] {
        guard let h = hunt else { return [say(node, "WG HUNT NONE", channel)] }
        return [say(node, "WG HUNT \(code) \(h.phase.rawValue.uppercased()) \(clock(t)) \(activeCount) HUNTERS \(finds.count) FOUND FOX \(foxName)", channel)]
    }

    public static func score(rssi: Double?, snr: Double?) -> Double? {
        if let rssi { return max(0, min(100, (rssi + 125) / 80 * 100)) }
        if let snr { return max(0, min(100, (snr + 20) / 32 * 100)) }
        return nil
    }

    private mutating func sig(_ t: TimeInterval, _ node: NodeNum, _ rssi: Double?, _ snr: Double?, _ src: Source,
                              _ hops: Int?, _ channel: Int?, _ label: String?, _ pos: Coordinate?) -> [Output] {
        guard let hh = hunt, hh.phase != .ended, node != hh.fox else { return [] }
        if rssi == nil && snr == nil {
            return src == .mesh ? [say(node, "WG NO SIG FORMAT · WG SIG -88 6.5", channel)] : []
        }
        var h = hunter(node, t, src: src, channel: channel, label: label)
        var s = Sample(t: t, rssi: rssi, snr: snr, score: Self.score(rssi: rssi, snr: snr), src: src, hops: hops,
                       direct: hops == nil || hops == 0, position: pos)
        if s.position == nil, let p = h.positionAt, t - p.t <= 120 { s.position = p.position }
        h.samples.append(s)
        if h.samples.count > 200 { h.samples.removeFirst(h.samples.count - 200) }
        guard s.direct else {
            hunters[node] = h
            return [.sig(node)]   // relayed: the RSSI is the relay's, not the fox's. Recorded, never scored.
        }
        h.prev = h.last
        h.last = s
        if h.best == nil || (s.score ?? -1) > (h.best?.score ?? -1) { h.best = s }
        h.trend = trend(h.prev, s)
        hunters[node] = h
        var out: [Output] = [.sig(node)]
        if isLive, h.found == nil, hh.mode != .code, thresholdOK(s) {
            return out + ruleFound(node, t, codeOK: false, witnessed: false)
        }
        if src == .mesh, t - h.lastReply >= Self.sigReplyCooldown {
            hunters[node]?.lastReply = t
            out.append(say(node, warmthLine(hunters[node]!), h.channel))
        }
        return out
    }

    private func trend(_ prev: Sample?, _ s: Sample) -> String {
        if thresholdOK(s) { return "HOT" }
        guard let prev else { return "FIRST" }
        let d: Double, step: Double
        if let a = s.rssi, let b = prev.rssi { (d, step) = (a - b, 3) }
        else if let a = s.snr, let b = prev.snr { (d, step) = (a - b, 1.5) }
        else { (d, step) = ((s.score ?? 0) - (prev.score ?? 0), 4) }
        return d >= step ? "WARMER" : d <= -step ? "COLDER" : "STEADY"
    }

    static func fmt(_ rssi: Double?, _ snr: Double?) -> String {
        if let rssi { return String(format: "%.0f", rssi) }
        if let snr { return "S" + String(format: "%.1f", snr) }
        return "?"
    }

    private func warmthLine(_ h: Hunter) -> String {
        guard let s = h.last, let best = h.best else { return "" }
        let arrow = h.prev.map { "\(Self.fmt($0.rssi, $0.snr))>\(Self.fmt(s.rssi, s.snr))" } ?? Self.fmt(s.rssi, s.snr)
        var line = "WG W \(code) \(h.trend) \(arrow) BEST \(Self.fmt(best.rssi, best.snr))"
        if let b = h.bearing { line += String(format: " BRG %03.0f", b.degrees) }
        if h.trend == "HOT", hunt?.mode != .signal { line += " · FOUND <code>" }
        return line
    }

    private mutating func found(_ t: TimeInterval, _ node: NodeNum, _ typed: String, _ relay: UInt32?, _ hops: Int?,
                                _ channel: Int?, _ label: String?, _ src: Source) -> [Output] {
        guard let hh = hunt else { return [say(node, "WG NO FOUND NO HUNT", channel)] }
        if hh.phase == .lobby { return [say(node, "WG NO FOUND \(code) NOT STARTED", channel)] }
        let h = hunter(node, t, src: src, channel: channel, label: label)
        if h.found != nil { return [say(node, foundLine(h), h.channel), .foundRepeat(node)] }
        if hh.phase == .ended { return [say(node, "WG NO FOUND \(code) OVER", channel)] }
        if h.badCodes >= Self.maxBadCodes { return [say(node, "WG NO FOUND \(code) LOCKED", channel)] }
        let typedCode = typed.trimmingCharacters(in: .whitespaces)
        let codeOK = typedCode == hh.foxCode
        if !typedCode.isEmpty && !codeOK {
            hunters[node]?.badCodes += 1
            return [say(node, "WG NO FOUND \(code) BADCODE \(hunters[node]!.badCodes)/\(Self.maxBadCodes)", channel), .badCode(node)]
        }
        let witnessed = relay.map { ($0 & 0xFF) == (hh.fox.raw & 0xFF) } == true && (hops ?? 0) >= 1
        let attestedNow = attested(h, t) != nil
        if !codeOK && !(hh.mode != .code && (attestedNow || witnessed)) {
            return [say(node, "WG NO FOUND \(code) NEED CODE", channel)]
        }
        return ruleFound(node, t, codeOK: codeOK, witnessed: witnessed)
    }

    private mutating func ruleFound(_ node: NodeNum, _ t: TimeInterval, codeOK: Bool, witnessed: Bool) -> [Output] {
        guard var h = hunters[node] else { return [] }
        var proofs: [Proof] = []
        if witnessed { proofs.append(.rfWitnessed) }
        let att = attested(h, t)
        if att != nil { proofs.append(.rfAttested) }
        if codeOK { proofs.append(.code) }
        let place = finds.count + 1
        let points = (Self.placePoints[place] ?? 30) + proofs.map(\.bonus).reduce(0, +)
        h.found = Find(place: place, t: t, clock: clock(t), proofs: proofs, points: points, sample: att,
                       elapsed: t - (hunt?.startedAt ?? t))
        hunters[node] = h
        finds.append(node)
        var out: [Output] = [say(node, foundLine(h), h.channel), .found(node)]
        out += radioHunters.filter { $0.id != node }.map {
            say($0.id, "WG FOUND \(code) \(h.name) #\(place) \(h.found!.clock)", $0.channel)
        }
        let active = hunters.values.filter { !$0.left }
        if !active.isEmpty, active.allSatisfy({ $0.found != nil }) { out += end(t, reason: .allFound) }
        return out
    }

    private func foundLine(_ h: Hunter) -> String {
        guard let f = h.found else { return "" }
        let tags = f.proofs.map(\.wire).joined(separator: "+")
        return "WG OK FOUND \(code) #\(f.place) +\(f.points) \(tags) \(f.clock)"
    }

    // MARK: Public view

    /// What anyone may see: never the code on the box; the fox's position only after the end.
    public struct Board: Equatable, Sendable {
        public var hunt: Hunt
        public var foxPosition: Coordinate?
        public var hunters: [Hunter]
    }

    public var board: Board? {
        guard var h = hunt else { return nil }
        let reveal = h.phase == .ended ? h.foxPosition : nil
        h.foxCode = ""
        h.foxPosition = nil
        let rows = hunters.values.sorted { a, b in
            switch (a.found, b.found) {
            case let (fa?, fb?): return fa.place < fb.place
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let sa = a.best?.score ?? -1, sb = b.best?.score ?? -1
                if sa != sb { return sa > sb }
                // Ties (no find, same best) by who joined first, so a board is the same every time.
                return a.joined != b.joined ? a.joined < b.joined : a.id < b.id
            }
        }
        return Board(hunt: h, foxPosition: reveal, hunters: rows)
    }

    // MARK: Bearing

    /// Least-squares plane `signal = a + b·east + c·north` over located samples:
    /// the uphill bearing (0 = north, clockwise), or nil when the fit means nothing.
    public static func fitBearing(_ samples: [Sample]) -> Bearing? {
        let pts = samples.compactMap { s -> (Coordinate, Double)? in
            guard let p = s.position, let sc = s.score else { return nil }
            return (p, sc)
        }
        guard pts.count >= 4, let origin = pts.last?.0 else { return nil }
        let kx = 111_320 * cos(origin.latitude * .pi / 180)
        let xy = pts.map { ((($0.0.longitude - origin.longitude) * kx), ($0.0.latitude - origin.latitude) * 110_574, $0.1) }
        let n = Double(xy.count)
        let mx = xy.map(\.0).reduce(0, +) / n, my = xy.map(\.1).reduce(0, +) / n, ms = xy.map(\.2).reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0, sxs = 0.0, sys = 0.0
        for (x, y, s) in xy {
            sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my); sxy += (x - mx) * (y - my)
            sxs += (x - mx) * (s - ms); sys += (y - my) * (s - ms)
        }
        let det = sxx * syy - sxy * sxy
        let spread = ((sxx + syy) / n).squareRoot()
        guard spread >= 15, det > 1e-6 else { return nil }
        let gx = (sxs * syy - sys * sxy) / det
        let gy = (sys * sxx - sxs * sxy) / det
        let mag = (gx * gx + gy * gy).squareRoot()
        guard mag >= 1e-4 else { return nil }
        let deg = (atan2(gx, gy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return Bearing(degrees: deg, per100m: mag * 100, n: xy.count, spread: spread)
    }

    // MARK: Wire

    /// "WG SIG FOX7 -88 6" -> ("SIG", ["-88", "6"]); a leading hunt code is dropped.
    public static func parseCommand(_ text: String) -> (verb: String, args: [String])? {
        let t = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard t.count >= 2, t[0].uppercased() == "WG" else { return nil }
        let verb = t[1].uppercased()
        guard ["JOIN", "SIG", "FOUND", "HUNT", "LEAVE"].contains(verb) else { return nil }
        var args = Array(t.dropFirst(2))
        if let first = args.first, isHuntCode(first) { args.removeFirst() }
        return (verb, args)
    }

    /// The hunt a command names ("WG SIG FOX7 -88" -> "FOX7"), nil when it names none.
    /// A referee ignores commands meant for another hunt.
    public static func huntCode(in text: String) -> String? {
        let t = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parseCommand(text) != nil, t.count >= 3, isHuntCode(t[2]) else { return nil }
        return t[2].uppercased()
    }

    private static func isHuntCode(_ s: String) -> Bool {
        s.uppercased().hasPrefix("FOX") && (4...7).contains(s.count)
            && s.dropFirst(3).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// "-88" · "-88 6.5" · "-88dBm 6.5dB" · "SNR 6.5" · "S6.5" · "R-88". A lone bare number
    /// ≤ -30 is RSSI, otherwise SNR. Out-of-range values are dropped.
    public static func parseSig(_ args: [String]) -> (rssi: Double?, snr: Double?) {
        var rssi: Double?, snr: Double?, forceSNR = false, bare: [Double] = []
        for tok in args {
            let u = tok.uppercased()
            if u == "SNR" { forceSNR = true; continue }
            if u == "RSSI" { continue }
            var body = Substring(u), pre = "", unit = ""
            if body.hasPrefix("S") || body.hasPrefix("R") { pre = String(body.removeFirst()) }
            if body.hasSuffix("DBM") { unit = "DBM"; body = body.dropLast(3) }
            else if body.hasSuffix("DB") { unit = "DB"; body = body.dropLast(2) }
            guard body.range(of: #"^[+-]?\d+(\.\d+)?$"#, options: .regularExpression) != nil, let v = Double(body) else { continue }
            if pre == "R" || unit == "DBM" { rssi = v }
            else if pre == "S" || unit == "DB" || forceSNR { snr = v }
            else { bare.append(v) }
        }
        for v in bare {
            if rssi == nil && snr == nil && v <= -30 { rssi = v }
            else if rssi != nil && snr == nil { snr = v }
            else if rssi == nil && snr == nil { snr = v }
        }
        if let r = rssi, !(-140 ... -5).contains(r) { rssi = nil }
        if let s = snr, !(-30...30).contains(s) { snr = nil }
        return (rssi, snr)
    }

    /// A WG text packet heard by the referee's node -> an event (nil when it isn't a hunt command).
    public static func event(from p: MeshPacket, text: String, label: String?, at t: TimeInterval) -> Event? {
        guard let (verb, args) = parseCommand(text) else { return nil }
        let ch = p.channel
        switch verb {
        case "JOIN": return .join(t: t, node: p.from, name: args.first, label: label, channel: ch)
        case "LEAVE": return .leave(t: t, node: p.from, channel: ch)
        case "HUNT": return .status(t: t, node: p.from, channel: ch)
        case "FOUND":
            return .found(t: t, node: p.from, code: args.first ?? "", relayNode: p.relayNode,
                          hops: p.hops, channel: ch, label: label)
        default:
            let (rssi, snr) = parseSig(args)
            // A typed reading: what the hunter's node heard from the fox, not this packet's link.
            return .sig(t: t, node: p.from, rssi: rssi, snr: snr, hops: nil, channel: ch, label: label)
        }
    }
}

// MARK: - Saving

/// The whole referee, so a host can save a hunt and carry on after a restart: restoring
/// and handling the same events gives exactly the outputs and board the original would.
/// Hunters are saved as a list in node order (the code on the box is saved too: keep the
/// file private to the host).
extension FoxReferee: Codable {
    private enum CodingKeys: String, CodingKey { case hunt, hunters, finds, events }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hunt = try c.decodeIfPresent(Hunt.self, forKey: .hunt)
        let list = try c.decode([Hunter].self, forKey: .hunters)
        hunters = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        finds = try c.decode([NodeNum].self, forKey: .finds)
        events = try c.decode([Event].self, forKey: .events)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hunt, forKey: .hunt)
        try c.encode(hunters.values.sorted { $0.id < $1.id }, forKey: .hunters)
        try c.encode(finds, forKey: .finds)
        try c.encode(events, forKey: .events)
    }
}
