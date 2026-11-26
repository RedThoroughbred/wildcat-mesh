import Foundation

/// When Wildcat asks for an App Store rating (SwiftUI's `requestReview`): at
/// most once per app version, right after something worked (another node
/// confirmed one of your messages, or you found the fox), and never while a
/// hunt, a hosted hunt or a coverage walk is running. Practice radios never
/// count. Apple shows the prompt at most three times a year whatever the app
/// asks; nothing is offered for a rating.
enum ReviewPrompt {
    /// `@AppStorage` key: the app version the rating was last asked in ("" before any).
    static let lastAskedKey = "review.lastAskedVersion"
    /// Time to see the tick or the find before the prompt covers it.
    static let delay: Duration = .seconds(2)

    /// Whether to ask now: not yet asked in `version`, nothing running, and
    /// not inside an XCTest host.
    static func shouldAsk(lastAsked: String, version: String?, busy: Bool,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let version, !version.isEmpty, lastAsked != version, !busy else { return false }
        return environment["XCTestConfigurationFilePath"] == nil
    }

    /// Still looking for the fox (a find, or the end, is not).
    static func isHunting(_ stage: HuntModel.Stage) -> Bool {
        stage == .joining || stage == .hunting
    }

    /// The running app's marketing version.
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
