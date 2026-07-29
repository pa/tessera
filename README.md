<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icon-dark.png">
    <img src="assets/icon-light.png" width="120" alt="Tessera icon">
  </picture>
  <h1>Tessera</h1>
  <p><strong>A keyboard-driven tiling window manager for macOS — tmux/Zellij workflows for any app.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple" alt="macOS 15+">
    <img src="https://img.shields.io/badge/install-Homebrew-orange?logo=homebrew" alt="Homebrew">
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
  </p>
</div>

<p align="center">
  <a href="https://pa.github.io/tessera/">
    <img src="assets/demo.gif" width="760" alt="Tessera demo — tiling, tabs, and modal keys">
  </a>
  <br><sub><strong>▶ <a href="https://pa.github.io/tessera/">Watch the full demo</a></strong> — tiling, tabs, and modal keys in action</sub>
</p>

Tessera brings terminal-multiplexer ergonomics — **tabs, splits, panes, a command
palette, modal keys** — to *arbitrary* GUI apps by puppeting their windows through
the macOS Accessibility API. It's a menu-bar agent (look for the `▚` glyph); no
Dock icon, no window.

## Install

Install via Homebrew:

```sh
brew tap pa/tessera
brew trust pa/tessera              # required once: Homebrew gates 3rd-party taps
brew install tessera
brew services start tessera        # run now + at login
```

> `brew trust` is a one-time consent step Homebrew requires for any third-party
> tap — it can't be pre-approved on your behalf. Without it `brew install` stops
> with *"Refusing to load formula … from untrusted tap"*.

Then grant **System Settings → Privacy & Security → Accessibility → Tessera**
(the menu has a one-click shortcut), and keep **Stage Manager off** (it hides
inactive apps' windows and fights every macOS tiling WM).

> **Note — it's a menu-bar agent, not a Dock/Applications app.** After install,
> look for the **`▚` glyph in the menu bar** (start it with `brew services start
> tessera`); there is intentionally no icon in Launchpad or `/Applications`.
> `brew install --HEAD` **compiles from source**, so the first install takes a
> few minutes. It needs the Xcode Command Line Tools (Swift toolchain), which
> Homebrew already installs — so no extra setup. Prefer a `/Applications` app or
> a faster install? See **Build from source** below.

## Highlights

- **BSP tiling** with configurable padding — split any focused window horizontally/vertically.
- **Virtual tabs** — independent workspaces; a tab can be a stacked (monocle) stack of windows.
- **Modal keys** (Zellij-style) — `⌃P` pane · `⌃T` tab · `⌃R` resize, with a live, context-aware hint bar.
- **Command palette** & **workspace navigator** — fuzzy-find apps, windows, tabs, and panes.
- **Floating windows**, **full-screen zoom**, **window ↔ tab moves**, **session restore**.
- **Organize by app** — one keystroke lays every open window out as one tab per app.
- **Works with stubborn apps** — disables `AXEnhancedUserInterface` around resizes so Chromium/Electron apps (Brave, VS Code, Slack) actually tile.

## Not yet / known limits

Stated up front so nothing surprises you after install:

- **Multi-monitor is not supported yet.** Tessera manages the **main display
  only** — every layout, tab and pane is computed from the main display's bounds.
  On a multi-display setup a second monitor is not tiled independently, and a
  window that gets adopted from another display will be pulled onto the main one.
  This is the next thing on the roadmap; until then `⌃⌥⌘P` (Pause) hands every
  window straight back to macOS if you need the other screen.
- **Apps with a minimum window size overflow their pane.** A pure-Accessibility
  window manager cannot force an app below the size it will accept — only
  SIP-disabled approaches can. Tessera anchors such a window at its pane origin
  and lets it overflow rather than faking a fit. Manual float (`w` in Pane mode)
  is the escape hatch.
- **Stage Manager must be off** — it hides inactive apps' windows and fights any
  macOS tiling WM. Tessera detects it and warns in the menu bar.
- **macOS 15+ and Apple silicon.** That's what's verified and what the prebuilt
  bottle targets; older versions compile but are untested.
- **No IPC/CLI yet** (`send-cmd`, `query state --json`) — also on the roadmap.

## Quick start

Default prefix is **`⌃⌥⌘`** (Control-Option-Command). A few to get going:

| Shortcut | Action |
|---|---|
| `⌃⌥⌘R` / `⌃⌥⌘D` | Split focused window **right** / **down** |
| `⌃⌥⌘ H J K L` | Focus left / down / up / right |
| `⌃⌥⌘⇧ H J K L` | Move window between panes |
| `⌃⌥⌘⇧P` / `⌃⌥⌘⇧W` | Command palette / Workspace navigator |
| `⌃P` then `r`/`d`, `hjkl`, `w`, `f`, `s` | **Pane mode**: split · focus · float · fullscreen · stack |
| `⌃T` then `n`, `h`/`l`, `m` | **Tab mode**: new · prev/next · move-to-tab-# |

Everything is rebindable in **Settings** (`⌘,` or the menu). Full reference on the
[**documentation site**](https://pa.github.io/tessera/).

## Build from source

Prefer not to use Homebrew — or want a real **`.app` in `/Applications`**? Build
it yourself. You only need the **Xcode Command Line Tools** (which include the
Swift toolchain); install them once with `xcode-select --install`.

```sh
git clone https://github.com/pa/tessera && cd tessera
./scripts/build-app.sh                    # compile + assemble Tessera.app
cp -R .build/Tessera.app /Applications/    # (optional) install to /Applications
open /Applications/Tessera.app             # launch — look for ▚ in the menu bar
```

Because the app is **built locally** (not downloaded), it isn't Gatekeeper-
quarantined, so it launches without the "unidentified developer" prompt. Grant
Accessibility on first launch as above.

### Developing

```sh
swift build -c release    # compile just the binary
swift test                # run the TesseraCore unit tests (no app needed)
```

Test through the `.app` (not `swift run`) — macOS keys the Accessibility grant to
a stable bundle identity. See [`CLAUDE.md`](CLAUDE.md) for the architecture.

## License

MIT.
