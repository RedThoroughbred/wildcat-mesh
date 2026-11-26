import Foundation
import Observation
import WildcatRadioCore

/// The app's one radio: the hunter's own Meshtastic node over Bluetooth, or
/// the practice simulator. Everything above it sees the same events.
@MainActor
@Observable
final class Radio {
    enum Source: Equatable { case none, bluetooth, practice }

    private(set) var source: Source = .none
    /// Created on first use so the Bluetooth permission prompt appears only
    /// when the player asks to connect.
    private(set) var link: MeshLink?
    private(set) var practice: PracticeMesh?
    /// A scan or reconnect waiting for Bluetooth to come up.
    let pending = PendingScan()
    /// Where practice nodes are placed: the phone's last known position, if any.
    @ObservationIgnored var practiceCenter: () -> LatLon? = { nil }
    var onEvent: ((MeshSession.Event) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    @ObservationIgnored private var listeners: [(MeshSession.Event) -> Void] = []

    /// Another observer of every radio event (the hunt uses `onEvent`).
    func addListener(_ l: @escaping (MeshSession.Event) -> Void) { listeners.append(l) }

    private func dispatch(_ e: MeshSession.Event) {
        onEvent?(e)
        for l in listeners { l(e) }
    }

    var session: MeshSession {
        switch source {
        case .practice: return practice?.session ?? MeshSession()
        default: return link?.session ?? MeshSession()
        }
    }

    var isReady: Bool {
        switch source {
        case .practice: return practice != nil
        case .bluetooth: return link?.state.isReady ?? false
        case .none: return false
        }
    }

    /// "Practice", the node's name, or what the link is doing.
    var statusText: String {
        switch source {
        case .practice: return "Practice"
        case .none: return "No node"
        case .bluetooth:
            switch link?.state ?? .idle {
            case .poweredOff: return "Bluetooth off"
            case .unauthorized: return "Bluetooth not allowed"
            case .idle: return "No node"
            case .scanning: return "Scanning…"
            case .connecting(let n): return "Connecting \(n)…"
            case .configuring(let n): return "Loading \(n)…"
            case .ready(let n): return n
            case .failed: return "Connection failed"
            }
        }
    }

    func bluetooth() -> MeshLink {
        if let link { return link }
        let l = MeshLink()
        l.onEvent = { [weak self] in self?.dispatch($0) }
        l.onDiagnostic = { [weak self] in self?.onDiagnostic?($0) }
        link = l
        return l
    }

    func useBluetooth() {
        stopPractice()
        source = .bluetooth
        _ = bluetooth()
    }

    /// "Find my node": scans now, or as soon as Bluetooth is on (the first tap
    /// creates the Bluetooth manager, which isn't ready yet).
    func findNode() {
        useBluetooth()
        let l = bluetooth()
        pending.start {
            switch l.state {
            case .unauthorized, .scanning, .connecting, .configuring, .ready: return true
            default: l.scan(); return l.state == .scanning
            }
        }
    }

    /// Reconnects the node used last time, waiting for Bluetooth like `findNode`.
    func reconnectLast() {
        useBluetooth()
        let l = bluetooth()
        pending.start {
            if l.state == .unauthorized { return true }
            let before = l.state
            l.reconnectLast()
            return l.state != before
        }
    }

    func stopFinding() {
        pending.cancel()
        link?.stopScan()
    }

    func startPractice() {
        pending.cancel()
        // A second tap must not leave the first practice mesh running (and sending) underneath.
        practice?.stop()
        link?.disconnect()
        let p = PracticeMesh(center: practiceCenter())
        p.onEvent = { [weak self] in self?.dispatch($0) }
        practice = p
        source = .practice
        p.start()
    }

    func stopPractice() {
        let was = practice != nil
        practice?.stop()
        practice = nil
        if source == .practice { source = .none }
        if was { for l in practiceEndListeners { l() } }
    }

    /// Told when practice ends, so pretend data (chats) can go with it.
    func onPracticeEnd(_ l: @escaping () -> Void) { practiceEndListeners.append(l) }
    @ObservationIgnored private var practiceEndListeners: [() -> Void] = []

    /// A position packet without coordinates: it goes over the air so the
    /// Den can measure the link, and says nothing about where we are.
    func sendPositionBeacon(channel: Int) {
        guard source == .bluetooth else { return }
        link?.send(toRadio: MeshCodec.positionPacket(time: Date(), channel: channel, id: MeshCodec.newPacketID()))
    }

    /// Asks `node` to answer with a traceroute (no message shown to its owner).
    @discardableResult
    func sendTraceroute(to node: NodeNum, channel: Int) -> UInt32? {
        guard source == .bluetooth, let link, link.state.isReady else { return nil }
        let id = MeshCodec.newPacketID()
        link.send(toRadio: MeshCodec.traceroutePacket(to: node, channel: channel, id: id))
        return id
    }

    /// A chat message (with ack); returns its packet id.
    @discardableResult
    func sendText(_ text: String, to: NodeNum, channel: Int, replyID: UInt32? = nil, isReaction: Bool = false) -> UInt32? {
        switch source {
        case .bluetooth:
            return link?.send(text: text, to: to, channel: channel, replyID: replyID, isReaction: isReaction)
        case .practice:
            return practice?.send(text: text, to: to, channel: channel, isReaction: isReaction)
        case .none:
            return nil
        }
    }

    func send(_ text: String, to: NodeNum = .broadcast, channel: Int) {
        switch source {
        case .practice: practice?.receive(text: text, channel: channel)
        case .bluetooth: link?.send(text: text, to: to, channel: channel)
        case .none: break
        }
    }
}
