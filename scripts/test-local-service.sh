#!/usr/bin/env bash
# Build Tessera's release-style bare binary and run it under the per-user
# launchd agent used for local testing. This deliberately does not assemble an
# .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="pramodh.ayyappan.tessera.dev"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/tessera-dev.log"
TARGET="gui/$(id -u)/$LABEL"
BINARY="$ROOT/.build/release/Tessera"

usage() {
  cat <<EOF
Usage: $(basename "$0") [start|stop|logs|status]

  start   Build the release binary and restart the local launchd service (default).
  stop    Stop and remove the local test service.
  logs    Follow the local test service log.
  status  Show launchd status for the local test service.
EOF
}

case "${1:-start}" in
  start)
    mkdir -p "$AGENTS_DIR" "$LOG_DIR"

    # Stop the previous development instance before replacing its executable.
    # Do not silently kill an installed/Homebrew instance: two Tessera processes
    # with the same identity would both try to manage the same windows.
    launchctl bootout "$TARGET" 2>/dev/null || true
    if pgrep -x Tessera >/dev/null; then
      echo "Another Tessera process is still running:" >&2
      pgrep -alf Tessera >&2 || true
      echo "Quit it first (for example: pkill -x Tessera), then rerun this script." >&2
      exit 1
    fi

    echo "==> Building release binary"
    (cd "$ROOT" && swift build -c release)

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BINARY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" >/dev/null

    launchctl bootstrap "gui/$(id -u)" "$PLIST"

    echo "==> Local Tessera service started"
    echo "    Binary: $BINARY"
    echo "    Log:    $LOG"
    ;;
  stop)
    launchctl bootout "$TARGET" 2>/dev/null || true
    rm -f "$PLIST"
    echo "==> Local Tessera service stopped"
    ;;
  logs)
    mkdir -p "$LOG_DIR"
    touch "$LOG"
    tail -f "$LOG"
    ;;
  status)
    launchctl print "$TARGET"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
