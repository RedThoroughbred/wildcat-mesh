import Foundation
import Observation
import WildcatRadioCore

/// One hunter's Fox Hunt: joins the referee (a host's phone or a Den) with WG
/// text on the WGHUNT channel, turns the hunter's own node's packets from the
/// fox into a live meter, reports readings to the referee, and claims the find
/// with the code.
@MainActor
@Observable
final class HuntModel {
    enum Stage: Equatable {
        case idle
        /// JOIN sent, waiting for the referee.
        case joining
        case hunting
        case found(place: Int, points: Int, proofs: [WG.Proof], minutes: Int)
        case ended(winner: String?, found: Int, total: Int)

        var isActive: Bool {
            switch self {
            case .joining, .hunting, .found: return true
            default: return false
            }
        }
    }

    struct LogLine: Identifiable, Equatable {
        enum Direction: Equatable { case sent, received, note }
        let id = UUID()
        let time: Date
        let direction: Direction
        let text: String
    }

    static let huntChannelName = "WGHUNT"
    static let codeKey = "hunt.code"
    static let nameKey = "hunt.name"

    var huntCode: String {
        didSet { defaults.set(huntCode, forKey: Self.codeKey) }
    }
    var playerName: String {
        didSet { defaults.set(playerName, forKey: Self.nameKey) }
    }

    private(set) var stage: Stage = .idle
    private(set) var fox: NodeNum?
    /// What the referee calls the fox ("6b18" or a name) until it is matched to a node.
    private(set) var foxHint: String?
    private(set) var tracker: FoxTracker?
    /// The referee's latest warmer/colder line.
    private(set) var warmth: WG.Reply?
    /// The referee's answer to "Ask the host", in words.
    private(set) var refereeStatus: String?
    /// A short message for the player (a rejection, someone else's find).
    private(set) var notice: String?
    private(set) var log: [LogLine] = []
    /// The node that sends the referee's replies, once one has arrived.
    private(set) var den: NodeNum?
    /// The player's own find, kept after the hunt ends.
    private(set) var myFind: (place: Int, points: Int, proofs: [WG.Proof], minutes: Int)?
    /// The hunt's time limit in seconds, when the invite said (nil: none, or joined by code).
    private(set) var timeLimit: TimeInterval?
    /// When the time runs out, by this phone's clock: from the GO, or from the referee's
    /// status when joining a hunt already live (to the half minute).
    private(set) var deadline: Date?
    /// The referee's last word on the hunt's phase (lobby, live, ended).
    private(set) var refereePhase: WG.Phase?
    /// The referee said the hunt ended because time ran out.
    private(set) var endedOnTime = false

    private let radio: Radio
    private let defaults: UserDefaults
    var clock: () -> Date = Date.init
    /// How long "Waiting for the referee…" lasts before giving up (LoRa is slow, hops add up).
    var joinTimeout: Duration = .seconds(45)
    @ObservationIgnored private var joinWait: Task<Void, Never>?

    init(radio: Radio, defaults: UserDefaults = .standard) {
        self.radio = radio
        self.defaults = defaults
        huntCode = defaults.string(forKey: Self.codeKey) ?? "FOX7"
        playerName = defaults.string(forKey: Self.nameKey) ?? ""
        radio.onEvent = { [weak self] in self?.handle($0) }
        radio.onDiagnostic = { [weak self] in self?.append(.note, $0) }
    }

    // MARK: Channel

    /// The WGHUNT channel on the player's node, if it has one.
    var huntChannel: Int? { radio.session.channelIndex(named: Self.huntChannelName) }

    /// Where WG goes: WGHUNT, else the primary channel.
    private var sendChannel: Int { huntChannel ?? 0 }

    // MARK: Actions

    func join() {
        guard radio.isReady else { return }
        notice = nil
        stage = .joining
        send(.join(hunt: huntCode, name: playerName.isEmpty ? nil : playerName))
        joinWait?.cancel()
        joinWait = Task { [weak self, joinTimeout] in
            try? await Task.sleep(for: joinTimeout)
            guard !Task.isCancelled, let self, self.stage == .joining else { return }
            self.stage = .idle
            self.notice = "No answer from the hunt. Check the code and that you're in range of the host, then try again."
        }
    }

