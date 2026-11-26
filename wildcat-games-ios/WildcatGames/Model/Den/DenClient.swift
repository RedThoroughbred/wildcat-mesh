import Foundation

/// Talks to one Den's Observatory over Tailscale (or the LAN).
struct DenClient {
    enum Failure: LocalizedError {
        case badURL
        case http(Int, String?)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .badURL: return "The Den address isn't a valid URL."
            case .http(let code, let message): return message ?? "The Den answered \(code)."
            case .unauthorized: return "The Den needs the operator password for that. Add it in Den settings."
            }
        }
    }

    var base: URL
    var token: String?
    var session: URLSession = .shared

    private func url(_ path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var u = base.appending(path: "v2/api/" + parts[0])
        if parts.count == 2, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = parts[1]
            u = c.url ?? u
        }
        return u
    }

    /// GET outside the Observatory's /v2/api (the games server).
    func getRaw<T: Decodable>(_ path: String) async throws -> T {
        try await fetch(URLRequest(url: base.appending(path: path), timeoutInterval: 8))
    }

    func postRaw<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: base.appending(path: path), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetch(req)
    }

    private func fetch<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        var req = URLRequest(url: url(path), timeoutInterval: 10)
        authorize(&req)
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], as: T.Type = T.self) async throws -> T {
        var req = URLRequest(url: url(path), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        authorize(&req)
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authorize(_ req: inout URLRequest) {
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Den.SendResult.self, from: data))?.error
            throw Failure.http(http.statusCode, message)
        }
    }
}
