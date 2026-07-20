#!/usr/bin/env bash
#
# Regenerate the keyboard-reference section of docs/index.html from the app's
# own binding definitions (KeyReference.swift + the live KeyBindingSet), so the
# docs never drift from the code. Run this after changing any keybinding:
#
#   ./scripts/gen-docs.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> building"
swift build -c release >/dev/null

echo "==> dumping keybindings"
.build/release/Tessera --dump-keybindings > /tmp/tessera-keys.html

echo "==> injecting into docs/index.html"
python3 - <<'PY'
import pathlib, re
section = pathlib.Path("/tmp/tessera-keys.html").read_text().rstrip("\n")
page = pathlib.Path("docs/index.html")
html = page.read_text()
pattern = re.compile(r"(<!-- KEYBINDINGS:START -->).*?(<!-- KEYBINDINGS:END -->)", re.S)
if not pattern.search(html):
    raise SystemExit("error: KEYBINDINGS markers not found in docs/index.html")
html = pattern.sub(lambda m: f"{m.group(1)}\n{section}\n    {m.group(2)}", html)
page.write_text(html)
print("    docs/index.html updated")
PY

rm -f /tmp/tessera-keys.html
echo "==> done"