    /// Stop waiting for the referee's answer (a late answer still joins).
    func cancelJoin() {
        joinWait?.cancel()
        if stage == .joining { stage = .idle }
    }

    /// Asks the referee how the hunt is going ("WG HUNT").
    func askHost() { send(.status) }

    func claim(code: String) {
        send(.found(hunt: currentHunt, code: code.trimmingCharacters(in: .whitespaces)))
    }

    func leave() {
        if stage.isActive { send(.leave) }
        reset()
    }

    func reset() {
        stage = .idle
        fox = nil
        foxHint = nil
        tracker = nil
        warmth = nil
        notice = nil
        myFind = nil
        timeLimit = nil
        deadline = nil
        refereePhase = nil
        endedOnTime = false
    }

    /// The player picks the fox by hand (the referee's hint matched no node).
    func choose(fox node: NodeNum) {
        fox = node
        tracker = FoxTracker(fox: node)
    }

    /// Joins from a host's invite: its hunt code, its fox by node number and its time limit.
    func join(invite: HuntInvite) {
        reset()
        huntCode = invite.code
        timeLimit = invite.timeLimit
        choose(fox: invite.foxNode)
        join()
    }

    /// Seconds left at `now`: the whole limit until the GO, then counting down; nil when
    /// there's no limit, or the hunt is live and its start isn't known yet.
    func timeRemaining(at now: Date) -> TimeInterval? {
        guard let timeLimit else { return nil }
        if let deadline { return max(0, deadline.timeIntervalSince(now)) }
        if refereePhase == .live || refereePhase == .ended { return nil }
        return timeLimit
    }

    /// Nodes the player could pick as the fox (everything but their own).
    var candidateFoxes: [NodeInfo] {
        let me = radio.session.myNode
        return radio.session.nodes.values.filter { $0.num != me }.sorted { ($0.shortName ?? "") < ($1.shortName ?? "") }
    }

    func foxLabel() -> String? {
        guard let fox else { return foxHint }
        return radio.session.label(for: fox)
    }

    private var currentHunt: String { huntCode.uppercased() }

    /// When this phone also referees the hunt, commands go straight to it.
    @ObservationIgnored var localReferee: ((WG.Command) -> Bool)?

    /// A ruling from this phone's own referee.
    func receive(localReply text: String) {
        guard let reply = WG.Reply(text) else { return }
        append(.received, text)
        apply(reply, text: text)
    }

    private func send(_ command: WG.Command) {
        if localReferee?(command) == true {
            append(.sent, command.text)
            return
        }
        let text = command.text
        radio.send(text, channel: sendChannel)
        append(.sent, text)
    }

    /// A line in the radio log from elsewhere (e.g. the MeshCore link).
    func note(_ text: String) { append(.note, text) }

    private func append(_ d: LogLine.Direction, _ text: String) {
        let line = LogLine(time: clock(), direction: d, text: text)
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
        Self.persist(line)
    }

    /// Also to Library/Caches/wildcat-log.txt (buffered, capped: see DebugLog).
    private static func persist(_ line: LogLine) {
        let mark: String
        switch line.direction {
        case .sent: mark = ">"
        case .received: mark = "<"
        case .note: mark = "#"
        }
        DebugLog.append("\(line.time.formatted(.iso8601)) \(mark) \(line.text)\n")
    }

    // MARK: Radio events

    func handle(_ event: MeshSession.Event) {
        switch event {
        case .ready:
            append(.note, "Node ready" + (huntChannel == nil ? " (no WGHUNT channel)" : ""))
            if let hint = foxHint, fox == nil { resolveFox(hint) }
        case .myNode:
            break
        case .packet(let p):
            handle(packet: p)
        }
    }

    private func handle(packet p: MeshPacket) {
        let now = clock()
        if p.from == radio.session.myNode { return }
        if tracker != nil, case .hunting = stage {
            if tracker?.ingest(p, at: now) != nil, let sig = tracker?.reportIfDue(hunt: currentHunt, at: now) {
                send(sig)
            }
        } else {
            tracker?.ingest(p, at: now)
        }
        guard let text = p.text, let reply = WG.Reply(text) else { return }
        // A Hunt game's pieces (FOXK711…) are the game's, not this single hunt's.
        if let code = reply.huntCode, HuntGame.isPieceCode(code), code != currentHunt { return }
        // Only replies meant for everyone or for us.
        if !p.isBroadcast, let me = radio.session.myNode, p.to != me { return }
        append(.received, text)
        den = p.from
        apply(reply, text: text)
    }

