#!/usr/bin/env python3
"""Stage generated Core and Voice Nimdoc for GitHub Pages."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SAFE_OUTPUT = (PROJECT_ROOT / "build" / "pages").resolve()


def build(core: Path, voice: Path, output: Path) -> None:
    if output.resolve() != SAFE_OUTPUT:
        raise ValueError(f"refusing unexpected Pages output: {output}")
    for name, source in (("Core", core), ("Voice", voice)):
        index = source / "theindex.html"
        if not index.is_file() or index.stat().st_size == 0:
            raise ValueError(f"missing generated {name} Nimdoc index: {index}")

    shutil.rmtree(output, ignore_errors=True)
    shutil.copytree(core, output)
    shutil.copy2(output / "theindex.html", output / "index.html")

    voice_output = output / "voice"
    shutil.copytree(voice, voice_output)
    shutil.copy2(voice_output / "theindex.html", voice_output / "index.html")
    (output / ".nojekyll").touch()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", type=Path, default=Path("htmldocs"))
    parser.add_argument("--voice", type=Path, default=Path("voice/htmldocs"))
    parser.add_argument("--output", type=Path, default=Path("build/pages"))
    args = parser.parse_args()

    resolve = lambda value: value if value.is_absolute() else PROJECT_ROOT / value
    try:
        build(resolve(args.core), resolve(args.voice), resolve(args.output))
    except (OSError, ValueError) as error:
        print(error)
        return 1
    print(f"staged generated Nimdoc under {resolve(args.output)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
