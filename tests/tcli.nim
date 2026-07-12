import std/[json, os, strutils, unittest]

import cordnim/cli {.all.} # {.all.} exposes private parseSyncOptions/makeRawRequest
import cordnim/raw/request as raw_request

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

  test "treats empty context-menu descriptions as omitted during diff":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let currentPath = directory / "current-ctx.json"
    let desiredPath = directory / "desired-ctx.json"
    # A Discord-fetched USER command echoes an empty description and default
    # fields our manifests never set.
    writeFile(currentPath, $(%*{
      "commands": [{
        "id": "1", "application_id": "2", "version": "3",
        "name": "Inspect User", "type": 2, "description": "",
        "nsfw": false, "dm_permission": newJNull(),
        "default_member_permissions": newJNull(),
        "name_localizations": newJNull(),
        "integration_types": [0], "contexts": [0]
      }]
    }))
    writeFile(desiredPath, $(%*{
      "commands": [{
        "name": "Inspect User", "type": 2,
        "integration_types": [0], "contexts": [0],
        "cordnim": {"ack": "ackManual"}
      }]
    }))
    check runCli(@[
      "commands", "diff", "--current", currentPath, "--desired", desiredPath
    ]) == 0

  test "ignores Discord's default true dm_permission during diff":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let currentPath = directory / "current-default-dm.json"
    let desiredPath = directory / "desired-default-dm.json"
    writeFile(currentPath, $(%*{
      "commands": [{
        "id": "1", "application_id": "2", "version": "3",
        "name": "ping", "type": 1, "description": "Ping",
        "dm_permission": true, "nsfw": false,
        "default_member_permissions": newJNull()
      }]
    }))
    writeFile(desiredPath, $(%*{
      "commands": [{
        "name": "ping", "type": 1, "description": "Ping"
      }]
    }))
    check runCli(@[
      "commands", "diff", "--current", currentPath, "--desired", desiredPath
    ]) == 0

  test "accepts the same command name across different kinds":
    let path = getTempDir() / "cordnim-cli-crosskind.json"
    writeFile(path, $(%*{
      "commands": [
        {"name": "inspect", "type": 1, "description": "Inspect a resource"},
        {"name": "inspect", "type": 2}
      ]
    }))
    check runCli(@["manifest", "validate", path]) == 0

  test "rejects manifests with unknown localization locales":
    let path = getTempDir() / "cordnim-cli-badlocale.json"
    writeFile(path, $(%*{
      "commands": [{
        "name": "ping", "type": 1, "description": "Ping",
        "name_localizations": {"xx": "nope"}
      }]
    }))
    check runCli(@["manifest", "validate", path]) == 1

  test "guild sync ignores global-only integration_types and contexts":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let desiredPath = directory / "desired-scope.json"
    let guildCurrentPath = directory / "current-guild.json"
    # The manifest is global-shaped; a guild command response omits the
    # global-only fields.
    writeFile(desiredPath, $(%*{
      "commands": [{
        "name": "ping", "type": 1, "description": "Ping",
        "integration_types": [0], "contexts": [0],
        "cordnim": {"ack": "ackManual"}
      }]
    }))
    writeFile(guildCurrentPath, $(%*{
      "commands": [{"name": "ping", "type": 1, "description": "Ping"}]
    }))
    # With --guild, integration_types/contexts are out of scope: no changes.
    check runCli(@[
      "commands", "sync", "--manifest", desiredPath,
      "--current", guildCurrentPath, "--guild", "123456789012345678"
    ]) == 0
    # Global scope still compares them, so the same inputs differ.
    check runCli(@[
      "commands", "sync", "--manifest", desiredPath,
      "--current", guildCurrentPath
    ]) == 2
    # The standalone global diff also keeps comparing them unchanged.
    check runCli(@[
      "commands", "diff", "--current", guildCurrentPath,
      "--desired", desiredPath
    ]) == 2

  test "list reads request full localization dictionaries; writes do not":
    let desired = %*{"commands": [
      {"name": "deploy", "type": 1, "description": "Deploy",
       "integration_types": [0], "contexts": [0]}
    ]}
    let globalOptions = parseSyncOptions(
      @["--manifest", "m.json", "--application", "123456789012345678"])
    check "with_localizations=true" in
      makeRawRequest(globalOptions, false, desired).renderedPath()
    check "with_localizations" notin
      makeRawRequest(globalOptions, true, desired).renderedPath()

    let guildOptions = parseSyncOptions(@[
      "--manifest", "m.json", "--application", "123456789012345678",
      "--guild", "234567890123456789"
    ])
    check "with_localizations=true" in
      makeRawRequest(guildOptions, false, desired).renderedPath()
    check "with_localizations" notin
      makeRawRequest(guildOptions, true, desired).renderedPath()

  test "localized commands diff cleanly against full localization data":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let currentPath = directory / "loc-current.json"
    let desiredPath = directory / "loc-desired.json"
    # A current fetched with with_localizations=true carries the full dicts.
    writeFile(currentPath, $(%*{
      "commands": [{
        "id": "1", "application_id": "2", "version": "3",
        "name": "deploy", "type": 1, "description": "Deploy",
        "name_localizations": {"ja": "配備"},
        "description_localizations": {"ja": "配備します"},
        "integration_types": [0], "contexts": [0]
      }]
    }))
    writeFile(desiredPath, $(%*{
      "commands": [{
        "name": "deploy", "type": 1, "description": "Deploy",
        "name_localizations": {"ja": "配備"},
        "description_localizations": {"ja": "配備します"},
        "integration_types": [0], "contexts": [0],
        "cordnim": {"ack": "ackManual"}
      }]
    }))
    check runCli(@[
      "commands", "diff", "--current", currentPath, "--desired", desiredPath
    ]) == 0
    # A changed localized value is still detected.
    writeFile(desiredPath, $(%*{
      "commands": [{
        "name": "deploy", "type": 1, "description": "Deploy",
        "name_localizations": {"ja": "配置"},
        "description_localizations": {"ja": "配備します"},
        "integration_types": [0], "contexts": [0]
      }]
    }))
    check runCli(@[
      "commands", "diff", "--current", currentPath, "--desired", desiredPath
    ]) == 2

  test "manifest validate uses the full schema validator before sync":
    let path = getTempDir() / "cordnim-cli-deep.json"
    # Invalid chat-input name.
    writeFile(path, $(%*{"commands": [
      {"name": "Bad Name", "type": 1, "description": "x"}]}))
    check runCli(@["manifest", "validate", path]) == 1
    # Empty chat-input description.
    writeFile(path, $(%*{"commands": [
      {"name": "ok", "type": 1, "description": ""}]}))
    check runCli(@["manifest", "validate", path]) == 1
    # Autocomplete combined with choices on an option.
    writeFile(path, $(%*{"commands": [
      {"name": "ok", "type": 1, "description": "d", "options": [
        {"type": 3, "name": "q", "description": "d", "autocomplete": true,
         "choices": [{"name": "a", "value": "a"}]}]}]}))
    check runCli(@["manifest", "validate", path]) == 1
    # A well-formed manifest still validates.
    writeFile(path, $(%*{"commands": [
      {"name": "ok", "type": 1, "description": "Fine"}]}))
    check runCli(@["manifest", "validate", path]) == 0
    # Invalid manifests fail sync before any Discord access.
    writeFile(path, $(%*{"commands": [
      {"name": "Bad Name", "type": 1, "description": "x"}]}))
    check runCli(@[
      "commands", "sync", "--manifest", path, "--current", path]) == 1

  test "diff treats integration_types/contexts/channel_types as sets":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let currentPath = directory / "set-current.json"
    let desiredPath = directory / "set-desired.json"
    writeFile(currentPath, $(%*{"commands": [{
      "name": "c", "type": 1, "description": "d",
      "integration_types": [1, 0], "contexts": [2, 0, 1],
      "options": [{"type": 7, "name": "ch", "description": "d",
        "channel_types": [2, 0]}]}]}))
    writeFile(desiredPath, $(%*{"commands": [{
      "name": "c", "type": 1, "description": "d",
      "integration_types": [0, 1], "contexts": [0, 1, 2],
      "options": [{"type": 7, "name": "ch", "description": "d",
        "channel_types": [0, 2]}]}]}))
    check runCli(@[
      "commands", "diff", "--current", currentPath, "--desired", desiredPath
    ]) == 0

  test "manifest hash ignores object key order but not array order":
    let a = %*{"name": "c", "type": 1, "description": "d",
      "options": [{"a": 1, "b": 2}]}
    let b = %*{"type": 1, "options": [{"b": 2, "a": 1}],
      "description": "d", "name": "c"}
    check manifestHash(a) == manifestHash(b)
    check manifestHash(%*{"x": [1, 2, 3]}) != manifestHash(%*{"x": [3, 2, 1]})

  test "malformed current or desired manifests fail without a defect":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let good = directory / "shape-good.json"
    let bad = directory / "shape-bad.json"
    writeFile(good, $(%*{"commands": [
      {"name": "ping", "type": 1, "description": "Ping"}]}))
    let malformed = @[
      %*{"commands": [5]},                              # non-object command
      %*{"commands": [{"name": 5, "type": 1}]},          # name wrong type
      %*{"commands": [{"name": "x", "type": "1"}]}       # type wrong type
    ]
    for payload in malformed:
      writeFile(bad, $payload)
      check runCli(@[
        "commands", "diff", "--current", bad, "--desired", good]) == 1
      check runCli(@[
        "commands", "diff", "--current", good, "--desired", bad]) == 1
    writeFile(bad, $(%*{"commands": [5]}))
    check runCli(@[
      "commands", "sync", "--manifest", good, "--current", bad]) == 1

  test "manifest validate rejects present-but-wrong-typed fields":
    let path = getTempDir() / "cordnim-cli-wrongtype.json"
    let bodies = @[
      %*{"commands": [{"name": "ok", "type": 1, "description": "d",
        "options": {}}]},                                    # options object
      %*{"commands": [{"name": "ok", "type": 1, "description": "d",
        "options": [{"type": 3, "name": "o", "description": "d",
          "required": "x"}]}]},                              # required string
      %*{"commands": [{"name": "ok", "type": 1, "description": "d",
        "options": [{"type": 3, "name": "o", "description": "d",
          "choices": {}}]}]},                                # choices object
      %*{"commands": [{"name": "ok", "type": 1, "description": "d",
        "name_localizations": []}]},                         # localizations arr
      %*{"commands": [{"name": "ok", "type": 1, "description": "d",
        "integration_types": {}}]}                           # installs object
    ]
    for body in bodies:
      writeFile(path, $body)
      check runCli(@["manifest", "validate", path]) == 1

  test "omitted install/context default; explicit empty arrays fail":
    let path = getTempDir() / "cordnim-cli-sets.json"
    writeFile(path, $(%*{"commands": [
      {"name": "ok", "type": 1, "description": "d"}]}))
    check runCli(@["manifest", "validate", path]) == 0
    writeFile(path, $(%*{"commands": [
      {"name": "ok", "type": 1, "description": "d",
       "integration_types": []}]}))
    check runCli(@["manifest", "validate", path]) == 1
    writeFile(path, $(%*{"commands": [
      {"name": "ok", "type": 1, "description": "d", "contexts": []}]}))
    check runCli(@["manifest", "validate", path]) == 1

  test "number option accepts an integral choice value; integer stays strict":
    let path = getTempDir() / "cordnim-cli-numchoice.json"
    writeFile(path, $(%*{"commands": [{"name": "ok", "type": 1,
      "description": "d", "options": [{"type": 10, "name": "ratio",
        "description": "d", "choices": [{"name": "one", "value": 1}]}]}]}))
    check runCli(@["manifest", "validate", path]) == 0
    writeFile(path, $(%*{"commands": [{"name": "ok", "type": 1,
      "description": "d", "options": [{"type": 4, "name": "count",
        "description": "d", "choices": [{"name": "one", "value": 1.5}]}]}]}))
    check runCli(@["manifest", "validate", path]) == 1

  test "diff equates NUMBER 1 and 1.0 while detecting real changes":
    let directory = getTempDir() / "cordnim-cli-tests"
    createDir(directory)
    let currentPath = directory / "num-current.json"
    let desiredPath = directory / "num-desired.json"
    writeFile(currentPath, $(%*{"commands": [{"name": "c", "type": 1,
      "description": "d", "options": [{"type": 10, "name": "r",
        "description": "d", "min_value": 1, "max_value": 9,
        "choices": [{"name": "o", "value": 2}]}]}]}))
    writeFile(desiredPath, $(%*{"commands": [{"name": "c", "type": 1,
      "description": "d", "options": [{"type": 10, "name": "r",
        "description": "d", "min_value": 1.0, "max_value": 9.0,
        "choices": [{"name": "o", "value": 2.0}]}]}]}))
    check runCli(@[
      "commands", "diff", "--current", currentPath, "--desired", desiredPath
    ]) == 0
    writeFile(desiredPath, $(%*{"commands": [{"name": "c", "type": 1,
      "description": "d", "options": [{"type": 10, "name": "r",
        "description": "d", "min_value": 2.0, "max_value": 9.0,
        "choices": [{"name": "o", "value": 2.0}]}]}]}))
    check runCli(@[
      "commands", "diff", "--current", currentPath, "--desired", desiredPath
    ]) == 2

  test "context-menu commands reject forbidden fields, before network":
    let path = getTempDir() / "cordnim-cli-ctxforbidden.json"
    let bodies = @[
      %*{"commands": [{"name": "Ctx", "type": 2, "description": "nope"}]},
      %*{"commands": [{"name": "Ctx", "type": 2,
        "description_localizations": {"ja": "x"}}]},
      %*{"commands": [{"name": "Ctx", "type": 2, "options": []}]}
    ]
    for body in bodies:
      writeFile(path, $body)
      check runCli(@["manifest", "validate", path]) == 1
      # sync validates desired before any Discord access.
      check runCli(@[
        "commands", "sync", "--manifest", path, "--current", path]) == 1

  test "options reject fields illegal for their kind":
    let path = getTempDir() / "cordnim-cli-illegalfield.json"
    # A subcommand carrying a scalar-only field.
    writeFile(path, $(%*{"commands": [{"name": "c", "type": 1,
      "description": "d", "options": [{"type": 1, "name": "s",
        "description": "d", "required": true}]}]}))
    check runCli(@["manifest", "validate", path]) == 1
    # A scalar option carrying nested options.
    writeFile(path, $(%*{"commands": [{"name": "c", "type": 1,
      "description": "d", "options": [{"type": 3, "name": "o",
        "description": "d", "options": []}]}]}))
    check runCli(@["manifest", "validate", path]) == 1
