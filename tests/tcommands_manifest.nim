## Deterministic command manifest tests.

import std/[json, unittest]

import cordnim/commands
import cordnim/core/ids

type ManifestServices = object

proc ping(ctx: CommandCtx[ManifestServices]): CommandResult
    {.discordCommand(name = "ping", description = "Check responsiveness").} =
  succeeded($ctx.invocation.userId)

proc inspectUser(ctx: CommandCtx[ManifestServices]): CommandResult
    {.discordCommand(
      name = "inspect_user",
      description = "Inspect the selected user",
      kind = ckUser
    ).} =
  succeeded()

let registry = commandSet(ping)

suite "command manifest":
  test "serializes and hashes deterministically":
    let first = initCommandManifest(registry, "2026-07-07")
    let second = initCommandManifest(registry, "2026-07-07")
    check first.canonicalJson == second.canonicalJson
    check first.manifestHash == second.manifestHash
    check first.manifestHash.len == 16
    let parsed = parseJson(first.canonicalJson)
    check parsed["schema_revision"].getStr == "2026-07-07"
    check parsed["commands"][0]["name"].getStr == "ping"

  test "reports added removed and changed commands":
    let current = initCommandManifest(registry, "2026-07-07")
    var desired = current
    desired.commands[0].description = "Check whether the app responds"
    var changes = diff(current, desired)
    check changes.len == 1
    check changes[0].kind == mckChanged
    check changes[0].commandName == "ping"

    desired.commands.add CommandSpec(
      name: "version",
      description: "Show the version",
      kind: ckChatInput,
      installs: {guildInstall},
      contexts: {guildChannel},
      ack: ackManual
    )
    changes = diff(current, desired)
    check changes.len == 2
    check changes[0].kind == mckChanged
    check changes[1].kind == mckAdded

  test "omits chat-input-only fields from context menu commands":
    let manifest = initCommandManifest(commandSet(inspectUser), "2026-07-11")
    let command = manifest.toJson()["commands"][0]
    check command["type"].getInt() == 2
    check not command.hasKey("description")
    check not command.hasKey("options")
