import Foundation
import Observation
import UIKit
import WidgetKit
import WildcatRadioCore

/// Keeps the widgets' snapshot fresh: rewritten a few seconds after radio
/// activity, and when the app goes to the background. WidgetKit's reload budget
/// is small, so the widget is reloaded only when something it shows changed,
/// at most once a minute in the foreground (every 15 minutes in the background).
@MainActor
@Observable
final class SnapshotWriter {
    private let radio: Radio
    private let meshcore: MeshCoreLink
    private let meshcoreStore: MeshCoreStore
    private let messages: MessageStore
    private let bridge: MeshBridge
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastMeshtasticPacket: Date?
    @ObservationIgnored private var last: WildcatSnapshot?
    @ObservationIgnored private var lastSaved: Date?
    @ObservationIgnored private var lastReload: Date?
    @ObservationIgnored private var reloadLater: Task<Void, Never>?
    static let foregroundGap: TimeInterval = 60
    static let backgroundGap: TimeInterval = 15 * 60

    init(radio: Radio, meshcore: MeshCoreLink, meshcoreStore: MeshCoreStore, messages: MessageStore, bridge: MeshBridge) {
        self.radio = radio
        self.meshcore = meshcore
        self.meshcoreStore = meshcoreStore
        self.messages = messages
        self.bridge = bridge
        radio.addListener { [weak self] e in
            if case .packet = e { self?.lastMeshtasticPacket = Date() }
            self?.schedule()
        }
        meshcore.addListener { [weak self] _ in self?.schedule() }
    }

    func schedule() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.pending = nil
            self?.write()
        }
    }

    func write() {
        let s = snapshot(), now = Date()
        if Self.shown(s) != last.map(Self.shown) {
            last = s
            s.save()
            lastSaved = now
            reload(now: now)
        } else if s != last, now.timeIntervalSince(lastSaved ?? .distantPast) >= Self.foregroundGap {
            // Only "last heard" moved: keep the file current for the widget's own
            // refresh, without spending a reload on it.
            last = s
            s.save()
            lastSaved = now
        }
    }

    /// What the widget shows, minus the fields that change with every packet.
    static func shown(_ s: WildcatSnapshot) -> WildcatSnapshot {
        var a = s
        a.updated = .distantPast
        a.meshtastic?.lastHeard = nil
        a.meshcore?.lastHeard = nil
        return a
    }

    /// Seconds until the widget may be reloaded again (0: now).
    static func reloadDelay(lastReload: Date?, now: Date, foreground: Bool) -> TimeInterval {
        guard let lastReload else { return 0 }
        return max(0, (foreground ? foregroundGap : backgroundGap) - now.timeIntervalSince(lastReload))
    }

    private func reload(now: Date) {
        let wait = Self.reloadDelay(lastReload: lastReload, now: now,
                                    foreground: UIApplication.shared.applicationState != .background)
        guard wait > 0 else {
            lastReload = now
            WidgetCenter.shared.reloadTimelines(ofKind: WildcatSnapshot.widgetKind)
            return
        }
        // Too soon: show the latest once the gap has passed (one reload for any number of changes).
        guard reloadLater == nil else { return }
        reloadLater = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.reloadLater = nil
            self.lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: WildcatSnapshot.widgetKind)
        }
    }

    private func snapshot() -> WildcatSnapshot {
        var mt: WildcatSnapshot.Node?
        if radio.isReady, let me = radio.session.myNode {
            let n = radio.session.nodes[me]
            mt = .init(name: n?.longName ?? radio.statusText, badge: n?.shortName ?? me.short, connected: true,
                       heard: max(0, radio.session.nodes.count - 1), lastHeard: lastMeshtasticPacket,
                       batteryVolts: n?.metrics?.voltage)
        }
        var mc: WildcatSnapshot.Node?
        if meshcore.state.isReady, let me = meshcore.session.me {
            mc = .init(name: me.name, badge: MeshCoreStatusCard.initials(me.name), connected: true,
                       heard: meshcore.session.contacts.count, lastHeard: meshcore.session.lastHeard,
                       batteryVolts: meshcore.session.batteryMillivolts.map { Double($0) / 1000 })
        }
        // Nothing from blocked senders, and the word filter applies here too.
        let shown = { (t: String) in self.messages.safety?.shown(t) ?? t }
        var lines: [WildcatSnapshot.Line] = messages.messages.filter { !$0.outgoing && !messages.isHidden($0) }.suffix(6).map {
            .init(id: "mt\($0.id)", network: "MT",
                  from: NodeNum(id: $0.from).flatMap { radio.session.nodes[$0]?.shortName } ?? $0.from,
                  text: shown($0.text), at: $0.time)
        }
        lines += meshcoreStore.visibleChats.filter { $0.direction == .received }.suffix(6).map { c in
            var from = meshcore.session.label(c.origin), text = shown(c.text)
            if case .channel = c.origin, let r = c.text.range(of: ": ") {
                from = String(c.text[..<r.lowerBound]); text = String(c.text[r.upperBound...])
            }
            return .init(id: "mc\(c.id)", network: "MC", from: from, text: text, at: c.at)
        }
        return WildcatSnapshot(updated: Date(), meshtastic: mt, meshcore: mc,
                               bridgeOn: bridge.isLive, bridged: bridge.log.count,
                               bridgeChannels: bridge.enabled ? bridgeLabel : nil,
                               unreadMeshtastic: messages.totalUnread, unreadMeshCore: meshcoreStore.totalUnread,
                               recent: Array(lines.sorted { $0.at > $1.at }.prefix(4)))
    }

    private var bridgeLabel: String? {
        guard let a = bridge.meshtasticChannel, let b = bridge.meshcoreChannel else { return nil }
        let mtName = radio.session.channels[a].map { $0.name.isEmpty ? "Primary" : $0.name } ?? "ch \(a)"
        return "\(mtName) ↔ \(meshcore.session.label(.channel(b)))"
    }
}
