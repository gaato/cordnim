## Invariant and drift checks for the generated chat-input name table.

import std/[os, osproc, unittest]

import cordnim/commands/name_grammar

suite "name grammar table":
  test "ranges are sorted, non-empty, and non-adjacent":
    check chatInputNameRanges.len > 0
    var previousHigh = -1
    for (low, high) in chatInputNameRanges:
      check low <= high
      # Ascending with a real gap between ranges (adjacent ones are merged).
      check low > previousHigh + 1
      previousHigh = high

  test "generator --check verifies the table (version-independent)":
    let tool = currentSourcePath().parentDir().parentDir() /
      "tools" / "gen_name_grammar.py"
    let python = findExe("python3")
    if python.len == 0:
      skip() # only a missing interpreter is a valid reason to skip
    else:
      # --check is version-independent: it verifies count/digest/ordering/header
      # against embedded expected values regardless of the host's bundled UCD,
      # so this never skips merely for a Unicode version mismatch.
      let (output, code) = execCmdEx(
        quoteShell(python) & " " & quoteShell(tool) & " --check")
      checkpoint(output)
      check code == 0
