import Foundation
import Observation
import WildcatRadioCore

/// Applies MeshCore node settings one step at a time and checks each one took,
/// by watching what the node reports back (it re-sends its info after every
/// setting). Same idle / working / done / failed status as Meshtastic's NodeAdmin.
@MainActor
@Observable
final class MeshCoreApply {
    enum Status: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    enum StepState: Equatable { case waiting, working, done, failed }

    /// One change: what to send, and how to tell from the session that it took.
    struct Step {
        let title: String
        let send: (MeshCoreLink) -> Void
        /// nil: nothing to read back (an advert); the step counts as done once sent.
        let check: ((MeshCoreSession) -> Bool)?

        init(_ title: String, send: @escaping (MeshCoreLink) -> Void, check: ((MeshCoreSession) -> Bool)?) {
            self.title = title
            self.send = send
            self.check = check
        }
    }

    private(set) var status: Status = .idle
    /// The current run's steps and how each went, for a progress list.
    private(set) var progress: [(title: String, state: StepState)] = []

    var isWorking: Bool { if case .working = status { return true } else { return false } }

    /// How long a node gets to report a setting back.
    static let timeout: Duration = .seconds(8)
    /// Practice answers at once, or (for settings it doesn't keep) never.
    static let practiceTimeout: Duration = .seconds(2)

    /// Ends a run that stopped before any step (say, no location).
    func fail(_ text: String) { status = .failed(text); progress = [] }

    /// Ends a run with nothing to send.
    func finish(_ text: String) { status = .done(text); progress = [] }

    func reset() {
        guard !isWorking else { return }
        status = .idle
        progress = []
    }

    /// Runs the steps in order; stops at the first one the node doesn't confirm.
    @discardableResult
    func run(_ steps: [Step], on link: MeshCoreLink, summary: String) async -> Bool {
        guard !isWorking, !steps.isEmpty else { return false }
        progress = steps.map { ($0.title, .waiting) }
        for (i, step) in steps.enumerated() {
            guard link.state.isReady else {
                status = .failed("The node disconnected before \(step.title.lowercased()).")
                progress[i].state = .failed
                return false
            }
            status = .working(step.title + "…")
            progress[i].state = .working
            step.send(link)
            if let check = step.check {
                let ok = await wait(link, timeout: link.isDemo ? Self.practiceTimeout : Self.timeout, until: check)
                guard ok else {
                    progress[i].state = .failed
                    status = .failed(link.isDemo ? "\(step.title): the practice node didn't take it."
                                                 : "\(step.title): the node didn't confirm it. Check it's still connected and try again.")
                    return false
                }
            } else {
                try? await Task.sleep(for: .milliseconds(300))
            }
            progress[i].state = .done
        }
        status = .done(summary)
        return true
    }

    private func wait(_ link: MeshCoreLink, timeout: Duration, until check: (MeshCoreSession) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        while clock.now < end {
            if check(link.session) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return check(link.session)
    }

    // MARK: Steps

    static func name(_ name: String) -> Step {
        let n = MeshCoreNodeLimits.clamp(name)
        return Step("Name", send: { $0.rename(n) }, check: { $0.me?.name == n })
    }

    static func radio(_ p: (frequency: Double, bandwidth: Double, spreadingFactor: Int, codingRate: Int), title: String = "Radio") -> Step {
        Step(title, send: { $0.setRadio(frequency: p.frequency, bandwidth: p.bandwidth, spreadingFactor: p.spreadingFactor, codingRate: p.codingRate) },
             check: { s in
                 guard let me = s.me else { return false }
                 return abs(me.frequency - p.frequency) < 0.0005 && abs(me.bandwidth - p.bandwidth) < 0.05
                     && me.spreadingFactor == p.spreadingFactor && me.codingRate == p.codingRate
             })
    }

    static func radio(_ preset: MeshCorePreset) -> Step {
        radio((preset.frequency, preset.bandwidth, preset.spreadingFactor, preset.codingRate), title: "Radio: \(preset.title)")
    }

    static func txPower(_ dbm: Int) -> Step {
        Step("Transmit power", send: { $0.setTxPower(dbm) }, check: { $0.me?.txPower == dbm })
    }

    static func position(_ c: Coordinate) -> Step {
        Step("Position", send: { $0.setPosition(c) }, check: { s in
            guard let p = s.me?.position else { return false }
            return abs(p.latitude - c.latitude) < 0.00001 && abs(p.longitude - c.longitude) < 0.00001
        })
    }

    /// 0,0 is "no position" to the firmware's readers (Wildcat's core reads it as none).
    static var clearPosition: Step {
        Step("Clear position", send: { $0.setPosition(Coordinate(latitude: 0, longitude: 0)) }, check: { $0.me != nil && $0.me?.position == nil })
    }

    /// Changes the "other params" (auto-add, telemetry, location policy, extra acks) together,
    /// starting from what the node has now, as the firmware takes all four at once.
    static func other(_ title: String, _ change: @escaping (inout MeshCore.SelfInfo) -> Void) -> Step {
        Step(title, send: { link in
            guard var me = link.session.me else { return }
            change(&me)
            link.enqueue(.setOtherParams(manualAddContacts: me.manualAddContacts, telemetryModes: me.telemetryModes,
                                         advertLocationPolicy: me.advertLocationPolicy, multiAcks: me.multiAcks))
            link.refreshSelf()
        }, check: { s in
            // Took once applying the change to what the node now reports changes nothing.
            guard let have = s.me else { return false }
            var want = have
            change(&want)
            return want == have
        })
    }

    static func sharesPosition(_ on: Bool) -> Step {
        other(on ? "Share position in adverts" : "Stop sharing position") { $0.advertLocationPolicy = on ? 1 : 0 }
    }

    static func advert(flood: Bool) -> Step {
        Step(flood ? "Advert to the whole mesh" : "Advert to nodes in range", send: { $0.advertise(flood: flood) }, check: nil)
    }

    /// Creates or joins a channel in the first free slot; the slot is known once sent.
    static func channel(named name: String, key: Data?, slot: MeshCoreSlotBox) -> Step {
        Step("Channel \(name)", send: { link in slot.value = link.addChannel(named: name, secret: key) },
             check: { s in
                 guard let i = slot.value, let c = s.channels[i] else { return false }
                 return c.name == name && (key == nil || c.secret == key)
             })
    }

    static func renameChannel(_ index: Int, to name: String, secret: Data) -> Step {
        Step("Rename channel", send: { link in
            link.enqueue(.setChannel(index: index, name: name, secret: secret))
            link.enqueue(.getChannel(index: index))
        }, check: { $0.channels[index]?.name == name })
    }
}

/// The slot a new channel landed in, filled in when its step runs.
final class MeshCoreSlotBox {
    var value: Int?
    init(_ value: Int? = nil) { self.value = value }
}
