import Foundation

/// What a build shows. Things that are on the branch but not released yet stay in Debug builds.
enum Features {
    /// Small Play (the Hunt game for 2–3 friends, "Who's playing?" on Play, its invites and
    /// guide pages): Debug builds only until it is released.
    static var smallPlay: Bool {
        #if DEBUG
        // -StoreLook shows a Debug build as the App Store build looks (for screenshots).
        return !ProcessInfo.processInfo.arguments.contains("-StoreLook")
        #else
        return false
        #endif
    }
}
