import Foundation

/// A short built-in list of slurs and strong swearing. Messages you receive
/// that use one show the word masked until you tap; notifications never show it.
/// Whole words only, any case, so "class" and "Scunthorpe" pass.
enum WordFilter {
    static let mask = "••••"

    /// Lower-case, whole words. A plain plural matches too ("fucks"); irregular ones are listed.
    static let words: Set<String> = [
        // Slurs
        "nigger", "nigga", "faggot", "fag", "kike", "spic", "chink", "wetback", "tranny", "retard", "retarded",
        // Strong swearing
        "fuck", "fucking", "fucked", "fucker", "motherfucker", "cunt", "shit", "bullshit", "bitch", "bitches", "asshole",
        "whore", "slut",
    ]

    /// True when the text contains a listed word.
    static func matches(_ text: String) -> Bool {
        var found = false
        _ = scan(text) { word in
            if isListed(word) { found = true }
            return word
        }
        return found
    }

    /// The text with every listed word replaced by the mask.
    static func masked(_ text: String) -> String {
        scan(text) { isListed($0) ? mask : $0 }
    }

    static func isListed(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let w = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        if words.contains(w) { return true }
        if w.hasSuffix("s"), words.contains(String(w.dropLast())) { return true }
        return false
    }

    /// Rebuilds the text word by word (runs of letters and digits), keeping everything between words.
    private static func scan(_ text: String, _ replace: (String) -> String) -> String {
        var out = "", word = ""
        for ch in text {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else {
                if !word.isEmpty { out += replace(word); word = "" }
                out.append(ch)
            }
        }
        if !word.isEmpty { out += replace(word) }
        return out
    }
}
