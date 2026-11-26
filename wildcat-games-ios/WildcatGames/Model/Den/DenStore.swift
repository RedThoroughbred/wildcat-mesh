import Foundation
import Observation

/// Everything the Den tab shows, refreshed from the Den's Observatory.
@MainActor
@Observable
final class DenStore {
    static let urlKey = "den.url"
    /// No default: each player points the app at their own Den.
    static let defaultURL = ""
    static let tokenAccount = "operator-token"

    var urlString: String {
        didSet { defaults.set(urlString, forKey: Self.urlKey) }
    }
    private(set) var hasToken: Bool

    private(set) var health: Den.Health?
    private(set) var about: Den.About?
    private(set) var services: Den.Services?
    private(set) var nodes: [Den.Node] = []
    private(set) var myID: String?
    private(set) var signal: Den.Signal?
    private(set) var chat: [Den.ChatMessage] = []
    private(set) var channels: [Den.Channels.Channel] = []
    private(set) var sos: Den.SOS?
    private(set) var authorized: Bool?
    private(set) var lastUpdated: Date?
    private(set) var error: String?
    private(set) var isLoading = false

    private let defaults: UserDefaults
    private var polling: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        urlString = defaults.string(forKey: Self.urlKey) ?? Self.defaultURL
        hasToken = Keychain.read(Self.tokenAccount) != nil
    }

    /// A Den address has been entered.
    var isPaired: Bool { !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var isReachable: Bool { health?.ok == true && error == nil }

    var client: DenClient? {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return DenClient(base: url, token: Keychain.read(Self.tokenAccount))
    }

    func setToken(_ token: String?) {
        Keychain.write(token?.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.tokenAccount)
        hasToken = Keychain.read(Self.tokenAccount) != nil
        Task { await refreshAuth() }
    }

    // MARK: Refresh

    func startPolling(every seconds: Double = 15) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        guard let c = client else {
            error = DenClient.Failure.badURL.localizedDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let h: Den.Health = c.get("health")
            async let a: Den.About = c.get("about")
            async let n: Den.Nodes = c.get("nodes")
            async let s: Den.Signal = c.get("signal")
            async let ch: Den.Chat = c.get("chat")
            async let chans: Den.Channels = c.get("channels/compact")
            let (health, about, nodes, signal, chat, chans2) = try await (h, a, n, s, ch, chans)
            self.health = health
            self.about = about
            self.nodes = nodes.nodes
            self.myID = nodes.my_id ?? health.my_id
            self.signal = signal
            self.chat = chat.messages.sorted { ($0.ts ?? 0) < ($1.ts ?? 0) }
            self.channels = chans2.c
            // Less important: don't fail the refresh over these.
            self.services = try? await c.get("services")
            self.sos = try? await c.get("sos")
            await refreshAuth()
            lastUpdated = Date()
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func refreshAuth() async {
        guard let c = client, let a: Den.Auth = try? await c.get("auth") else { return }
        authorized = a.required == true ? a.authorized : true
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return "Can't reach the Den. Is Tailscale on, and is the Pi running?"
            default: break
            }
        }
        return error.localizedDescription
    }

    private(set) var coverage: [Den.Coverage.Point] = []

    /// The Den's passive coverage (last 30 days), loaded on demand.
    func loadCoverage() async {
        guard let c = client, let cov: Den.Coverage = try? await c.get("coverage?hours=720") else { return }
        coverage = cov.points.filter { ($0.hops ?? 0) == 0 && $0.lat != nil && $0.lon != nil }
    }

    // MARK: Actions

    /// Sends a text through the Den's radio. `to` is "^all" or "!nodeid".
    func send(_ text: String, to: String = "^all", channel: Int) async throws {
        guard let c = client else { throw DenClient.Failure.badURL }
        let result: Den.SendResult = try await c.post("tx", body: ["to": to, "text": text, "channel": channel])
        if result.ok != true { throw DenClient.Failure.http(200, result.error ?? "The Den didn't accept the message.") }
        await refresh()
    }

    // MARK: Lookups

    func node(_ id: String?) -> Den.Node? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    func channelName(_ index: Int?) -> String {
        guard let index else { return "" }
        return channels.first { $0.i == index }?.n ?? "Ch \(index)"
    }

    var denNode: Den.Node? { node(myID) }
}
