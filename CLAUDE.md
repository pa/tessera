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

## Distribution: Homebrew, no Apple Developer ID

Tessera ships as a **single Swift binary via a Homebrew tap** — no `.app`
wrapper, no notarization, no $99/yr Developer ID, no Gatekeeper quarantine (a
source build isn't downloaded, it's compiled locally, so nothing is quarantined
— the same trick paneru uses).

```sh
brew tap pa/tessera https://github.com/pa/tessera
brew install tessera
brew services start tessera        # run now + at login
```

Two pieces make the bare binary a first-class agent that keeps its Accessibility
grant across upgrades:

1. **Embedded Info.plist.** `Package.swift` passes `-sectcreate __TEXT
   __info_plist Resources/Info.plist` linker flags, so `swift build` bakes the
   plist (LSUIElement + `CFBundleIdentifier=pramodh.ayyappan.tessera`) into the
   Mach-O's `__TEXT,__info_plist` section. `codesign` binds it on signing, so
   the bare executable has a real bundle identity with no `.app` around it.
2. **Self-sign on launch (`SelfSign.swift`).** A Homebrew source build (and each
   `brew upgrade`) is **ad-hoc** signed, whose DR is the exact code hash — so TCC
   would drop the grant on every update. On launch, if the binary isn't already
   signed with the per-user **"Tessera Code Signing"** cert, Tessera creates that
   cert once (dedicated keychain, non-interactive — same logic as
   `scripts/create-signing-cert.sh`, embedded as a string), `codesign --force
   --sign`s its own on-disk binary, and re-execs once (guarded by
   `TESSERA_SELFSIGN_DONE` against loops). Every version then shares one stable
   DR — `identifier "pramodh.ayyappan.tessera" and certificate leaf = H"<user cert>"`
   — and because TCC matches on the DR (not the path), the Accessibility grant
   **persists across upgrades**. The cert is created per-machine, so the leaf
   hash differs per user; each user grants Accessibility exactly once.
   - Gotcha: detect the cert with `security find-identity -p codesigning` **without
     `-v`**. A self-signed codesigning cert always reports
     `CSSMERR_TP_NOT_TRUSTED`, so the valid-only (`-v`) listing hides it even
     though `codesign` signs with it fine — using `-v` would make SelfSign think
     the cert is missing and recreate it, minting a new leaf and losing the grant.

`Formula/tessera.rb` builds from source (`depends_on xcode: :build`) and defines
a `brew services` launch agent. The dev flow below (`.app` bundle) is still used
for local iteration and log attachment.

## Why the .app bundle matters (do not `swift run` for real testing)

macOS keys the Accessibility (TCC) grant to an app's **code-signing identity +
bundle path**. A bare SPM executable has no stable bundle identity, so its
Accessibility access is attributed to the *parent terminal* instead — the app
can never reliably control windows. Always test through
`./scripts/build-app.sh` + the `.app`, never `swift run`.

- Bundle id: `pramodh.ayyappan.tessera` (fixed, in `Resources/Info.plist`).
- Default signing is **ad-hoc** (`-`). Ad-hoc signatures change every rebuild,
  so macOS re-prompts for Accessibility after each build. To make the grant
  stick, run `./scripts/create-signing-cert.sh` once — it creates a self-signed
  "Tessera Code Signing" identity in a dedicated keychain (non-interactive) —
  then build with `CODESIGN_IDENTITY="Tessera Code Signing" ./scripts/build-app.sh`.
  The identity gives a stable Designated Requirement (`identifier
  pramodh.ayyappan.tessera and certificate leaf = H"…"`) that TCC keys the grant to.
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
    FuzzyMatcher.swift              Subsequence fuzzy match + ranking (palette filter)
  Tessera/                          Menu-bar agent (AppKit + Accessibility)
    main.swift                      AppKit programmatic entry (menu-bar agent)
    AppDelegate.swift               Menu-bar UI + prototype actions
    Accessibility/
      AccessibilityAuthorizer.swift AX trust check / prompt
      AXWindow.swift                Typed wrapper: window position/size/title/raise
      AppTargeter.swift             Find/launch an app, get main window, focus a window
      PrivateAX.swift               _AXUIElementGetWindow shim (AX element → CGWindowID)
    Palette/
      PaletteItem.swift             A selectable row (app to launch / window to focus)
      AppCatalog.swift              Discover installed apps + on-screen windows
      CommandPaletteController.swift Borderless floating NSPanel search UI
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

**Milestone 3 (command palette) — done.** Borderless floating `NSPanel` search
bar listing installed apps (Applications-folder scan) and on-screen windows;
type-to-filter via `FuzzyMatcher`, ↑/↓/Return/Esc, click-out to dismiss.
Selecting launches an app or raises a window.

**Milestone 4 (tmux split logic) — done.** `TilingController` ties the pieces
together: split the focused pane → BSP recompute → shrink the focused window
into its half → render the empty pane (`EmptyPaneOverlay`) → pop the palette
centered in it → snap the picked window into the pane. Splits originate from the
live focused window (matched by CGWindowID, so same-app windows are
distinguished); cancelling the palette rolls the split back. Menu: Split → Right
(⌘D), Split → Down (⌘⇧D), Reset Tiling.

