import AppKit

// Tessera runs as a menu-bar agent (no Dock icon). AppKit's programmatic entry
// point: build the shared application, attach the delegate, and run the loop.
// Top-level code in main.swift is main-actor isolated under Swift 6, which is
// what the AppKit APIs below require.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
