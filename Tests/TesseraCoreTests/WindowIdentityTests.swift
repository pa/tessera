import Testing
@testable import TesseraCore

@Suite("Window identity matching")
struct WindowIdentityTests {
    @Test("A matching bundle and live window ID wins over title")
    func prefersBundleAndWindowID() {
        let saved = WindowIdentity(bundleID: "com.example.editor", title: "Notes", windowID: 42)
        let candidates = [
            WindowIdentity(bundleID: "com.example.editor", title: "Notes", windowID: 7),
            WindowIdentity(bundleID: "com.example.editor", title: "Other", windowID: 42),
        ]

        #expect(WindowMatcher.bestMatchIndex(for: saved, in: candidates) == 1)
    }

    @Test("A recycled window ID from another app is not accepted")
    func doesNotTrustWindowIDAcrossBundles() {
        let saved = WindowIdentity(bundleID: "com.example.editor", title: "Notes", windowID: 42)
        let candidates = [
            WindowIdentity(bundleID: "com.example.other", title: "Notes", windowID: 42),
        ]

        #expect(WindowMatcher.bestMatchIndex(for: saved, in: candidates) == nil)
    }

    @Test("Title then bundle are restart-safe fallbacks")
    func fallsBackToTitleThenBundle() {
        let saved = WindowIdentity(bundleID: "com.example.editor", title: "Notes", windowID: 42)
        let candidates = [
            WindowIdentity(bundleID: "com.example.editor", title: "Other", windowID: 5),
            WindowIdentity(bundleID: "com.example.editor", title: "Notes", windowID: 6),
        ]

        #expect(WindowMatcher.bestMatchIndex(for: saved, in: candidates) == 1)
        #expect(WindowMatcher.bestMatchIndex(
            for: WindowIdentity(bundleID: "com.example.editor", title: "Missing", windowID: nil),
            in: candidates
        ) == 0)
    }

    @Test("Removing each match prevents duplicate assignment without window IDs")
    func candidatesAreConsumedByCaller() {
        let saved = WindowIdentity(bundleID: "com.example.editor", title: "Notes", windowID: nil)
        var candidates = [
            WindowIdentity(bundleID: "com.example.editor", title: "Notes", windowID: nil),
        ]

        let first = WindowMatcher.bestMatchIndex(for: saved, in: candidates)
        #expect(first == 0)
        candidates.remove(at: first!)
        #expect(WindowMatcher.bestMatchIndex(for: saved, in: candidates) == nil)
    }
}
