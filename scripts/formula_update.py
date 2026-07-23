#!/usr/bin/env python3
"""Edit the Homebrew formula in place for a release — used by the release
workflow so bottling is fully automated (no hand-edits).

  # point at a new tag's source tarball + checksum, and drop any old bottle:
  formula_update.py Formula/tessera.rb --url <URL> --sha <SRC_SHA> --strip-bottle

  # add the freshly-built bottle block (from `brew bottle --json` output):
  formula_update.py Formula/tessera.rb --bottle-json out.json --root-url <URL>
"""
import argparse
import json
import re


def strip_bottle(text: str) -> str:
    return re.sub(r"\n  bottle do\n(?:.*\n)*?  end\n", "\n", text)


def set_url_sha(text: str, url: str, sha: str) -> str:
    text = re.sub(r'(\n\s*url ").*?(")', lambda m: m.group(1) + url + m.group(2), text, count=1)
    # The FIRST sha256 "…" is the source checksum (bottle shas use `sha256 cellar:`).
    text = re.sub(r'(\n\s*sha256 ")[a-f0-9]{64}(")', lambda m: m.group(1) + sha + m.group(2), text, count=1)
    return text


def insert_bottle(text: str, jsonfile: str, root_url: str) -> str:
    data = json.load(open(jsonfile))
    lines = ["  bottle do", f'    root_url "{root_url}"']
    for _, info in data.items():
        for tag, t in info["bottle"]["tags"].items():
            cellar = t.get("cellar", "any_skip_relocation")
            cell = f":{cellar}" if cellar in ("any", "any_skip_relocation") else f'"{cellar}"'
            lines.append(f'    sha256 cellar: {cell}, {tag}: "{t["sha256"]}"')
    block = "\n".join(lines) + "\n  end\n"
    # Place it right after the `head "…"` line.
    return re.sub(r'(\n\s*head ".*?"[^\n]*\n)', lambda m: m.group(1) + "\n" + block, text, count=1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("formula")
    ap.add_argument("--url")
    ap.add_argument("--sha")
    ap.add_argument("--strip-bottle", action="store_true")
    ap.add_argument("--bottle-json")
    ap.add_argument("--root-url")
    a = ap.parse_args()

    text = open(a.formula).read()
    if a.strip_bottle:
        text = strip_bottle(text)
    if a.url and a.sha:
        text = set_url_sha(text, a.url, a.sha)
    if a.bottle_json and a.root_url:
        text = strip_bottle(text)  # avoid duplicate blocks on re-run
        text = insert_bottle(text, a.bottle_json, a.root_url)
    open(a.formula, "w").write(text)


if __name__ == "__main__":
    main()