**Milestone 5 (virtual tabs) — done.** Each tab is an independent BSP workspace
(`TilingController.Tab`: tree + occupants + focused pane). Switching hides the
current tab's apps via `kAXHiddenAttribute` and unhides + re-snaps the target
tab's. Menu: New Tab, Next, Previous. Caveat: `kAXHiddenAttribute`
is **application-level** (no per-window hidden attribute), so a tab is
effectively a set of apps — an app spanning two tabs can't be hidden for only
one. Distinct apps per tab switch cleanly.

**Milestone 6 (global hotkeys) — done.** `HotKeyManager` registers system-wide
shortcuts via the Carbon Hot Key API (`RegisterEventHotKey`) — fires regardless
of focused app, needs no extra permission, and only sees the chords it
registers. Default prefix is ⌃⌥⌘ (a dedicated modifier so a global ⌘T doesn't
shadow per-app shortcuts).

**Configurable hotkeys (extension).** `HotKeyConfig` defines a `TilingCommand`
enum, `KeyBinding` (Carbon keycode + modifier mask), and preset sets
(Tessera / tmux-inspired / zellij-inspired / custom), persisted to
`~/Library/Application Support/Tessera/hotkeys.json`. "Hotkey Settings…" opens
`HotKeyPreferencesController`: a preset picker plus a `KeyRecorderView` per
command to record custom chords; edits apply live (`HotKeyManager.unregisterAll`
+ re-register) and switch the preset to Custom. The menu shows each command's
current chord. Note: presets are distinct **chord sets** inspired by those
tools, not a full modal prefix-key (leader) emulation — that would be a future
enhancement.

All six brief milestones are complete.

**WM enhancements (zellij/AeroSpace-inspired, post-brief).**
- **Pane navigation & move** — directional focus (`PaneNavigation`, pure + tested)
  and window-swap between panes.
- **Directional resize** — grow/shrink the focused pane by nudging the nearest
  ancestor split ratio (`BSPNode.resized(axis:grow:)`, pure + tested); the
  adjacent pane follows automatically. No constraint solver (unlike zellij).
- **Modal input** — `ModeEngine` (a single `CGEventTap`) implements zellij-style
  modes: ⌃P pane, ⌃T tab, ⌃R resize (entry keys configurable). Strict capture
  while in a mode; menu-bar glyph (`▚ P/T/R`) + `ModeHUD` hint bar. State-switch
  entry, so re-entry is reliable (a `RegisterEventHotKey` per-mode approach was
  not — it silently failed to re-arm).
- **Exclusive tabs (hide others)** — a tab shows only its tiled windows; other
  apps are `kAXHidden`, and a managed app's *other* windows are parked
  off-screen (`kAXHidden` is app-level; per-window parking covers multi-window
  apps). Restored on Reset / quit.
- **Layout enforcement** — a 0.6s timer re-snaps windows dragged/resized outside
  Tessera and removes panes whose window was closed (BSP collapse → neighbor
  fills).
- **Change Pane Window** — re-pick the focused pane's window via the palette.
- **Full-screen (zoom)** — the focused pane fills the workspace; others park
  off-screen. Toggles; auto-clears on tab switch / reset / window close.
- **Floating panes** — toggle a window out of the BSP tree to float above the
  tiles (centered), move it freely with hjkl in Pane mode, and re-tile it.
  Floating windows are exempt from layout enforcement; they park/restore with
  their tab.
- New Tab pops the palette for its first window; tab hide/show is per-window
  off-screen parking (see "z-order reality" caveat — still bounded by apps that
  clamp window position on-screen).

Pane mode keys: r/d split, hjkl focus (or move a floating window), ⇧hjkl swap,
f fullscreen, w float, c change window. Tab mode: n/]/[. Resize mode: hjkl.

## Tiling & the macOS z-order reality

Window z-order on macOS is **per-application** — only one app is frontmost, so
activating app B drops app A's windows behind it. This is invisible while tiles
don't overlap (each window owns a distinct screen region) and only shows when an
app refuses to shrink to its pane (enforces a minimum size) and spills over a
neighbor — the brief's "uncooperative app" caveat. There is no API to keep two
different apps' windows simultaneously topmost. `TilingController.focus` raises
the whole managed set together so tiled windows stay above unmanaged clutter.

**Stage Manager conflicts with tiling** (it hides non-active apps' windows) —
keep it off, like every macOS tiling WM requires. State lives in
`com.apple.WindowManager` `GloballyEnabled`.

Coordinate spaces: the BSP engine and `AXWindow` work in AX top-left space;
`NSWindow` placement (overlay, palette) is AppKit bottom-left. `ScreenGeometry`
does the flip and computes the usable workspace rect (menu bar / Dock excluded).

## Reading window titles

Window titles come from the **Accessibility** API (`kAXTitleAttribute` on each
window element), not `CGWindowList`'s `kCGWindowName`. `kCGWindowName` is gated
behind **Screen Recording** permission since macOS 10.15; AX titles need only
the Accessibility grant Tessera already has. `AppCatalog` uses AX when trusted
and falls back to `CGWindowList` (owner-name titles) otherwise. The private
`_AXUIElementGetWindow` shim (in `PrivateAX.swift`) maps an AX window element to
its `CGWindowID` for stable identity — the same symbol yabai/AeroSpace/Reef use.

## Gotchas

- Some apps (System Settings, apps with min window sizes) reject or clamp
  `AXUIElement` resize — the prototype surfaces this by reading back the frame
  and alerting when the result differs from the request. A real layout fallback
  is a later milestone.
- Swift 6 strict concurrency: `kAXTrustedCheckOptionPrompt` is a non-Sendable
  global — use the literal `"AXTrustedCheckOptionPrompt"` key instead.
