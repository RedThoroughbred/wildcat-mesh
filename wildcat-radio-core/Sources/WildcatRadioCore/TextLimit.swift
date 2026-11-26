import Foundation

extension String {
    /// The longest run of whole characters from the start that fits in `maxBytes`
    /// of UTF-8. A radio's byte limit must never cut an emoji or an accented
    /// letter in half (that arrives as "\u{FFFD}").
    public func utf8Prefix(_ maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        var used = 0
        var end = startIndex
        for i in indices {
            let n = self[i].utf8.count
            guard used + n <= maxBytes else { break }
            used += n
            end = index(after: i)
        }
        if end > startIndex { return String(self[..<end]) }
        // One enormous character (stacked accents): cut between its scalars instead.
        var scalars = String.UnicodeScalarView()
        used = 0
        for s in unicodeScalars {
            let n = String(s).utf8.count
            guard used + n <= maxBytes else { break }
            used += n
            scalars.append(s)
        }
        return String(scalars)
    }
}
