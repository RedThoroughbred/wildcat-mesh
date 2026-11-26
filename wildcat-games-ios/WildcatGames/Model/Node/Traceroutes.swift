import Foundation
import Observation
import WildcatRadioCore

/// Traceroutes to other nodes: send, wait up to a minute, keep the answer.
@MainActor
@Observable
final class Traceroutes {
    enum State: Equatable {
        case waiting(since: Date)
        case answered(Route, at: Date)
        case timedOut
    }

    private(set) var results: [NodeNum: State] = [:]
    private(set) var lastSent: Date?
    @ObservationIgnored private var pending: [UInt32: NodeNum] = [:]
    @ObservationIgnored private let radio: Radio
    static let cooldown: TimeInterval = 30
    static let timeout: TimeInterval = 60

    init(radio: Radio) {
        self.radio = radio
        radio.addListener { [weak self] in self?.handle($0) }
    }

    var canSend: Bool {
        radio.isReady && radio.source == .bluetooth && (lastSent.map { Date().timeIntervalSince($0) >= Self.cooldown } ?? true)
    }

    func run(to node: NodeNum) {
        guard canSend, let id = radio.sendTraceroute(to: node, channel: radio.session.channel(toReach: node)) else { return }
        pending[id] = node
        lastSent = Date()
        results[node] = .waiting(since: Date())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeout))
            guard let self, case .waiting? = self.results[node] else { return }
            self.results[node] = .timedOut
            self.pending[id] = nil
        }
    }

    func handle(_ e: MeshSession.Event) {
        guard case .packet(let p) = e, let route = p.route, let req = p.requestID, let node = pending.removeValue(forKey: req) else { return }
        results[node] = .answered(route, at: Date())
    }
}
