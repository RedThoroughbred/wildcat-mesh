import CoreLocation
import Foundation
import Observation
import WildcatRadioCore

/// Hunt for 2–3 friends on this phone (Small Play 2): the core's `HuntGame` wired to the
/// radio, the phone's position and a save file. The rules live in the core; this draws
/// nothing and decides nothing beyond when to send.
///
/// - Hiding: this phone's node hears each piece as it is carried and set down (the hide walk
///   calibrates from it); in the round, every piece's referee answers hunters over the radio,
///   spaced like `PhoneReferee`.
/// - Hunting with a node: joins every piece, reports its readings (the piece on screen more
///   often), keeps the referee's lines, claims.
/// - Hunting with no node: the GPS guide from the invite's spots, claims by the label code.
@MainActor
@Observable
final class GamePlay {
    private(set) var game: HuntGame?
    /// Hunting with no node: the GPS guide stands in for the signal.
    private(set) var guide = false
    /// Bumps on every change so views refresh.
    private(set) var revision = 0
    var error: String?
    /// A short line for the player (a find, a refusal).
    var notice: String?
    /// The game was picked up from a save at launch.
    private(set) var resumed = false
    /// This phone's node hearing each piece, by piece number.
    private(set) var trackers: [Int: FoxTracker] = [:]
    /// The referee's latest warmer/colder line for each piece.
    private(set) var warmth: [Int: WG.Reply] = [:]
    /// Pieces whose referee answered this hunter's JOIN.
    private(set) var joined: Set<Int> = []
    private(set) var joining = false
    /// The piece the hunter's board shows big.
    var focus = 1
    /// The GPS guide's latest reading and trend per piece.
    private(set) var scent: [Int: ScentGuide.Reading] = [:]
    private(set) var scentTrend: [Int: FoxTracker.Trend] = [:]
    /// The hunter's walk this round.
    private(set) var walked: Double = 0
    private(set) var trail: [Coordinate] = []
    /// Every ruling sent, newest last.
    private(set) var sent: [FoxReferee.Say] = []
    /// The hider's invite QR is showing (the game screen presents it, so it survives the setup giving way to the hide walk).
    var inviteShown = false

    let location = GameLocation()
    var clock: () -> Date = Date.init
    /// The guide's noise, -1...1 (tests pin it).
    @ObservationIgnored var noise: () -> Double = { Double.random(in: -1...1) }

    @ObservationIgnored private let radio: Radio
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let saveURL: URL?
    @ObservationIgnored private let saver = Debouncer(.seconds(1))
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var queue: [FoxReferee.Say] = []
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var lastSentTo: [NodeNum: Date] = [:]
    @ObservationIgnored private var askedStatus = false
    @ObservationIgnored private var lastScent: Date?
    static let tickInterval: Duration = .seconds(5)
    /// The guide reads the GPS at most this often, so it doesn't flicker.
    static let scentInterval: TimeInterval = 8

    init(radio: Radio, defaults: UserDefaults = .standard, saveURL: URL? = GameSave.defaultURL, now: Date = Date()) {
        self.radio = radio
        self.defaults = defaults
        self.saveURL = saveURL
        radio.addListener { [weak self] in self?.handle($0) }
        location.onFix = { [weak self] in self?.moved($0) }
        if let saveURL, let save = GameSave.load(from: saveURL, now: now) {
            game = save.game
            guide = save.guide
            resumed = true
            resetRound()
            updateTicking()
        }
    }

    private var now: TimeInterval { clock().timeIntervalSince1970 }

    // MARK: Reading the game

    var round: HuntGame.Round? { game?.current }
    var isHider: Bool { round?.role == .hider }
    /// A game that isn't over.
    var isActive: Bool { game.map { !$0.isOver } ?? false }

    func piece(_ index: Int) -> HuntGame.Piece? { game?.pieces.first { $0.index == index } }
    func pieceName(_ index: Int) -> String { piece(index)?.name ?? "PIECE \(index)" }

    /// One of this game's hunt codes (so the single Fox Hunt leaves its lines alone).
    func owns(huntCode: String) -> Bool { game?.owns(huntCode: huntCode) ?? false }

