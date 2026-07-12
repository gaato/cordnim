#!/usr/bin/env python3
"""Validate the staged GitHub Pages Nimdoc layout."""

from __future__ import annotations

import argparse
from pathlib import Path


REQUIRED = (
    Path("index.html"),
    Path("theindex.html"),
    Path("nimdoc.out.css"),
    Path("dochack.js"),
    Path("cordnim/bot.html"),
    Path("cordnim/api.html"),
    Path("cordnim/interactions.html"),
    Path("voice/index.html"),
    Path("voice/theindex.html"),
    Path("voice/nimdoc.out.css"),
    Path("voice/dochack.js"),
    Path(".nojekyll"),
)
FORBIDDEN = (Path("api"), Path("guide"), Path("styles.css"))


def check(root: Path) -> list[str]:
    failures: list[str] = []
    for relative in REQUIRED:
        target = root / relative
        if not target.is_file():
            failures.append(f"missing staged Pages file: {target}")
    for relative in FORBIDDEN:
        target = root / relative
        if target.exists():
            failures.append(f"unexpected legacy Pages path: {target}")

    aliases = (
        (root / "index.html", root / "theindex.html"),
        (root / "voice" / "index.html", root / "voice" / "theindex.html"),
    )
    for alias, source in aliases:
        if (
            alias.is_file()
            and source.is_file()
            and alias.read_bytes() != source.read_bytes()
        ):
            failures.append(f"staged index does not match Nimdoc index: {alias}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default="build/pages", type=Path)
    args = parser.parse_args()
    failures = check(args.root)
    if failures:
        for failure in failures:
            print(failure)
        return 1
    print(f"checked staged Nimdoc Pages layout under {args.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
