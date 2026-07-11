## Aggregate test entry point used by Nimble and CI.

import std/[algorithm, os, strutils]

const testDir = currentSourcePath().parentDir()
const projectDir = testDir.parentDir()

proc isLeafTest(path: string): bool =
  let name = path.extractFilename()
  name.startsWith("t") and name.endsWith(".nim") and name != "test_all.nim"

when isMainModule:
  var failures = 0
  var paths: seq[string]
  for path in walkFiles(testDir / "t*.nim"):
    if path.isLeafTest:
      paths.add path
  paths.sort()
  let cacheRoot = getTempDir() / "cordnim-test-nimcache"
  let binaryRoot = getTempDir() / "cordnim-test-bin"
  createDir(cacheRoot)
  createDir(binaryRoot)
  for path in paths:
    let name = path.splitFile.name
    let command = "nim c -r --mm:orc" &
      " --path:" & quoteShell(projectDir / "src") &
      " --path:" & quoteShell(projectDir / "voice" / "src") &
      " --nimcache:" & quoteShell(cacheRoot / name) &
      " --out:" & quoteShell(binaryRoot / name) &
      " " & quoteShell(path)
    if execShellCmd(command) != 0:
      inc failures
  if failures != 0:
    quit($failures & " test file(s) failed", QuitFailure)
