# Tessera

A native macOS menu-bar app that brings terminal-multiplexer workflows
(tmux/Zellij: tabs, splits, panes, a command palette) to arbitrary GUI apps by
puppeting their windows through the Accessibility (`AXUIElement`) APIs.

## Build & run

```sh
swift build -c release            # compile only
./scripts/build-app.sh            # compile + assemble a signed .app bundle
open .build/Tessera.app           # launch the menu-bar agent
.build/Tessera.app/Contents/MacOS/Tessera   # launch attached to a terminal (see logs)
```

Tessera is a menu-bar agent (`LSUIElement`), so there is no Dock icon or window
— look for the `▚` glyph in the menu bar after launch.

## Why the .app bundle matters (do not `swift run` for real testing)

macOS keys the Accessibility (TCC) grant to an app's **code-signing identity +
bundle path**. A bare SPM executable has no stable bundle identity, so its
Accessibility access is attributed to the *parent terminal* instead — the app
can never reliably control windows. Always test through
`./scripts/build-app.sh` + the `.app`, never `swift run`.

- Bundle id: `cloud.facets.tessera` (fixed, in `Resources/Info.plist`).
- Default signing is **ad-hoc** (`-`). Ad-hoc signatures change every rebuild,
  so macOS re-prompts for Accessibility after each build. To make the grant
  stick, run `./scripts/create-signing-cert.sh` once — it creates a self-signed
  "Tessera Code Signing" identity in a dedicated keychain (non-interactive) —
  then build with `CODESIGN_IDENTITY="Tessera Code Signing" ./scripts/build-app.sh`.
  The identity gives a stable Designated Requirement (`identifier
  cloud.facets.tessera and certificate leaf = H"…"`) that TCC keys the grant to.
  Switching signing identity (ad-hoc → cert, or regenerating the cert) requires
  re-granting Accessibility once.

## Accessibility permission

The app needs System Settings → Privacy & Security → Accessibility. On first
launch it triggers the system prompt; the menu also has a one-click "grant"
row that deep-links to the pane. `AXIsProcessTrusted()` reports the live state.

## Coordinate space

AX position/size and `CGDisplayBounds` share a **top-left-origin, y-down**
global coordinate space. Tessera works entirely in that space — do NOT use
AppKit's `NSScreen.frame` (bottom-left origin) for placement math without
flipping. `ScreenLayout` centralizes this.

## Layout / structure

```
Sources/
  TesseraCore/                      Pure, UI-independent logic (CoreGraphics only)
    ScreenLayout.swift              Screen-relative named placements (prototype)
    BSPLayout.swift                 BSP tree + LayoutTree: split/remove/resize → frames
  Tessera/                          Menu-bar agent (AppKit + Accessibility)
    main.swift                      AppKit programmatic entry (menu-bar agent)
    AppDelegate.swift               Menu-bar UI + prototype actions
    Accessibility/
      AccessibilityAuthorizer.swift AX trust check / prompt
      AXWindow.swift                Typed wrapper: read/set window position & size
      AppTargeter.swift             Find (or launch) an app, get its main window
Tests/TesseraCoreTests/             swift-testing unit tests for the core
Resources/Info.plist                Bundle metadata (id, LSUIElement)
scripts/build-app.sh                Build + package + codesign
scripts/create-signing-cert.sh      One-time self-signed cert for a persistent AX grant
```

Run the core tests with `swift test`. `TesseraCore` has no AppKit dependency,
so the layout logic is testable without launching the agent.

## Status

**Milestone 1 (Accessibility control prototype) — done.** Request permission and
move/resize a target app (Terminal/Safari) to exact coordinates via the menu.

**Milestone 2 (BSP layout engine) — done.** `BSPLayout` computes exact
x/y/width/height for panes across horizontal/vertical splits, with outer/inner
gaps and a per-window titlebar/border inset knob. Pure value type, 14 unit tests.

Next milestones (see the flow task brief): command palette → tmux split logic
→ virtual tabs (`kAXHiddenAttribute`) → global hotkeys (Carbon event taps).

## Gotchas

- Some apps (System Settings, apps with min window sizes) reject or clamp
  `AXUIElement` resize — the prototype surfaces this by reading back the frame
  and alerting when the result differs from the request. A real layout fallback
  is a later milestone.
- Swift 6 strict concurrency: `kAXTrustedCheckOptionPrompt` is a non-Sendable
  global — use the literal `"AXTrustedCheckOptionPrompt"` key instead.
