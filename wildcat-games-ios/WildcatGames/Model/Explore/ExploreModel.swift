import CoreLocation
import Foundation
import Observation
import WildcatRadioCore

/// Solo play: Daily Fox, Territory, Frontier, Nodedex and achievements,
/// built from the phone's GPS, the player's own node and the Den.
@MainActor
@Observable
final class ExploreModel: NSObject, CLLocationManagerDelegate {
    private struct Saved: Codable {
        var dex = Nodedex()
        var runs: [DailyFoxRun] = []
        var unlocked: [String: Date] = [:]
        var refLat: Double?
        var rerolls: [String: Int] = [:]
    }

    private(set) var dex = Nodedex()
    private(set) var runs: [DailyFoxRun] = []
    private(set) var unlocked: [String: Date] = [:]
    /// Shown once, then cleared by the view.
    var toast: String?
    private(set) var here: LatLon?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    // Daily Fox, live
    private(set) var tracker: FoxTracker?
    private(set) var located: [(LatLon, Double)] = []
    private(set) var lastPing: Date?
    var maxDistance: Double {
        didSet { UserDefaults.standard.set(maxDistance, forKey: "explore.maxDistance") }
    }

    static let pingCooldown: TimeInterval = 30

    @ObservationIgnored private var refLat: Double?
    @ObservationIgnored private var rerolls: [String: Int] = [:]
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var users = 0
    @ObservationIgnored private let radio: Radio
    @ObservationIgnored private let den: DenStore
    @ObservationIgnored private let walker: WalkRecorder
    @ObservationIgnored private let fileURL: URL

    init(radio: Radio, den: DenStore, walker: WalkRecorder, file: URL? = nil) {
        self.radio = radio
        self.den = den
        self.walker = walker
        fileURL = file ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("explore.json")
        maxDistance = UserDefaults.standard.object(forKey: "explore.maxDistance") as? Double ?? 5000
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        authorization = manager.authorizationStatus
        load()
        radio.addListener { [weak self] in self?.handle($0) }
        if let run = todayRun, !run.isOver { resumeTracker(for: run) }
    }

    // MARK: Persistence

