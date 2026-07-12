#!/usr/bin/env python3
"""Validate or clean Cordnim's generated API documentation."""

from __future__ import annotations

import argparse
import re
import shutil
from html.parser import HTMLParser
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENTRY_BLOCK = re.compile(
    r"const\s+publicEntries\s*=\s*\[(?P<body>.*?)\n\]", re.DOTALL
)
QUOTED_PATH = re.compile(r'"(src/[^"\n]+\.nim)"')
DOC_ASSETS = ("theindex.html", "nimdoc.out.css", "dochack.js")
CORE_CONTENT = {
    Path("cordnim.html"): (
        "Cordnim 0.1.0 is a preview",
        "cordnim/bot",
        "hybrid application",
        "cordnim/testing",
    ),
    Path("cordnim/bot.html"): (
        "singleProcessGateway",
        "onReady",
        "app.run()",
        "bot.interactions",
    ),
    Path("cordnim/api.html"): (
        "ChronosRestClient",
        "bot.rest",
        "ApiCallOptions",
        "cordnim/raw",
        "fetchCurrentApplication",
    ),
    Path("cordnim/interactions.html"): (
        "runtime.dispatcher",
        "bot.interactions",
        "component, modal, and autocomplete handlers",
        "CommandSet",
    ),
    Path("cordnim/doc_index.html"): (
        "Complete generated reference",
        "Cordnim 0.1.0 is a preview",
    ),
    Path("theindex.html"): (
        "cordnim/bot",
        "cordnim/api",
        "cordnim/interactions",
    ),
}


class TextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def text(self) -> str:
        text = " ".join(" ".join(self.parts).split())
        return re.sub(r"\s*([./()\[\]])\s*", r"\1", text)


def public_entries(manifest: Path) -> list[Path]:
    text = manifest.read_text(encoding="utf-8")
    match = ENTRY_BLOCK.search(text)
    if match is None:
        raise ValueError(f"{manifest} has no publicEntries block")
    entries = [Path(value) for value in QUOTED_PATH.findall(match.group("body"))]
    if not entries:
        raise ValueError("publicEntries is empty")
    duplicates = sorted({entry for entry in entries if entries.count(entry) > 1})
    if duplicates:
        rendered = ", ".join(map(str, duplicates))
        raise ValueError(f"publicEntries contains duplicates: {rendered}")
    return entries


def output_page(entry: Path) -> Path:
    relative = entry.relative_to("src")
    return relative.with_suffix(".html")


def rendered_text(page: Path) -> str:
    parser = TextParser()
    parser.feed(page.read_text(encoding="utf-8"))
    return parser.text()


def clean(root: Path) -> None:
    resolved = root.resolve()
    allowed = {
        (PROJECT_ROOT / "htmldocs").resolve(),
        (PROJECT_ROOT / "voice" / "htmldocs").resolve(),
    }
    if resolved not in allowed:
        raise ValueError(f"refusing to clean unexpected documentation root: {root}")
    shutil.rmtree(resolved, ignore_errors=True)


def check(root: Path, manifest: Path, doc_index_page: Path) -> list[str]:
    failures: list[str] = []
    package_root = manifest.parent
    for entry in public_entries(manifest):
        source = package_root / entry
        if not source.is_file():
            failures.append(f"missing public source entry: {entry}")
            continue
        page = root / output_page(entry)
        if not page.is_file() or page.stat().st_size == 0:
            failures.append(f"missing generated public API page: {page}")

    doc_index = root / doc_index_page
    if not doc_index.is_file() or doc_index.stat().st_size == 0:
        failures.append(f"missing documentation root page: {doc_index}")
    for name in DOC_ASSETS:
        asset = root / name
        if not asset.is_file() or asset.stat().st_size == 0:
            failures.append(f"missing generated documentation asset: {asset}")
    if manifest.resolve() == (PROJECT_ROOT / "cordnim.nimble").resolve():
        for relative, required in CORE_CONTENT.items():
            page = root / relative
            if not page.is_file():
                continue
            try:
                text = rendered_text(page)
            except (OSError, UnicodeError) as error:
                failures.append(f"cannot inspect generated documentation: {page}: {error}")
                continue
            for phrase in required:
                if phrase not in text:
                    failures.append(
                        f"generated documentation lacks {phrase!r}: {page}"
                    )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default="htmldocs", type=Path)
    parser.add_argument(
        "--manifest", default="cordnim.nimble", type=Path,
        help="Nimble manifest containing publicEntries",
    )
    parser.add_argument(
        "--doc-index", default="cordnim/doc_index.html", type=Path,
        help="generated documentation-root page",
    )
    parser.add_argument(
        "--clean", action="store_true", help="remove the core doc output safely"
    )
    args = parser.parse_args()
    root = args.root if args.root.is_absolute() else PROJECT_ROOT / args.root
    manifest = (
        args.manifest
        if args.manifest.is_absolute()
        else PROJECT_ROOT / args.manifest
    )

    try:
        if args.clean:
            clean(root)
            return 0
        failures = check(root, manifest, args.doc_index)
    except (OSError, ValueError) as error:
        print(error)
        return 1

    if failures:
        for failure in failures:
            print(failure)
        return 1
    print(f"checked generated public API pages under {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
