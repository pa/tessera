<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icon-dark.png">
    <img src="assets/icon-light.png" width="120" alt="Tessera icon">
  </picture>
  <h1>Tessera</h1>
  <p><strong>A keyboard-driven tiling window manager for macOS — tmux/Zellij workflows for any app.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
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
brew tap pa/tessera https://github.com/pa/tessera
brew install --HEAD tessera
brew services start tessera        # run now + at login
```

Then grant **System Settings → Privacy & Security → Accessibility → Tessera**
(the menu has a one-click shortcut), and keep **Stage Manager off**.

> Keep **Stage Manager off** (it hides inactive apps' windows and fights every
> macOS tiling WM).

## Highlights

- **BSP tiling** with configurable padding — split any focused window horizontally/vertically.
- **Virtual tabs** — independent workspaces; a tab can be a stacked (monocle) stack of windows.
- **Modal keys** (Zellij-style) — `⌃P` pane · `⌃T` tab · `⌃R` resize, with a live, context-aware hint bar.
- **Command palette** & **workspace navigator** — fuzzy-find apps, windows, tabs, and panes.
- **Floating windows**, **full-screen zoom**, **window ↔ tab moves**, **session restore**.
- **Organize by app** — one keystroke lays every open window out as one tab per app.
- **Works with stubborn apps** — disables `AXEnhancedUserInterface` around resizes so Chromium/Electron apps (Brave, VS Code, Slack) actually tile.

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

## Build from source (dev)

```sh
swift build -c release          # compile
swift test                      # run the TesseraCore unit tests
./scripts/build-app.sh          # assemble + sign a .app for local testing
```

Test through the `.app` (not `swift run`) — macOS keys the Accessibility grant to
a stable bundle identity. See [`CLAUDE.md`](CLAUDE.md) for the architecture.

## License

MIT.