    /// The name hunters' referees know this phone by: the name typed for Fox Hunt, else the node's short name.
    var playerName: String {
        let typed = WG.sanitizedName(defaults.string(forKey: HuntModel.nameKey) ?? "")
        if !typed.isEmpty { return typed }
        if let me = radio.session.myNode, let short = radio.session.nodes[me]?.shortName {
            let s = WG.sanitizedName(short)
            if !s.isEmpty { return s }
        }
        return "PLAYER"
    }

    var huntChannel: Int? { radio.session.channelIndex(named: HuntModel.huntChannelName) }

    /// The hunt channel's settings, key included, for the invite (the practice mesh has none to read).
    var huntChannelSettings: Data? {
        guard let index = huntChannel else { return nil }
        return radio.session.channels[index]?.settings
            ?? (radio.source == .practice ? ChannelSettings(name: HuntModel.huntChannelName, psk: Data([1])).raw : nil)
    }

    /// The invite for the round this phone hides.
    var invite: HuntGame.Invite? {
        guard let me = radio.session.myNode, let channel = huntChannelSettings else { return nil }
        return game?.invite(host: me, channel: channel)
    }

    /// Nodes that could be pieces: every node this phone's node has heard but its own, latest first.
    var candidates: [NodeInfo] {
        let me = radio.session.myNode
        return radio.session.nodes.values.filter { $0.num != me }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
    }

    // MARK: Hiding

    /// A new game hidden by this phone first. False with `error` set when it can't start.
    @discardableResult
    func host(pieces nodes: [NodeNum], rounds: Int, limitMinutes: Int, mode: FoxReferee.Mode) -> Bool {
        error = nil
        guard radio.isReady else { error = "Connect your node first: it referees the hunt."; return false }
        guard huntChannelSettings != nil else {
            error = "Your node needs the WGHUNT channel: hunters talk to you on it."
            return false
        }
        let pieces = nodes.map { n in
            HuntGame.NewPiece(node: n, name: radio.session.nodes[n]?.shortName ?? radio.session.nodes[n]?.longName ?? n.short,
                              code: FoxCode.random())
        }
        do {
            let g = try HuntGame(hosting: String(UUID().uuidString.prefix(8)).lowercased(), code: HostPhoneView.randomCode(),
                                 me: playerName, pieces: pieces,
                                 settings: .init(rounds: rounds, timeLimit: limitMinutes > 0 ? TimeInterval(limitMinutes) * 60 : nil, mode: mode),
                                 channelName: HuntModel.huntChannelName, at: now)
            start(game: g, guide: false)
            return true
        } catch let e as HuntGame.SetupError {
            error = Self.explain(e)
            return false
        } catch {
            return false
        }
    }

    static func explain(_ e: HuntGame.SetupError) -> String {
        switch e {
        case .badGameCode: return "That game code doesn't work. Try again."
        case .noPieces: return "Pick at least one piece to hide."
        case .tooManyPieces: return "Three pieces at most."
        case .samePieceTwice: return "Each piece once."
        case .badLabelCode: return "Label codes are 4 digits."
        case .noName: return "Type your name in Fox Hunt first."
        }
    }

    /// The label code of a piece, typed by a hider who swapped in (checked against the game).
    @discardableResult
    func learnCode(piece: Int, code: String) -> Bool {
        let ok = game?.learnCode(piece: piece, code: code) ?? false
        if ok { changed() }
        return ok
    }

    /// The piece's latest reading by this phone's node, if in the last two minutes.
    func reading(_ piece: Int) -> FoxTracker.Sample? {
        guard let s = trackers[piece]?.latest, clock().timeIntervalSince(s.time) < 120 else { return nil }
        return s
    }

    /// "Hidden here": the phone's spot and this phone's node's readings from right beside it.
    @discardableResult
    func hide(piece: Int) async -> Bool {
        guard game?.isHiding == true else { return false }
        let fix = await location.current()
        let t = now
        let samples = (trackers[piece]?.samples ?? []).map {
            (t: $0.time.timeIntervalSince1970, reading: HuntGame.Reading(rssi: $0.rssi.map(Double.init), snr: $0.snr))
        }
        var rng = SystemRandomNumberGenerator()
        let ok = game?.hide(piece: piece, spot: fix.map(GameLocation.coordinate), reading: HuntGame.calibrationReading(samples, at: t),
                            offset: ScentGuide.randomOffset(using: &rng), at: t) ?? false
        if ok { changed() }
        return ok
    }

