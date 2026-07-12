#!/usr/bin/env python3
"""Fail when generated Nim API documentation has a broken local asset link."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[str] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        wanted = "src" if tag in {"img", "script", "source"} else "href"
        if tag not in {"a", "img", "link", "script", "source"}:
            return
        for name, value in attrs:
            if name == wanted and value:
                self.links.append(value)


def local_target(root: Path, source: Path, link: str) -> Path | None:
    parts = urlsplit(link)
    if parts.scheme or parts.netloc or not parts.path:
        return None
    decoded = unquote(parts.path)
    if Path(decoded).suffix.lower() not in {
        ".html",
        ".css",
        ".js",
        ".png",
        ".svg",
        ".ico",
        ".woff",
        ".woff2",
    }:
        return None
    if decoded.startswith("/"):
        target = root / decoded.lstrip("/")
    else:
        target = source.parent / decoded
    return target.resolve()


def check(root: Path) -> list[str]:
    root = root.resolve()
    failures: list[str] = []
    pages = sorted(root.rglob("*.html"))
    if not pages:
        return [f"no HTML files found under {root}"]

    for page in pages:
        parser = LinkParser()
        try:
            parser.feed(page.read_text(encoding="utf-8"))
        except (OSError, UnicodeError) as error:
            failures.append(f"{page.relative_to(root)}: cannot parse: {error}")
            continue

        for link in parser.links:
            target = local_target(root, page, link)
            if target is None:
                continue
            try:
                target.relative_to(root)
            except ValueError:
                failures.append(
                    f"{page.relative_to(root)}: link escapes doc root: {link}"
                )
                continue
            if not target.is_file():
                failures.append(
                    f"{page.relative_to(root)}: missing local target: {link}"
                )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default="htmldocs", type=Path)
    args = parser.parse_args()

    failures = check(args.root)
    if failures:
        for failure in failures:
            print(failure)
        return 1
    print(f"checked generated documentation links under {args.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
