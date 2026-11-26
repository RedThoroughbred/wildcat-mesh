import Foundation

/// The 4-digit code written on the fox box. The host form starts with a random
/// one, so nobody has to invent it, and never a guessable one.
enum FoxCode {
    /// A random code that isn't trivial (see `isTrivial`).
    static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return random(using: &g)
    }

    static func random<G: RandomNumberGenerator>(using g: inout G) -> String {
        while true {
            let code = String(format: "%04d", Int.random(in: 0...9999, using: &g))
            if !isTrivial(code) { return code }
        }
    }

    /// One digit four times (0000, 7777) or a straight run up or down (1234, 6789, 4321, 3210):
    /// the first codes anyone would try.
    static func isTrivial(_ code: String) -> Bool {
        let d = code.compactMap(\.wholeNumberValue)
        guard d.count == 4, code.count == 4 else { return false }
        let steps = zip(d, d.dropFirst()).map { $1 - $0 }
        return steps.allSatisfy { $0 == 0 } || steps.allSatisfy { $0 == 1 } || steps.allSatisfy { $0 == -1 }
    }
}
