#!/usr/bin/env python3
"""Build the human guide and nest generated Nimdoc under /api/."""

from __future__ import annotations

import argparse
import html
import re
import shutil
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SAFE_OUTPUT = (PROJECT_ROOT / "build" / "pages").resolve()
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
FENCE = re.compile(r"^```([A-Za-z0-9_+-]*)\s*$")
ORDERED = re.compile(r"^\d+\.\s+(.+)$")
UNORDERED = re.compile(r"^-\s+(.+)$")
TABLE_RULE = re.compile(r"^\s*\|?(?:\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?\s*$")
CODE_SPAN = re.compile(r"`([^`]+)`")
LINK = re.compile(r"\[([^]]+)]\(([^)]+)\)")
STRONG = re.compile(r"\*\*([^*]+)\*\*")
EMPHASIS = re.compile(r"(?<!\*)\*([^*]+)\*(?!\*)")


def rewrite_link(target: str, from_readme: bool) -> str:
    if target.startswith(("http://", "https://", "mailto:", "#")):
        return target
    path, marker, fragment = target.partition("#")
    if path.endswith(".md"):
        if from_readme and path.startswith("docs/"):
            path = path.removeprefix("docs/")
        path = path[:-3] + ".html"
    return path + (marker + fragment if marker else "")


def inline(value: str, from_readme: bool = False) -> str:
    placeholders: list[str] = []

    def save_code(match: re.Match[str]) -> str:
        placeholders.append("<code>" + html.escape(match.group(1)) + "</code>")
        return f"\x00{len(placeholders) - 1}\x00"

    rendered = CODE_SPAN.sub(save_code, value)
    rendered = html.escape(rendered, quote=False)

    def link_value(match: re.Match[str]) -> str:
        label = match.group(1)
        target = rewrite_link(html.unescape(match.group(2)), from_readme)
        return f'<a href="{html.escape(target, quote=True)}">{label}</a>'

    rendered = LINK.sub(link_value, rendered)
    rendered = STRONG.sub(r"<strong>\1</strong>", rendered)
    rendered = EMPHASIS.sub(r"<em>\1</em>", rendered)
    for index, replacement in enumerate(placeholders):
        rendered = rendered.replace(f"\x00{index}\x00", replacement)
    return rendered


def slug(value: str) -> str:
    plain = re.sub(r"[`*_]", "", value).lower()
    plain = re.sub(r"[^a-z0-9]+", "-", plain).strip("-")
    return plain or "section"


def table_cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def render_markdown(text: str, from_readme: bool = False) -> tuple[str, str]:
    lines = text.splitlines()
    output: list[str] = []
    title = "Cordnim guide"
    paragraph: list[str] = []
    index = 0

    def flush_paragraph() -> None:
        if paragraph:
            output.append("<p>" + inline(" ".join(paragraph), from_readme) + "</p>")
            paragraph.clear()

    while index < len(lines):
        line = lines[index]
        fence = FENCE.match(line)
        if fence:
            flush_paragraph()
            language = fence.group(1)
            code: list[str] = []
            index += 1
            while index < len(lines) and not FENCE.match(lines[index]):
                code.append(lines[index])
                index += 1
            class_name = f' class="language-{html.escape(language)}"' if language else ""
            output.append(
                f'<pre tabindex="0"><code{class_name}>'
                + html.escape("\n".join(code))
                + "</code></pre>"
            )
            index += 1
            continue

        heading = HEADING.match(line)
        if heading:
            flush_paragraph()
            level = len(heading.group(1))
            value = heading.group(2)
            if level == 1:
                title = re.sub(r"[`*_]", "", value)
            output.append(
                f'<h{level} id="{slug(value)}">{inline(value, from_readme)}</h{level}>'
            )
            index += 1
            continue

        if index + 1 < len(lines) and "|" in line and TABLE_RULE.match(lines[index + 1]):
            flush_paragraph()
            headers = table_cells(line)
            index += 2
            rows: list[list[str]] = []
            while index < len(lines) and "|" in lines[index] and lines[index].strip():
                rows.append(table_cells(lines[index]))
                index += 1
            output.append(
                '<div class="table-scroll" tabindex="0"><table><thead><tr>'
            )
            output.extend(
                f'<th scope="col">{inline(cell, from_readme)}</th>' for cell in headers
            )
            output.append("</tr></thead><tbody>")
            for row in rows:
                output.append("<tr>")
                output.extend(
                    f"<td>{inline(cell, from_readme)}</td>" for cell in row
                )
                output.append("</tr>")
            output.append("</tbody></table></div>")
            continue

        unordered = UNORDERED.match(line)
        ordered = ORDERED.match(line)
        if unordered or ordered:
            flush_paragraph()
            tag = "ul" if unordered else "ol"
            pattern = UNORDERED if unordered else ORDERED
            items: list[str] = []
            while index < len(lines):
                item = pattern.match(lines[index])
                if not item:
                    break
                value = item.group(1)
                index += 1
                while index < len(lines) and lines[index].startswith("  "):
                    value += " " + lines[index].strip()
                    index += 1
                items.append(value)
            output.append(f"<{tag}>")
            output.extend(
                f"<li>{inline(item, from_readme)}</li>" for item in items
            )
            output.append(f"</{tag}>")
            continue

        if line.startswith("> "):
            flush_paragraph()
            quote: list[str] = []
            while index < len(lines) and lines[index].startswith("> "):
                quote.append(lines[index][2:])
                index += 1
            output.append(
                "<blockquote><p>"
                + inline(" ".join(quote), from_readme)
                + "</p></blockquote>"
            )
            continue

        if not line.strip():
            flush_paragraph()
        else:
            paragraph.append(line.strip())
        index += 1

    flush_paragraph()
    return title, "\n".join(output)