    /// Starts the round once every piece is hidden.
    func start() {
        guard game?.canStart == true else { return }
        deliver(game?.start(at: now) ?? [])
    }

    /// Ends the round this phone hides, for everyone.
    func endRound() { deliver(game?.endRound(at: now) ?? []) }

    // MARK: Hunting

    /// Joins a round from a hider's invite: the same game carries on (a later round), another starts fresh.
    func join(invite: HuntGame.Invite) {
        if var g = game, g.merge(invite) {
            let newRound = g.current?.number != game?.current?.number
            game = g
            if newRound { resetRound() }
        } else {
            start(game: HuntGame(joining: invite, me: playerName), guide: !radio.isReady)
            return
        }
        guide = !radio.isReady
        changed()
        if !guide { joinRound() }
    }

    /// Sends JOIN for every piece of the round not yet answered (a second or so apart).
    func joinRound() {
        guard let g = game, let r = g.current, r.role == .hunter, r.stage != .over, radio.isReady else { return }
        let codes = g.pieces.filter { !joined.contains($0.index) }.map { g.huntCode(round: r.number, piece: $0.index) }
        guard !codes.isEmpty else { return }
        joining = true
        notice = nil
        Task { [weak self] in
            for (i, code) in codes.enumerated() {
                if i > 0 { try? await Task.sleep(for: .milliseconds(1200)) }
                guard let self, self.game?.id == g.id else { return }
                self.send(.join(hunt: code, name: g.me))
            }
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.joining else { return }
            self.joining = false
            if let missing = self.game?.pieces.first(where: { !self.joined.contains($0.index) }), self.round?.stage != .over {
                self.notice = "No answer yet for \(missing.name). The hider may still be hiding it: try Join again in a minute."
            }
        }
    }

    /// A hunter with no node starts the round's clock when the hider says go.
    func go() {
        game?.go(at: now)
        changed()
    }

    /// Claims a piece over the radio: the latest reading first (a signal claim leans on it), then FOUND.
    func claim(piece: Int, code: String?) {
        guard let g = game, let r = g.current, r.role == .hunter else { return }
        let hunt = g.huntCode(round: r.number, piece: piece)
        if let s = reading(piece) {
            send(.sig(hunt: hunt, WG.Signal(rssi: s.rssi, snr: s.snr.map { ($0 * 10).rounded() / 10 })))
        }
        send(.found(hunt: hunt, code: code.flatMap { $0.isEmpty ? nil : $0 }))
    }

    /// A hunter with no node claims by the label code, checked on this phone.
    func claimByCode(piece: Int, code: String) -> HuntGame.GuideClaim {
        let result = game?.claimByCode(piece: piece, code: code, at: now) ?? .noSuchPiece
        if result == .found { notice = "You found \(pieceName(piece))!" }
        changed()
        return result
    }

    /// The player is in the claim zone of `piece` by their own node (or the referee said HOT).
    func isInZone(_ piece: Int) -> Bool {
        if case .warmth(_, .hot, _, _, _, _, _)? = warmth[piece] { return true }
        guard let s = reading(piece), let g = game else { return false }
        return g.isInZone(piece: piece, reading: .init(rssi: s.rssi.map(Double.init), snr: s.snr))
    }

    // MARK: Between rounds

    /// On to the next round: this phone hides it, or hunts it (joining its pieces when it can).
    func nextRound(iHide: Bool) {
        guard game?.nextRound(iHide: iHide, at: now) == true else { return }
        resetRound()
        if iHide { guide = false }
        changed()
        if !iHide, !guide { joinRound() }
    }

    /// Ends the game on this phone (a round it hides ends first, so hunters hear it).
    func endGame() {
        if isHider, round?.stage != .over { endRound() }
        else if round?.role == .hunter, round?.stage != .over, !guide, radio.isReady { send(.leave) }
        game = nil
        guide = false
        resumed = false
        resetRound()
        revision += 1
        saver.cancel()
        updateTicking()
        if let saveURL { GameSave.remove(at: saveURL) }
    }

    private func start(game g: HuntGame, guide: Bool) {
        game = g
        self.guide = guide
        resumed = false
        error = nil
        notice = nil
        resetRound()
        changed()
        if !guide, g.current?.role == .hunter { joinRound() }
    }

