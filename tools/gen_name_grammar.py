#!/usr/bin/env python3
"""Generate or verify src/cordnim/commands/name_grammar.nim.

Deterministic generator/checker for the Discord chat-input allowed-name code
point table. It uses ONLY the Unicode Character Database bundled with the
running Python interpreter and never fetches data at build time.

Data sources:
  * General_Category (L, N) and case mappings: Python ``unicodedata``, pinned
    to Unicode ``REQUIRED_UNICODE``.
  * Script=Devanagari and Script=Thai code point ranges: taken verbatim from
    the Unicode Scripts.txt for the same version
    (https://www.unicode.org/Public/15.1.0/ucd/Scripts.txt). These are Script
    *property* ranges, not Unicode blocks, so Script=Inherited Vedic marks
    U+0951..U+0954 and Script=Common danda U+0964..U+0965 are excluded.

The expected canonical range count and digest are embedded below so that
``--check`` verifies the checked-in module even on a host whose bundled UCD is
not the pinned version. When the host UCD matches, ``--check`` additionally
regenerates the module and byte-compares it.

Usage:
  python3 tools/gen_name_grammar.py           # (re)write the module (UCD-pinned)
  python3 tools/gen_name_grammar.py --check    # verify; exits non-zero on drift
"""

import hashlib
import os
import re
import sys
import unicodedata

REQUIRED_UNICODE = "15.1.0"
# Canonical fingerprint of the Unicode 15.1.0 output; update deliberately when
# the pinned Unicode version changes (write mode re-checks these).
EXPECTED_RANGE_COUNT = 1273
EXPECTED_DIGEST = \
    "5b2ecfe4dd2e1633d7e5a85a6557de1c0d59df152ce4aa41bfa051bacd6add71"

# Source of the Script property ranges below (recorded, not fetched):
#   https://www.unicode.org/Public/15.1.0/ucd/Scripts.txt
#   SHA-256: 0eacb65169ae6eb1d399cd70826b3da15fff19f6f586eecf819b70c83b1d9b32
SCRIPTS_TXT_URL = "https://www.unicode.org/Public/15.1.0/ucd/Scripts.txt"
SCRIPTS_TXT_SHA256 = \
    "0eacb65169ae6eb1d399cd70826b3da15fff19f6f586eecf819b70c83b1d9b32"

# Exact Script=Devanagari ranges (Scripts.txt 15.1.0). U+0951..U+0954 are
# Script=Inherited and U+0964..U+0965 are Script=Common, so both spans are
# split out here deliberately.
DEVANAGARI = [
    (0x0900, 0x0950), (0x0955, 0x0963), (0x0966, 0x097F),
    (0xA8E0, 0xA8FF), (0x11B00, 0x11B09),
]
# Exact Script=Thai ranges (Scripts.txt 15.1.0).
THAI = [(0x0E01, 0x0E3A), (0x0E40, 0x0E5B)]

MODULE_PATH = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "src", "cordnim",
                 "commands", "name_grammar.nim"))

RANGE_RE = re.compile(r"\(0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+)\)")


def effective_ucd():
    # NAME_GRAMMAR_FAKE_UCD lets tests exercise the mismatched-UCD --check path
    # deterministically without a second interpreter. It never affects writes.
    return os.environ.get("NAME_GRAMMAR_FAKE_UCD", unicodedata.unidata_version)


def in_ranges(code, ranges):
    return any(low <= code <= high for low, high in ranges)


def allowed_ranges():
    """Return the sorted inclusive (low, high) ranges from the bundled UCD."""
    allowed = set()
    for code in range(0x110000):
        char = chr(code)
        category = unicodedata.category(char)
        if category == "Cn":
            continue  # unassigned
        is_letter_or_number = category[0] in ("L", "N")
        is_script = in_ranges(code, DEVANAGARI) or in_ranges(code, THAI)
        if not (is_letter_or_number or is_script):
            continue
        if char.lower() != char:
            continue  # keep only lowercase or caseless code points
        allowed.add(code)
    allowed.update((0x2D, 0x5F, 0x27))  # ASCII hyphen, underscore, apostrophe
    codes = sorted(allowed)
    ranges = []
    start = prev = codes[0]
    for code in codes[1:]:
        if code == prev + 1:
            prev = code
        else:
            ranges.append((start, prev))
            start = prev = code
    ranges.append((start, prev))
    return ranges


