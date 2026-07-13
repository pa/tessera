import Foundation

/// Pure subsequence fuzzy matching + ranking for the command palette.
///
/// Kept UI-independent (and here in `TesseraCore`) so the ranking behaviour is
/// unit-testable without launching the agent. The palette feeds it candidate
/// strings (app names, window titles); it returns a score or filters/orders a
/// list. Higher score = better match.
public enum FuzzyMatcher {
    /// Characters that begin a new "word", so a match right after one earns a
    /// boundary bonus (e.g. the "S" in "App Store" or after "-", "_", "/").
    private static let separators: Set<Character> = [" ", "-", "_", ".", "/", ":"]

    /// Score `query` against `candidate`, case-insensitively. Returns nil when
    /// `query` isn't a subsequence of `candidate`. An empty query matches
    /// everything with score 0.
    ///
    /// Scoring rewards matches that are contiguous and that land on word
    /// boundaries (start of string, after a separator, or a camelCase hump) —
    /// so "saf" scores "Safari" above "Msf Archive".
    public static func score(query: String, in candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        let q = Array(query.lowercased())
        let cLower = Array(candidate.lowercased())
        let cRaw = Array(candidate)
        guard !cLower.isEmpty else { return nil }

        var qi = 0
        var total = 0
        var previousMatchIndex: Int? = nil

        for i in 0..<cLower.count {
            guard qi < q.count, cLower[i] == q[qi] else { continue }

            var charScore = 1
            if let prev = previousMatchIndex, prev == i - 1 {
                // Contiguous run. Weighted above the boundary bonus so a solid
                // prefix ("Cal" → Calendar) beats a scattered acronym
                // ("Custom App Layer") for the same query.
                charScore += 7
            }
            if isBoundary(at: i, in: cRaw) {
                charScore += 6 // word-boundary match
            }
            if i == 0 {
                charScore += 2 // very first character
            }
            total += charScore
            previousMatchIndex = i
            qi += 1
            if qi == q.count { break }
        }

        return qi == q.count ? total : nil
    }

    /// Filter `items` to those matching `query` and order them best-first.
    /// Ties break toward the shorter candidate, then original order — so the
    /// result is fully deterministic (important for tests and stable UI).
    /// An empty query returns `items` unchanged.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        if query.isEmpty { return items }

        let scored = items.enumerated().compactMap { index, item -> (item: T, score: Int, length: Int, index: Int)? in
            guard let s = score(query: query, in: key(item)) else { return nil }
            return (item, s, key(item).count, index)
        }

        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.index < b.index
        }.map(\.item)
    }

    private static func isBoundary(at i: Int, in chars: [Character]) -> Bool {
        if i == 0 { return true }
        let prev = chars[i - 1]
        if separators.contains(prev) { return true }
        // camelCase hump: lower/space→Upper transition.
        if prev.isLowercase && chars[i].isUppercase { return true }
        return false
    }
}
