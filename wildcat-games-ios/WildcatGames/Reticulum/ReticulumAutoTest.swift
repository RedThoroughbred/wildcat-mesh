#if DEBUG
import Foundation
import WildcatRadioCore

/// Developer only: `-ReticulumAutoTest` drives the Reticulum spike without touching the screen, for
/// `tools/reticulum/sim-test.sh` (simulator, TCP to the Mac's test peer) and the on-device test.
/// Starts Reticulum (TCP to `-ReticulumTCP host:port`, default 127.0.0.1:4243; the RNode too with
/// `-ReticulumAutoTestRNode`), announces, waits for the peer named `-ReticulumPeer` (default
/// "Mac test peer") to announce, sends it a message, and logs `[ReticulumAutoTest]` lines: PASS
/// when the message is delivered and when the peer's echo arrives, the measurements, and a
/// heartbeat every 5 s (gaps show when the app was suspended). With `-ReticulumRestart` it then
/// stops Reticulum, starts it again in the same run and sends a second message (`PASS restart`).
@MainActor
final class ReticulumAutoTest {
    static let shared = ReticulumAutoTest()
    private var started = false
    private var peerName = "Mac test peer"
    private var sentID: String?
    private var delivered = false
    private var echoed = false
    private var startedAt = Date()
    private var restart = false
    private var restarted = false
    private var secondID: String?
    private weak var link: RNodeLink?

    func start(link: RNodeLink) {
        guard !started else { return }
        started = true
        startedAt = Date()
        let args = ProcessInfo.processInfo.arguments
        let spike = ReticulumModel.shared
        restart = args.contains("-ReticulumRestart")
        self.link = link
        if let hp = Self.value(after: "-ReticulumTCP", in: args) {
            let parts = hp.split(separator: ":")
            if parts.count == 2 { spike.internetHost = String(parts[0]); spike.internetPort = String(parts[1]) }
        }
        spike.internetOn = !args.contains("-ReticulumNoTCP")
        spike.useRNode = args.contains("-ReticulumAutoTestRNode")
        spike.opportunistic = args.contains("-ReticulumOpportunistic")
        spike.heartbeat = true
        spike.displayName = Self.value(after: "-ReticulumName", in: args) ?? "Wildcat autotest"
        peerName = Self.value(after: "-ReticulumPeer", in: args) ?? peerName
        spike.onEvent = { [weak self] in self?.handle($0) }
        log("start: tcp \(spike.internetOn ? "\(spike.internetHost):\(spike.internetPort)" : "off") · rnode \(spike.useRNode) · peer \"\(peerName)\" · memory \(Self.mb(ProcessMemory.footprintMB()))")
        guard spike.useRNode, !link.state.isReady else { return begin(link) }
        // Reticulum only starts on an RNode that is connected and has reported its firmware.
        if link.lastNodeID != nil {
            log("reconnecting the last RNode (\(link.lastNodeName ?? "?")) for Reticulum")
            link.reconnectLast()
        }
        Task { @MainActor in
            for _ in 0..<60 where !link.state.isReady { try? await Task.sleep(for: .seconds(1)) }
            begin(link)
        }
    }

    private func begin(_ link: RNodeLink) {
        let spike = ReticulumModel.shared
        spike.start(link: link)
        if let why = spike.lastStartError { log("FAIL start: \(why)") }
    }

    private func handle(_ e: Reticulum.Event) {
        let spike = ReticulumModel.shared
        switch e {
        case .ready(let python):
            log("python \(python) ready in \(spike.pythonReadyMs.map(String.init) ?? "?") ms")
        case .identity(_, let hash):
            log("new identity \(hash.prefix(8))… (saved to the Keychain: \(spike.identityStore))")
        case .started(let s):
            log("started <\(s.address)> RNS \(s.rns) LXMF \(s.lxmf) Python \(s.python) crypto \"\(s.crypto)\" · RNS \(s.reticulumMs ?? -1) ms · LXMF \(s.lxmfMs ?? -1) ms")
            log("memory \(Self.mb(spike.memoryBeforeMB)) before → \(Self.mb(spike.memoryRunningMB)) running")
            spike.announce()
        case .interfaces(let list):
            log("interfaces: " + list.map { "\($0.name) \($0.online ? "up" : "down")" }.joined(separator: ", "))
        case .announced:
            log("announced")
        case .announce(let peer):
            log("heard announce <\(peer.hash)> \"\(peer.name ?? "")\" hops \(peer.hops.map(String.init) ?? "?")")
            if restarted, secondID == nil, peer.name == peerName {
                secondID = spike.send(to: peer.hash, text: "hello again from Wildcat (autotest)")
                log("sent again to \(peerName) (id \(secondID ?? "nil"))")
            }
            if sentID == nil, peer.name == peerName {
                sentID = spike.send(to: peer.hash, text: "hello from Wildcat (autotest)")
                log("sent to \(peerName) (id \(sentID ?? "nil"))")
            }
        case .messageState(let id, let delivery, _, let detail):
            let state = delivery.rawValue
            log("message \(id.prefix(8)) \(state)" + (detail.map { " (\($0))" } ?? ""))
            if id == sentID, state == "delivered", !delivered {
                delivered = true
                log("PASS delivered in \(Self.seconds(since: startedAt))")
                done()
            }
            if id == secondID, state == "delivered" { log("PASS restart: delivered after stop and start in one run") }
            if id == sentID || id == secondID, state == "failed" { log("FAIL message failed") }
        case .message(let m):
            log("message \(m.incoming ? "in" : "out") \(m.delivery.rawValue) \"\(m.text)\" signature \(m.trust.map { $0 == .verified ? "valid" : "unverified (\($0.rawValue))" } ?? "-")")
            if m.incoming, m.text.hasPrefix("echo: "), !echoed {
                echoed = true
                log("PASS echo received in \(Self.seconds(since: startedAt))")
                done()
            }
        case .heartbeat(let at):
            log("heartbeat \(String(format: "%.1f", at.timeIntervalSince1970))")
        case .error(let message):
            log("error: \(message)")
        case .stopped:
            log("stopped")
            if restart, !restarted {
                restarted = true
                log("starting again in the same run")
                spike.start(link: link)
            }
        case .pythonExited(let code):
            log("python exited \(code)")
        case .log:
            break
        }
    }

    private func done() {
        guard delivered, echoed else { return }
        log("DONE memory now \(Self.mb(ProcessMemory.footprintMB()))")
        if restart, !restarted {
            log("stopping, to start again")
            ReticulumModel.shared.stop()
        }
    }

    private func log(_ s: String) {
        let line = "[ReticulumAutoTest] \(s)"
        print(line)
        NSLog("%@", line)
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func mb(_ v: Double?) -> String { v.map { String(format: "%.1f MB", $0) } ?? "?" }

    static func seconds(since d: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(d)) }
}
#endif