def digest(ranges):
    canonical = ";".join(f"{low:X}-{high:X}" for low, high in ranges)
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def render(ranges):
    items = [f"(0x{low:04X}, 0x{high:04X})" for low, high in ranges]
    rows = ["  " + ", ".join(items[i:i + 3]) for i in range(0, len(items), 3)]
    header = f"""\
## Generated allowed code point ranges for Discord chat-input command and
## option names. Do not edit by hand.
##
## Regenerate or verify with the deterministic generator:
##   python3 tools/gen_name_grammar.py           # rewrite this file
##   python3 tools/gen_name_grammar.py --check    # fail if this file is stale
##
## Built offline from the bundled Unicode Character Database (no data is
## fetched at build time):
##   - General_Category L and N, and case mappings, from Python unicodedata
##     pinned to Unicode {REQUIRED_UNICODE}.
##   - Script=Devanagari and Script=Thai ranges from Unicode {REQUIRED_UNICODE}
##     Scripts.txt (Script property ranges, not Unicode blocks). Source digest
##     SHA-256:
##     {SCRIPTS_TXT_SHA256}
##     so the Script=Inherited Vedic marks U+0951..U+0954 and Script=Common
##     danda U+0964..U+0965 are excluded.
##
## Only assigned code points that are already lowercase or caseless are kept,
## plus the ASCII hyphen, underscore, and apostrophe. Each pair is an inclusive
## `(low, high)` range, sorted ascending.
##
## Unicode version: {REQUIRED_UNICODE}
## Ranges: {len(ranges)}
## Digest (sha256 of ranges):
##   {digest(ranges)}

const chatInputNameRanges* = [
"""
    return header + ",\n".join(rows) + "\n]\n"


def parse_ranges(text):
    return [(int(a, 16), int(b, 16)) for a, b in RANGE_RE.findall(text)]


def header_value(text, pattern):
    match = re.search(pattern, text)
    return match.group(1) if match else None


def static_problems(text):
    """Version-independent checks of the checked-in module."""
    problems = []
    ranges = parse_ranges(text)
    if not ranges:
        return ["no code point ranges found"]
    previous_high = None
    for low, high in ranges:
        if low > high:
            problems.append(f"inverted range 0x{low:X}-0x{high:X}")
        if previous_high is not None and low <= previous_high + 1:
            problems.append(
                f"range 0x{low:X}-0x{high:X} is not ascending/merged after "
                f"0x{previous_high:X}")
        previous_high = high
    if len(ranges) != EXPECTED_RANGE_COUNT:
        problems.append(
            f"range count {len(ranges)} != expected {EXPECTED_RANGE_COUNT}")
    actual_digest = digest(ranges)
    if actual_digest != EXPECTED_DIGEST:
        problems.append(
            f"range digest {actual_digest} != expected {EXPECTED_DIGEST}")
    version = header_value(text, r"## Unicode version: (\S+)")
    if version != REQUIRED_UNICODE:
        problems.append(f"header Unicode version {version!r} != "
                        f"{REQUIRED_UNICODE!r}")
    header_count = header_value(text, r"## Ranges: (\d+)")
    if header_count != str(EXPECTED_RANGE_COUNT):
        problems.append(f"header range count {header_count!r} != "
                        f"{EXPECTED_RANGE_COUNT}")
    header_digest = header_value(
        text, r"## Digest \(sha256 of ranges\):\s*\r?\n##\s+([0-9a-f]{64})")
    if header_digest != EXPECTED_DIGEST:
        problems.append("header digest does not match expected digest")
    return problems


def run_check():
    try:
        text = open(MODULE_PATH, encoding="utf-8").read()
    except FileNotFoundError:
        sys.exit(f"error: {MODULE_PATH} is missing; run without --check")
    problems = static_problems(text)
    if problems:
        sys.exit("error: name_grammar.nim drift detected:\n  - "
                 + "\n  - ".join(problems))
    ucd = effective_ucd()
    if ucd == REQUIRED_UNICODE:
        if text != render(allowed_ranges()):
            sys.exit("error: name_grammar.nim differs from a fresh Unicode "
                     f"{REQUIRED_UNICODE} regeneration; run without --check")
        print(f"name_grammar.nim verified against a fresh Unicode "
              f"{REQUIRED_UNICODE} regeneration")
    else:
        print("name_grammar.nim verified against embedded range count, digest, "
              "ordering, and header; full regeneration not run (interpreter "
              f"UCD is {ucd}, pinned {REQUIRED_UNICODE})")


def run_write():
    ucd = effective_ucd()
    if ucd != REQUIRED_UNICODE:
        sys.exit(f"error: regeneration requires Unicode {REQUIRED_UNICODE}, "
                 f"interpreter bundles {ucd}")
    ranges = allowed_ranges()
    if len(ranges) != EXPECTED_RANGE_COUNT or digest(ranges) != EXPECTED_DIGEST:
        sys.exit("error: embedded EXPECTED_RANGE_COUNT/EXPECTED_DIGEST are "
                 "stale versus Unicode 15.1 output; update them deliberately")
    with open(MODULE_PATH, "w", encoding="utf-8") as handle:
        handle.write(render(ranges))
    print(f"wrote {MODULE_PATH} ({len(ranges)} ranges, Unicode "
          f"{REQUIRED_UNICODE})")


def main():
    if "--check" in sys.argv[1:]:
        run_check()
    else:
        run_write()


if __name__ == "__main__":
    main()
