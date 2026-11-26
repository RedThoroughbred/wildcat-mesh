import Foundation
import Observation

/// A Bluetooth call that has to wait for Bluetooth. Right after the manager is
/// created (the first "Find my node", often behind the permission prompt) it
/// isn't powered on yet, so a scan or reconnect does nothing. This retries the
/// call until it takes, Bluetooth says no, or the time runs out.
@MainActor
@Observable
final class PendingScan {
    /// Still waiting for Bluetooth to come up.
    private(set) var isWaiting = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `attempt` tries once and returns true when it's done: the call took, or
    /// can't work (Bluetooth not allowed). Tried now, then every `interval`.
    func start(every interval: Duration = .milliseconds(250), for limit: Duration = .seconds(60),
               _ attempt: @escaping @MainActor () -> Bool) {
        cancel()
        if attempt() { return }
        isWaiting = true
        task = Task { [weak self] in
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                if attempt() { break }
            }
            self?.isWaiting = false
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWaiting = false
    }
}
