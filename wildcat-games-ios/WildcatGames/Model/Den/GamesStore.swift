import Foundation
import Observation

/// The Den's games server (wildcat-games-app, port 5070): hosting and
/// watching Fox Hunts. It sits next to the Observatory on the same host.
@MainActor
@Observable
final class GamesStore {
    struct Signal: Decodable, Equatable {
        var rssi: Double?
        var snr: Double?
        var score: Double?
    }

    struct Found: Decodable, Equatable {
        var place: Int?
        var points: Int?
        var clock: String?
        var tags: [String]?
    }

    struct Hunter: Decodable, Equatable, Identifiable {
        var id: String
        var name: String?
        var best: Signal?
        var last: Signal?
        var trend: String?
        var found: Found?
        var left: Bool?
        var bad_codes: Int?
    }

    struct Hunt: Decodable, Equatable {
        var code: String?
        var fox: String?
        var fox_name: String?
        var mode: String?
        var phase: String?
        var started_at: Double?
        var channel_name: String?
    }

    struct HuntState: Decodable, Equatable {
        var hunt: Hunt
        var hunters: [Hunter]
        var finds: [String]?
    }

    private struct Snapshot: Decodable {
        struct Wrapper: Decodable { var state: HuntState? }
        var hunt: Wrapper?
    }

    private struct Result: Decodable {
        var ok: Bool?
        var error: String?
    }

    private(set) var state: HuntState?
    private(set) var reachable: Bool?
    private(set) var error: String?
    private let den: DenStore
    private var polling: Task<Void, Never>?

    init(den: DenStore) { self.den = den }

    static let port = 5070

    /// Same host as the Den's Observatory, port 5070.
    var client: DenClient? {
        guard var c = den.client, var comps = URLComponents(url: c.base, resolvingAgainstBaseURL: false) else { return nil }
        comps.port = Self.port
        comps.path = ""
        guard let url = comps.url else { return nil }
        c.base = url
        c.token = nil
        return c
    }

    var isLive: Bool { state?.hunt.phase == "live" }
    var isOpen: Bool { state != nil && state?.hunt.phase != "ended" }

    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        guard let c = client else { return }
        do {
            // The games server's API lives at /api/…, not under /v2.
            let s: Snapshot = try await c.getRaw("api/state")
            state = s.hunt?.state
            reachable = true
            error = nil
        } catch {
            reachable = false
            self.error = "The games server isn't answering on port \(Self.port)."
        }
    }

    func create(fox: String, code: String, mode: String, channel: String) async throws {
        try await post("create", ["fox": fox, "fox_code": code, "mode": mode, "channel_name": channel])
    }

    func start() async throws { try await post("start", [:]) }
    func end() async throws { try await post("end", [:]) }

    private func post(_ action: String, _ body: [String: Any]) async throws {
        guard let c = client else { throw DenClient.Failure.badURL }
        let r: Result = try await c.postRaw("api/hunt/\(action)", body: body)
        if r.ok != true { throw DenClient.Failure.http(400, r.error ?? "The games server said no.") }
        await refresh()
    }
}