def guide_page(title: str, body: str, source: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="{html.escape(title, quote=True)} in the Cordnim guide.">
  <title>{html.escape(title)} | Cordnim</title>
  <link rel="stylesheet" href="../styles.css">
</head>
<body>
  <a class="skip-link" href="#content">Skip to content</a>
  <header class="site-header">
    <nav class="nav-shell" aria-label="Primary navigation">
      <a class="wordmark" href="../">cordnim</a>
      <div class="nav-links">
        <a href="overview.html">Guide</a>
        <a href="../api/cordnim.html">API</a>
        <a href="https://github.com/gaato/cordnim">GitHub</a>
      </div>
    </nav>
  </header>
  <main id="content" class="guide-shell" tabindex="-1">
{body}
    <p class="guide-source">Source: <a href="https://github.com/gaato/cordnim/blob/main/{html.escape(source, quote=True)}">{html.escape(source)}</a></p>
  </main>
</body>
</html>
"""


def build(api: Path, voice_api: Path, output: Path) -> None:
    if output.resolve() != SAFE_OUTPUT:
        raise ValueError(f"refusing unexpected Pages output: {output}")
    for source in (api, voice_api):
        if not (source / "theindex.html").is_file():
            raise ValueError(f"missing generated Nimdoc index: {source}")

    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    shutil.copy2(PROJECT_ROOT / "docs-site" / "index.html", output / "index.html")
    shutil.copy2(PROJECT_ROOT / "docs-site" / "styles.css", output / "styles.css")
    shutil.copytree(api, output / "api")
    shutil.copy2(output / "api" / "theindex.html", output / "api" / "index.html")
    shutil.copytree(voice_api, output / "api" / "voice")
    shutil.copy2(
        output / "api" / "voice" / "theindex.html",
        output / "api" / "voice" / "index.html",
    )

    guide = output / "guide"
    guide.mkdir()
    sources = [(PROJECT_ROOT / "README.md", "overview.html", True)]
    sources.extend(
        (path, path.with_suffix(".html").name, False)
        for path in sorted((PROJECT_ROOT / "docs").glob("*.md"))
    )
    for source, name, from_readme in sources:
        title, body = render_markdown(
            source.read_text(encoding="utf-8"), from_readme=from_readme
        )
        relative_source = source.relative_to(PROJECT_ROOT).as_posix()
        (guide / name).write_text(
            guide_page(title, body, relative_source), encoding="utf-8"
        )
    (output / ".nojekyll").touch()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--api", type=Path, default=Path("htmldocs"))
    parser.add_argument("--voice-api", type=Path, default=Path("voice/htmldocs"))
    parser.add_argument("--output", type=Path, default=Path("build/pages"))
    args = parser.parse_args()
    resolve = lambda value: value if value.is_absolute() else PROJECT_ROOT / value
    try:
        build(resolve(args.api), resolve(args.voice_api), resolve(args.output))
    except (OSError, ValueError) as error:
        print(error)
        return 1
    print(f"built human guides and API reference under {resolve(args.output)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