    /// Forgets what this phone heard in the last round.
    private func resetRound() {
        trackers = Dictionary(uniqueKeysWithValues: (game?.pieces ?? []).map { ($0.index, FoxTracker(fox: $0.node)) })
        warmth = [:]
        joined = []
        joining = false
        scent = [:]
        scentTrend = [:]
        walked = 0
        trail = []
        askedStatus = false
        lastScent = nil
        focus = game?.pieces.first?.index ?? 1
    }

    // MARK: Radio

    /// A radio event (the radio calls this; tests too).
    func handle(_ e: MeshSession.Event) {
        switch e {
        case .ready:
            // Picked up from a save: hunters join their round's pieces again.
            if round?.role == .hunter, round?.stage != .over, !guide, joined.isEmpty { joinRound() }
        case .packet(let p):
            handle(packet: p)
        case .myNode:
            break
        }
    }

    private func handle(packet p: MeshPacket) {
        guard let g = game, let r = g.current, p.from != radio.session.myNode else { return }
        let t = now
        if let piece = g.piece(node: p.from), let s = trackers[piece]?.ingest(p, at: clock()) {
            if r.role == .hunter { report(piece, s) }
            revision += 1
        }
        if r.role == .hider { referee(p, at: t) } else { heard(p, at: t) }
    }

    /// A hider's referees rule on what their node heard.
    private func referee(_ p: MeshPacket, at t: TimeInterval) {
        guard let g = game else { return }
        var out: [HuntGame.Output] = []
        if let piece = g.piece(node: p.from) {
            out += game?.handle(.foxHeard(t: t, node: p.from, position: p.position), piece: piece) ?? []
        } else if let pos = p.position {
            out += game?.handleAll(.position(t: t, node: p.from, position: pos)) ?? []
        }
        var ruled = false
        if let text = p.text, let pieces = g.pieces(forCommand: text),
           let ev = FoxReferee.event(from: p, text: text, label: radio.session.nodes[p.from]?.shortName, at: t) {
            DebugLog.append("\(clock().formatted(.iso8601)) < \(text)\n")
            for piece in pieces { out += game?.handle(ev, piece: piece) ?? [] }
            ruled = true
        }
        if !out.isEmpty || ruled { deliver(out) }
    }

    /// A hunter's own readings of a piece go to its referee, paced by the core.
    private func report(_ piece: Int, _ s: FoxTracker.Sample) {
        guard !guide, let g = game, let r = g.current, r.stage == .live, joined.contains(piece) else { return }
        let pace = HuntGame.reportPace(focused: piece == focus,
                                       near: g.isNear(piece: piece, reading: .init(rssi: s.rssi.map(Double.init), snr: s.snr)))
        trackers[piece]?.reportInterval = pace.interval
        trackers[piece]?.reportJump = pace.jump
        if let cmd = trackers[piece]?.reportIfDue(hunt: g.huntCode(round: r.number, piece: piece), at: clock()) { send(cmd) }
    }

    /// A referee's line to this hunter.
    private func heard(_ p: MeshPacket, at t: TimeInterval) {
        guard let text = p.text, let reply = WG.Reply(text), let code = reply.huntCode, owns(huntCode: code) else { return }
        if !p.isBroadcast, let me = radio.session.myNode, p.to != me { return }
        receive(reply, text: text, at: t)
    }

    /// Applies a referee's line (also used by tests).
    func receive(_ reply: WG.Reply, text: String, at t: TimeInterval) {
        guard let piece = game?.heard(reply, text: text, at: t) else { return }
        DebugLog.append("\(clock().formatted(.iso8601)) < \(text)\n")
        let name = pieceName(piece)
        switch reply {
        case .joined(_, _, _, let phase, _):
            joined.insert(piece)
            if joined.count == game?.pieces.count { joining = false }
            // Joined a round already under way: ask how long it has been running.
            if phase == .live, round?.startedAt == nil, !askedStatus {
                askedStatus = true
                send(.status)
            }
        case .go:
            joined.insert(piece)
            notice = "Round \(round?.number ?? 1) is live. Go!"
        case .warmth:
            warmth[piece] = reply
        case .youFound:
            notice = "You found \(name)!"
        case .someoneFound(_, let who, _, _):
            notice = "\(who) found \(name)."
        case .rejected(let verb, _, let reason):
            notice = "\(name): " + HuntModel.explain(verb: verb, reason: reason)
        default:
            break
        }
        changed()
    }

