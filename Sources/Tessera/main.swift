import AppKit

// Tessera runs as a menu-bar agent (no Dock icon). AppKit's programmatic entry
// point: build the shared application, attach the delegate, and run the loop.
// Top-level code in main.swift is main-actor isolated under Swift 6, which is
// what the AppKit APIs below require.
// Docs generation: print the keyboard-reference HTML and exit, before any
// signing/AppKit setup (used by scripts/gen-docs.sh).
if ProcessInfo.processInfo.arguments.contains("--dump-keybindings") {
    print(KeyReference.html())
    exit(0)
}

// Before anything else: (1) re-sign this binary with the per-user cert if it's
// running ad-hoc (a fresh `brew install`/`upgrade`) so the Accessibility grant
// survives upgrades, and (2) disclaim the launching terminal so TCC attributes
// the grant to "Tessera", not the terminal. Re-execs once if either is needed.
SelfSign.bootstrap()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
