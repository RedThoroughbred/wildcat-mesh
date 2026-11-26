import Foundation

/// The open-source software that ships inside the app (the Reticulum stack and the Python it runs
/// in), read from `Licenses/licenses.json` and the `license-<id>.txt` files beside it.
/// `THIRD_PARTY_NOTICES.md` at the repo root is made from the same files (`tools/notices.py`).
struct OpenSourceComponent: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let version: String
    let license: String
    let by: String
    let source: String
    let note: String

    /// "1.5.7 · Reticulum License"
    var line: String { "\(version) · \(license)" }

    /// The full licence text, exactly as its authors publish it.
    func text(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "license-\(id)", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func all(in bundle: Bundle = .main) -> [OpenSourceComponent] {
        guard let url = bundle.url(forResource: "licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([OpenSourceComponent].self, from: data) else { return [] }
        return list
    }
}