    /// `text`: the line as received, for the hints after its "·" (e.g. TIME UP).
    func apply(_ reply: WG.Reply, text: String = "") {
        switch reply {
        case .joined(let hunt, _, _, let phase, let foxName):
            huntCode = hunt
            stage = .hunting
            refereePhase = phase
            // A fox chosen from an invite (by node number) beats the referee's name for it.
            if fox == nil { resolveFox(foxName) } else { foxHint = foxName }
            // Joined a timed hunt already under way: ask how long it has been running.
            if phase == .live, timeLimit != nil, deadline == nil { send(.status) }
        case .go(let hunt, let foxName):
            huntCode = hunt
            if stage == .joining || stage == .idle { stage = .hunting }
            if !foxName.isEmpty, fox == nil { resolveFox(foxName) }
            refereePhase = .live
            if let timeLimit, deadline == nil { deadline = clock().addingTimeInterval(timeLimit) }
            notice = "The hunt is live."
        case .warmth:
            warmth = reply
        case .youFound(_, let place, let points, let proofs, let minutes):
            stage = .found(place: place, points: points, proofs: proofs, minutes: minutes)
            myFind = (place, points, proofs, minutes)
            notice = nil
        case .someoneFound(_, let name, let place, let minutes):
            notice = "\(name) found the fox, #\(place) after \(minutes) min."
        case .ended(_, let winner, let found, let total):
            stage = .ended(winner: winner, found: found, total: total)
            refereePhase = .ended
            endedOnTime = WG.isTimeUp(text)
        case .status(let hunt, let phase, let minutes, let hunters, let found, let foxName):
            refereeStatus = "\(hunt) · \(phase.rawValue.lowercased()) · \(minutes) min · \(hunters) hunting · \(found) found"
            if !huntCode.isEmpty, stage == .idle { huntCode = hunt }
            if fox == nil, stage.isActive { resolveFox(foxName) }
            if stage.isActive {
                refereePhase = phase
                // "T+12M" is whole minutes run: take the middle of that minute.
                if phase == .live, let timeLimit, deadline == nil {
                    deadline = clock().addingTimeInterval(timeLimit - (Double(minutes) * 60 + 30))
                }
            }
        case .noHunt:
            refereeStatus = "No hunt is running."
            if stage == .joining { stage = .idle }
        case .left:
            reset()
        case .rejected(let verb, _, let reason):
            notice = Self.explain(verb: verb, reason: reason)
            if verb == "JOIN" { stage = .idle }
        case .pong, .other:
            break
        }
    }

    /// The fox by the referee's short hex ("6b18") or its name ("ZEUZ").
    private func resolveFox(_ hint: String) {
        foxHint = hint
        let h = hint.lowercased()
        let nodes = radio.session.nodes.values
        let match = nodes.first { $0.num.id.hasSuffix(h) && h.count == 4 && h.allSatisfy(\.isHexDigit) }
            ?? nodes.first { ($0.shortName ?? "").lowercased() == h || ($0.longName ?? "").lowercased() == h }
        if let match, fox != match.num { choose(fox: match.num) }
    }

    static func explain(verb: String, reason: String) -> String {
        let r = reason.uppercased()
        if r.hasPrefix("BADCODE") {
            let tries = r.split(separator: " ").last.map(String.init) ?? ""
            return "Wrong code (\(tries) tries used)."
        }
        switch r {
        case "LOCKED": return "Too many wrong codes. You're locked out of this hunt."
        case "NOT STARTED": return "The hunt hasn't started yet."
        case "OVER": return "That hunt is over."
        case "NEED CODE": return "Enter the code written on the fox."
        case "NO HUNT": return "No hunt with that code is running."
        case "FORMAT": return "The host didn't understand that reading."
        default: return "The host said no: \(verb) \(reason)"
        }
    }
}
