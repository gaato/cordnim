import std/[json, os, unittest]

import cordnim/cli

suite "cordnim CLI":
  test "reports schema and version without network access":
    check runCli(@["--version"]) == 0
    check runCli(@["schema"]) == 0

  test "validates and diffs local manifests deterministically":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let currentPath = directory / "current.json"
    let desiredPath = directory / "desired.json"
    writeFile(currentPath, $(%*{
      "commands": [{
        "name": "ping", "description": "Ping", "type": 1
      }]
    }))
    writeFile(desiredPath, $(%*{
      "commands": [{
        "name": "ping", "description": "Ping now", "type": 1,
        "cordnim": {"ack": "ackManual"}
      }]
    }))
    check runCli(@["manifest", "validate", desiredPath]) == 0
    check runCli(@[
      "commands", "diff", "--current", currentPath,
      "--desired", desiredPath
    ]) == 2

  test "rejects unsafe sync arguments before touching Discord":
    let path = getTempDir() / "cordnim-cli-empty.json"
    writeFile(path, $(%*{"commands": []}))
    check runCli(@[
      "commands", "sync", "--manifest", path,
      "--current", path, "--apply", "--yes"
    ]) == 1