    private func send(_ command: WG.Command) {
        let text = command.text
        radio.send(text, channel: huntChannel ?? 0)
        DebugLog.append("\(clock().formatted(.iso8601)) > \(text)\n")
    }

    // MARK: Position

    private func moved(_ l: CLLocation) {
        guard let r = round, r.role == .hunter, r.stage == .live, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 50 else { return }
        let c = GameLocation.coordinate(l)
        if let last = trail.last {
            let step = ScentGuide.distance(last, c)
            guard step >= 4 else { return }
            if step < 200 { walked += step }
        }
        trail.append(c)
        if trail.count > 2000 { trail.removeFirst(trail.count - 2000) }
        if guide { sampleScent(l) }
    }

    /// The guide's reading of every piece from where the phone is (at most every `scentInterval`).
    private func sampleScent(_ l: CLLocation, force: Bool = false) {
        guard let g = game, let r = g.current else { return }
        let date = clock()
        if !force, let last = lastScent, date.timeIntervalSince(last) < Self.scentInterval { return }
        lastScent = date
        let phone = GameLocation.coordinate(l)
        for p in g.pieces {
            guard let spot = r.hidden(p.index)?.sharedSpot,
                  let reading = ScentGuide.reading(phone: phone, accuracy: l.horizontalAccuracy, spot: spot, noise: noise()) else { continue }
            scentTrend[p.index] = ScentGuide.trend(scent[p.index], reading)
            scent[p.index] = reading
        }
        revision += 1
    }

    /// Reads the guide now from a fix (tests, and the first look when the board opens).
    func sampleScent(at l: CLLocation) { sampleScent(l, force: true) }

    // MARK: Clock, saving, sending

    /// Time limits (the hider's referees end the round on time; a hunter who heard no END
    /// stops after the grace) and the guide's next look.
    func tick() {
        if isHider, !radio.isReady { return }   // wait for the node, so hunters hear the END
        let out = game?.tick(at: now) ?? []
        if !out.isEmpty || round?.stage == .over { deliver(out) }
        if guide, let fix = location.fix { sampleScent(fix) }
    }

    private func updateTicking() {
        let live = round?.stage == .live
        if live, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: GamePlay.tickInterval)
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        } else if !live {
            ticker?.cancel()
            ticker = nil
        }
    }

    func saveNow() { persist(now: true) }

    var snapshot: GameSave? {
        guard let game, !game.isOver else { return nil }
        return GameSave(savedAt: clock(), game: game, guide: guide)
    }

    private func persist(now: Bool) {
        guard let saveURL else { return }
        guard let snapshot else {
            GameSave.remove(at: saveURL)
            return
        }
        if now { snapshot.writeNow(to: saveURL) } else { snapshot.write(to: saveURL) }
    }

    private func changed() {
        revision += 1
        if saveURL != nil { saver.schedule { [weak self] in self?.persist(now: false) } }
        updateTicking()
    }

    private func deliver(_ outputs: [HuntGame.Output]) {
        changed()
        for o in outputs {
            if case .error(let e) = o.output { error = e }
            if let s = o.output.say { PhoneReferee.admit(s, to: &queue) }
        }
        pump()
    }

    private func pump() {
        guard sending == nil, !queue.isEmpty else { return }
        sending = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let (i, wait) = PhoneReferee.next(in: self.queue, lastSentTo: self.lastSentTo, now: Date())
                guard let i else {
                    try? await Task.sleep(for: .seconds(min(wait, PhoneReferee.cooldown)))
                    continue
                }
                let s = self.queue.remove(at: i)
                _ = self.radio.sendText(s.text, to: s.to, channel: s.channel ?? self.huntChannel ?? 0)
                DebugLog.append("\(Date().formatted(.iso8601)) > \(s.text)\n")
                if s.to != .broadcast { self.lastSentTo[s.to] = Date() }
                self.sent.append(s)
                if self.sent.count > 500 { self.sent.removeFirst(self.sent.count - 500) }
                try? await Task.sleep(for: PhoneReferee.spacing)
            }
            self?.sending = nil
        }
    }
}
