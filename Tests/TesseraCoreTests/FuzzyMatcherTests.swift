import Testing
@testable import TesseraCore

@Suite("Fuzzy matcher")
struct FuzzyMatcherTests {

    @Test("Empty query matches everything with score 0")
    func emptyQueryMatches() {
        #expect(FuzzyMatcher.score(query: "", in: "Safari") == 0)
    }

    @Test("A subsequence matches; a non-subsequence does not")
    func subsequenceMatching() {
        #expect(FuzzyMatcher.score(query: "sfr", in: "Safari") != nil) // S-a-f-a-r-i
        #expect(FuzzyMatcher.score(query: "xyz", in: "Safari") == nil)
        // Out-of-order is not a subsequence.
        #expect(FuzzyMatcher.score(query: "ras", in: "Safari") == nil)
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() {
        #expect(FuzzyMatcher.score(query: "SAF", in: "safari") != nil)
        #expect(FuzzyMatcher.score(query: "saf", in: "SAFARI") != nil)
    }

    @Test("A prefix / contiguous match outscores a scattered one")
    func contiguousBeatsScattered() {
        let prefix = FuzzyMatcher.score(query: "cal", in: "Calendar")!
        let scattered = FuzzyMatcher.score(query: "cal", in: "Custom App Layer")!
        #expect(prefix > scattered)
    }

    @Test("A word-boundary match outscores a mid-word one of equal length")
    func boundaryBonus() {
        // "st" as the start of "Store" (boundary) vs. buried inside "Toaster".
        let boundary = FuzzyMatcher.score(query: "st", in: "App Store")!
        let midWord = FuzzyMatcher.score(query: "st", in: "Toaster")!
        #expect(boundary > midWord)
    }

    @Test("camelCase humps count as boundaries")
    func camelCaseBoundary() {
        #expect(FuzzyMatcher.score(query: "ps", in: "PlayStation") != nil)
        let camel = FuzzyMatcher.score(query: "ps", in: "PlayStation")!
        let buried = FuzzyMatcher.score(query: "ps", in: "capstone")!
        #expect(camel > buried)
    }

    @Test("rank on empty query returns items unchanged")
    func rankEmptyQueryIdentity() {
        let items = ["Safari", "Mail", "Calendar"]
        #expect(FuzzyMatcher.rank(items, query: "", key: { $0 }) == items)
    }

    @Test("rank filters out non-matches")
    func rankFilters() {
        let items = ["Safari", "Mail", "Calendar"]
        let result = FuzzyMatcher.rank(items, query: "cal", key: { $0 })
        #expect(result == ["Calendar"])
    }

    @Test("rank orders the best match first")
    func rankOrdersBestFirst() {
        let items = ["Mail Archive", "Safari"]
        // "saf" is a clean prefix of Safari; only a scattered match in the other.
        let result = FuzzyMatcher.rank(items, query: "saf", key: { $0 })
        #expect(result.first == "Safari")
    }

    @Test("Ties break toward the shorter candidate")
    func rankShorterWinsTie() {
        let items = ["Notes Manager", "Notes"]
        let result = FuzzyMatcher.rank(items, query: "notes", key: { $0 })
        #expect(result.first == "Notes")
    }

    @Test("rank is deterministic for equal score + length")
    func rankDeterministic() {
        let items = ["abc", "abd"] // both match "ab" identically, same length
        let result = FuzzyMatcher.rank(items, query: "ab", key: { $0 })
        #expect(result == ["abc", "abd"]) // original order preserved
    }
}