    private func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: fileURL), let s = try? d.decode(Saved.self, from: data) else { return }
        dex = s.dex
        runs = s.runs
        unlocked = s.unlocked
        refLat = s.refLat
        rerolls = s.rerolls
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        let s = Saved(dex: dex, runs: runs, unlocked: unlocked, refLat: refLat, rerolls: rerolls)
        try? e.encode(s).write(to: fileURL, options: .atomic)
    }

    // MARK: Location

    var access: LocationAccess { LocationAccess(authorization) }

    /// Starts location while a screen needs it. `asking: false` (Play, Explore)
    /// never shows the permission prompt; screens that need a fix ask.
    func begin(asking: Bool = true) {
        users += 1
        if asking { askLocation() } else if access == .allowed { manager.startUpdatingLocation() }
    }

    /// The permission prompt, once, from a tap or a screen that needs it.
    func askLocation() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    /// The freshest position the phone has, without waiting for a new fix.
    var lastKnown: LatLon? {
        here ?? manager.location.map { LatLon(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
    }

    func end() {
        users = max(0, users - 1)
        if users == 0, todayRun.map({ !$0.isOver }) != true { manager.stopUpdatingLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 80 else { return }
        let p = LatLon(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        MainActor.assumeIsolated { moved(to: p) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = s
            // Allowed just now (the prompt, or Settings) while a screen waits for a fix.
            if users > 0, access == .allowed { self.manager.startUpdatingLocation() }
        }
    }

    private func moved(to p: LatLon) {
        if refLat == nil {
            refLat = (p.lat * 10).rounded() / 10
            save()
        }
        if let prev = here, var run = todayRun, !run.isOver {
            let step = Geo.distance(prev, p)
            if step < 200 { run.walked += step }
            if Geo.distance(p, run.foxPosition) <= DailyFox.foundRadius {
                run.found = Date()
                toast = "You found \(run.foxName)! +\(run.score)"
                tracker = nil
            }
            update(run)
        }
        here = p
        onMove?(p)
    }

    /// Told about each new position (practice follows the player with it).
    @ObservationIgnored var onMove: ((LatLon) -> Void)?

    // MARK: Radio

    private func handle(_ event: MeshSession.Event) {
        guard case .packet(let p) = event, p.from != radio.session.myNode else { return }
        if p.isDirectRF {
            let info = radio.session.nodes[p.from]
            let pos = den.node(p.from.id).flatMap { n -> LatLon? in
                guard n.hasPosition, let la = n.position?.lat, let lo = n.position?.lon else { return nil }
                return LatLon(lat: la, lon: lo)
            }
            let isNew = dex.heard(id: p.from.id, shortName: info?.shortName ?? den.node(p.from.id)?.short_name,
                                  longName: info?.longName ?? den.node(p.from.id)?.long_name, at: Date(), me: here,
                                  nodePosition: pos, snr: p.rxSNR.map(Double.init), rssi: p.rxRSSI)
            if isNew { toast = "New in your Nodedex: \(dex.entries[p.from.id]?.name ?? p.from.short)" }
            save()
            checkAchievements()
        }
        if tracker != nil, let s = tracker?.ingest(p, at: Date()), let here {
            located.append((here, s.score))
            if located.count > 200 { located.removeFirst(located.count - 200) }
        }
    }

    // MARK: Daily Fox

    var today: String { DailyFox.day(Date()) }
    var todayRun: DailyFoxRun? { runs.first { $0.day == today } }

    /// Nodes with a known position that were heard over radio: from your own node's
    /// list, plus the Den's when one is paired. No Den needed.
    private var candidates: [DailyFox.Candidate] {
        let me = radio.session.myNode?.id
        var out: [String: DailyFox.Candidate] = [:]
        for n in radio.session.nodes.values where !n.viaMQTT && n.num.id != me {
            guard let p = n.position else { continue }
            out[n.num.id] = DailyFox.Candidate(id: n.num.id, name: n.shortName ?? n.longName ?? n.num.short,
                                               position: LatLon(lat: p.latitude, lon: p.longitude), lastHeard: n.lastHeard)
        }
        for n in den.nodes {
            guard n.isRF, n.hasPosition, n.id != den.myID, n.id != me,
                  let la = n.position?.lat, let lo = n.position?.lon else { continue }
            out[n.id] = DailyFox.Candidate(id: n.id, name: n.name, position: LatLon(lat: la, lon: lo), lastHeard: n.lastHeard)
        }
        return Array(out.values).sorted { $0.id < $1.id }
    }

    /// Why today's fox can't be picked yet, or nil.
    var foxBlocker: String? {
        if here == nil { return access.problem ?? "Waiting for GPS…" }
        if candidates.isEmpty {
            return radio.isReady ? "Your node hasn't heard any node that shares its position yet. Give it a few minutes."
                                 : "Needs a Meshtastic node: today's fox is picked from the nodes it hears."
        }
        if todaysFox == nil { return "No radio-heard node with a position within \(Geo.format(maxDistance)). Try a bigger range." }
        return nil
    }

    var todaysFox: DailyFox.Candidate? {
        guard let here else { return nil }
        return DailyFox.pick(from: candidates, me: here, day: today, reroll: rerolls[today] ?? 0, maxDistance: maxDistance)
    }

    func differentFox() {
        guard todayRun == nil else { return }
        rerolls[today, default: 0] += 1
        save()
    }

    func startDailyFox() {
        guard todayRun == nil, let fox = todaysFox, let here else { return }
        let run = DailyFoxRun(day: today, foxID: fox.id, foxName: fox.name, foxPosition: fox.position, started: Date(),
                              startDistance: Geo.distance(here, fox.position))
        runs.insert(run, at: 0)
        save()
        resumeTracker(for: run)
    }

    private func resumeTracker(for run: DailyFoxRun) {
        guard let num = NodeNum(id: run.foxID) else { return }
        var t = FoxTracker(fox: num)
        t.acceptRelayed = true
        tracker = t
        located = []
        manager.startUpdatingLocation()
    }

    /// Next hint: first how far, then which way.
    func hint() -> String? {
        guard var run = todayRun, !run.isOver, let here else { return nil }
        run.hints += 1
        update(run)
        let d = Geo.distance(here, run.foxPosition)
        return run.hints == 1 ? DailyFox.distanceHint(d)
            : "It's roughly \(Geo.compass(Geo.bearing(here, run.foxPosition))) of you, \(DailyFox.distanceHint(d).lowercased())"
    }

    var canPing: Bool {
        radio.isReady && radio.source == .bluetooth && (lastPing.map { Date().timeIntervalSince($0) >= Self.pingCooldown } ?? true)
    }

    /// Asks the fox to answer (a traceroute); its reply is a fresh reading.
    func ping() {
        guard canPing, var run = todayRun, !run.isOver, let num = NodeNum(id: run.foxID) else { return }
        radio.sendTraceroute(to: num, channel: radio.session.channel(toReach: num))
        lastPing = Date()
        run.pings += 1
        update(run)
    }

    func giveUp() {
        guard var run = todayRun, !run.isOver else { return }
        run.gaveUp = true
        update(run)
        tracker = nil
    }

    /// Uphill direction of the fox's signal from your own located readings.
    var signalBearing: Double? { Geo.signalBearing(located) }

    private func update(_ run: DailyFoxRun) {
        if let i = runs.firstIndex(where: { $0.day == run.day }) { runs[i] = run }
        save()
        checkAchievements()
    }

    // MARK: Map layers

    var grid: HexGrid { HexGrid(size: 90, refLat: refLat ?? here?.lat ?? den.denPosition?.lat ?? 39) }

    var allWalkPoints: [CoveragePoint] { (walker.walk?.points ?? []) + walker.walks.flatMap(\.points) }

    var territory: Territory { Territory(grid: grid, points: allWalkPoints) }

    var frontier: Frontier? { den.denPosition.map { Frontier(den: $0, points: allWalkPoints) } }

    // MARK: Achievements

    var stats: ExploreStats {
        let pts = allWalkPoints
        var s = ExploreStats()
        s.uplinks = pts.filter { $0.kind == .uplink }.count
        s.downlinks = pts.filter { $0.kind == .downlink }.count
        s.deadZones = territory.dead
        s.tiles = territory.explored
        s.farthest = frontier?.farthest ?? 0
        s.frontierSectors = frontier?.reach.count ?? 0
        s.walkedKm = WalkStats.walkedKm(walker.walks)
        s.dex = dex.entries.count
        s.legendary = dex.entries.values.filter { $0.rarity == .legendary }.count
        s.foxes = runs.filter { $0.found != nil }.count
        s.streak = DailyFox.streak(runs, today: today)
        s.drives = walker.walks.filter { $0.drive == true }.count
        return s
    }

    func checkAchievements() {
        let s = stats
        for a in Achievement.all where unlocked[a.id] == nil && a.isMet(s) {
            unlocked[a.id] = Date()
            toast = "Achievement: \(a.title)"
        }
        save()
    }
}

extension DenStore {
    var denPosition: LatLon? {
        guard let p = denNode?.position, let la = p.lat, let lo = p.lon, la != 0 || lo != 0 else { return nil }
        return LatLon(lat: la, lon: lo)
    }
}
