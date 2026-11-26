import Foundation
import Observation
import WildcatRadioCore

/// Referees a Fox Hunt on this phone, through the player's own node: no Den.
/// Hunters' WG text arrives on the hunt channel; rulings go back as direct
/// messages, spaced out so a burst (start, a find) doesn't flood the mesh.
///
/// The hunt is saved as it changes (Application Support/hosted-hunt.json), so a
/// host who closes the app picks it up again; a timed hunt ends on time from a
/// clock tick even when nobody is talking.
@MainActor
@Observable
final class PhoneReferee {
    private(set) var referee = FoxReferee()
    /// Every ruling sent, newest last (for the host's log).
    private(set) var sent: [FoxReferee.Say] = []
    private(set) var error: String?
    /// The join invite for the current hunt (QR code / link).
    private(set) var invite: HuntInvite?
    /// Bumps on every change so views refresh.
    private(set) var revision = 0
    /// Set when the hunt was picked up from a save at launch.
    private(set) var resumed = false

    private let radio: Radio
    @ObservationIgnored private let saveURL: URL?
    @ObservationIgnored private let saver = Debouncer(.seconds(1))
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// How often a live hunt with a time limit checks the clock.
    static let tickInterval: Duration = .seconds(5)
    @ObservationIgnored private var queue: [FoxReferee.Say] = []
    @ObservationIgnored private var sending: Task<Void, Never>?
    var clock: () -> Date = Date.init
    /// Gap between radio sends.
    static let spacing: Duration = .milliseconds(1500)
    /// Replies waiting to go out, all told and per hunter; past these the oldest
    /// (or the newest for one chatty hunter) are dropped, so a flood can't back up the mesh.
    static let maxQueue = 20
    static let maxPerNode = 3
    /// At most one direct reply to the same hunter this often.
    static let cooldown: TimeInterval = 3
    @ObservationIgnored private var lastSentTo: [NodeNum: Date] = [:]

    /// `saveURL`: where the hunt is saved (nil: never saved, e.g. previews). A hunt saved
    /// there in the lobby or live, in the last 12 hours, is picked up now.
    init(radio: Radio, saveURL: URL? = HostedHuntSave.defaultURL, now: Date = Date()) {
        self.radio = radio
        self.saveURL = saveURL
        radio.addListener { [weak self] in self?.handle($0) }
        if let saveURL, let save = HostedHuntSave.load(from: saveURL, now: now) {
            referee = save.referee
            invite = save.invite
            resumed = true
            updateTicking()
        }
    }

    var board: FoxReferee.Board? { referee.board }
    var isHosting: Bool { referee.hunt != nil && referee.hunt?.phase != .ended }
    var huntChannel: Int? { radio.session.channelIndex(named: HuntModel.huntChannelName) }

    private var now: TimeInterval { clock().timeIntervalSince1970 }

    // MARK: Host actions

    /// A new hunt in the lobby, with a time limit in seconds (nil: none). Returns the join invite, or nil (see `error`).
    func create(fox: NodeNum, foxCode: String, mode: FoxReferee.Mode, code: String, timeLimit: TimeInterval? = nil) -> HuntInvite? {
        error = nil
        guard radio.isReady, let me = radio.session.myNode else { error = "Connect your node first."; return nil }
        guard let index = huntChannel else {
            error = "Your node needs the WGHUNT channel: hunters talk to you on it."
            return nil
        }
        // The practice mesh has no real channel keys; real nodes always send theirs.
        guard let settings = radio.session.channels[index]?.settings
                ?? (radio.source == .practice ? ChannelSettings(name: HuntModel.huntChannelName, psk: Data([1])).raw : nil) else {
            error = "Couldn't read your node's WGHUNT key. Reconnect the node and try again."
            return nil
        }
        let label = radio.session.nodes[fox]?.shortName
        resumed = false
        let out = referee.handle(.create(t: now, fox: fox, foxCode: foxCode, code: code.uppercased(), mode: mode,
                                         foxLabel: label, channelName: HuntModel.huntChannelName, timeLimit: timeLimit))
        let created = out.contains(.created)
        if created {
            invite = HuntInvite(code: code.uppercased(), channel: settings, fox: fox, host: me,
                                limitMinutes: referee.hunt?.timeLimit.map { Int(($0 / 60).rounded()) })
        }
        deliver(out)
        return created ? invite : nil
    }

    func start() { deliver(referee.handle(.start(t: now))) }
    func end() { deliver(referee.handle(.end(t: now))) }

    /// Clears a finished hunt so a new one can be set up.
    func reset() {
        referee = FoxReferee()
        invite = nil
        sent = []
        error = nil
        resumed = false
        revision += 1
        saver.cancel()
        updateTicking()
        if let saveURL { HostedHuntSave.remove(at: saveURL) }
    }

    // MARK: Time limit

    /// Seconds left at `date` (nil: no limit). See `FoxReferee.Hunt.timeRemaining(at:)`.
    func timeRemaining(at date: Date) -> TimeInterval? { referee.timeRemaining(at: date.timeIntervalSince1970) }

    /// Ends a live hunt whose time is up. Waits for the node, so hunters hear the END.
    func tick() {
        guard radio.isReady else { return }
        let out = referee.handle(.tick(t: now))
        if !out.isEmpty { deliver(out) }
    }

    /// The clock runs only while a hunt with a time limit is live.
    private func updateTicking() {
        let timed = referee.hunt?.phase == .live && referee.hunt?.timeLimit != nil
        if timed, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: PhoneReferee.tickInterval)
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        } else if !timed {
            ticker?.cancel()
            ticker = nil
        }
    }

    // MARK: Saving

    /// Saves now (the app is going to the background).
    func saveNow() { persist(now: true) }

    /// The hunt as it would be saved now (nil when there's nothing to keep).
    var snapshot: HostedHuntSave? {
        guard isHosting else { return nil }
        return HostedHuntSave(savedAt: clock(), referee: referee, invite: invite)
    }

    private func persist(now: Bool) {
        guard let saveURL else { return }
        guard let snapshot else {
            HostedHuntSave.remove(at: saveURL)   // ended or reset: nothing to pick up
            return
        }
        if now { snapshot.writeNow(to: saveURL) } else { snapshot.write(to: saveURL) }
    }

    // MARK: Hosting and hunting on the same phone

    /// Rulings for this phone's own hunter (the host playing too) come here, not over the radio.
    @ObservationIgnored var onLocalReply: ((String) -> Void)?

    /// This phone's hunter sent a WG command while this phone referees: handle it
    /// directly (a node never hears itself). True when it was handled here.
    func acceptLocal(_ command: WG.Command) -> Bool {
        guard isHosting, let me = radio.session.myNode else { return false }
        let text = command.text
        guard FoxReferee.parseCommand(text) != nil else { return false }
        // Only this hunt's commands (a hunter may name another hunt).
        let named: String? = {
            switch command {
            case .join(let h, _), .sig(let h, _), .found(let h, _): return h
            default: return nil
            }
        }()
        if let named, named.uppercased() != referee.code.uppercased() { return false }
        let p = MeshPacket(from: me, to: .broadcast, channel: huntChannel ?? 0, id: 0, portnum: .text, text: text)
        guard let ev = FoxReferee.event(from: p, text: text, label: radio.session.nodes[me]?.shortName, at: now) else { return false }
        deliver(referee.handle(ev))
        return true
    }

    // MARK: Radio

    private func handle(_ e: MeshSession.Event) {
        guard case .packet(let p) = e, let hunt = referee.hunt, p.from != radio.session.myNode else { return }
        let t = now
        if p.from == hunt.fox {
            deliver(referee.handle(.foxHeard(t: t, node: p.from, position: p.position)))
        } else if let pos = p.position {
            deliver(referee.handle(.position(t: t, node: p.from, position: pos)))
        }
        guard let text = p.text else { return }
        // A command naming another hunt (someone else hosting nearby) isn't ours to rule on.
        if let named = FoxReferee.huntCode(in: text), named != referee.code.uppercased() { return }
        guard let ev = FoxReferee.event(from: p, text: text, label: radio.session.nodes[p.from]?.shortName, at: t) else { return }
        deliver(referee.handle(ev))
    }

    private func deliver(_ outputs: [FoxReferee.Output]) {
        revision += 1
        if saveURL != nil { saver.schedule { [weak self] in self?.persist(now: false) } }
        updateTicking()
        for o in outputs {
            if case .error(let e) = o { error = e }
            if let s = o.say {
                if s.to == radio.session.myNode { onLocalReply?(s.text) } else { Self.admit(s, to: &queue) }
            }
        }
        pump()
    }

    /// Adds a reply to the queue within its limits.
    static func admit(_ s: FoxReferee.Say, to queue: inout [FoxReferee.Say]) {
        if s.to != .broadcast, queue.filter({ $0.to == s.to }).count >= maxPerNode { return }
        queue.append(s)
        if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
    }

    /// The first reply that may go now (broadcasts always; a hunter's only after its
    /// cooldown), or how long until one may.
    static func next(in queue: [FoxReferee.Say], lastSentTo: [NodeNum: Date], now: Date) -> (index: Int?, wait: TimeInterval) {
        var wait = TimeInterval.infinity
        for (i, s) in queue.enumerated() {
            guard s.to != .broadcast, let last = lastSentTo[s.to] else { return (i, 0) }
            let left = cooldown - now.timeIntervalSince(last)
            if left <= 0 { return (i, 0) }
            wait = min(wait, left)
        }
        return (nil, wait)
    }

    private func pump() {
        guard sending == nil, !queue.isEmpty else { return }
        sending = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let (i, wait) = Self.next(in: self.queue, lastSentTo: self.lastSentTo, now: Date())
                guard let i else {
                    try? await Task.sleep(for: .seconds(min(wait, Self.cooldown)))
                    continue
                }
                let s = self.queue.remove(at: i)
                _ = self.radio.sendText(s.text, to: s.to, channel: s.channel ?? self.huntChannel ?? 0)
                if s.to != .broadcast { self.lastSentTo[s.to] = Date() }   // real time: this is about airtime
                self.sent.append(s)
                if self.sent.count > 500 { self.sent.removeFirst(self.sent.count - 500) }
                try? await Task.sleep(for: Self.spacing)
            }
            self?.sending = nil
        }
    }
}
