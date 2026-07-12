## Deterministic command manifest tests.

import std/[algorithm, json, unittest]

import cordnim/commands
import cordnim/core/ids

type ManifestServices = object

proc ping(ctx: CommandCtx[ManifestServices]): CommandResult
    {.discordCommand(name = "ping", description = "Check responsiveness").} =
  succeeded($ctx.invocation.userId)

proc inspectUser(ctx: CommandCtx[ManifestServices]): CommandResult
    {.discordCommand(
      name = "Inspect User",
      kind = ckUser
    ).} =
  succeeded()

proc inspectSlash(ctx: CommandCtx[ManifestServices]): CommandResult
    {.discordCommand(name = "inspect", description = "Inspect a resource").} =
  succeeded()

proc inspectUserSameName(ctx: CommandCtx[ManifestServices]): CommandResult
    {.discordCommand(name = "inspect", kind = ckUser).} =
  succeeded()

proc inspectMessage(ctx: CommandCtx[ManifestServices]): CommandResult
    {.discordCommand(name = "inspect", kind = ckMessage).} =
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
    check changes[0].command == initCommandKey(ckChatInput, "ping")

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

  test "orders and hashes commands by kind and name":
    let commands = commandSet(
      inspectMessage, inspectUserSameName, inspectSlash)
    let manifest = initCommandManifest(commands, "2026-07-12")
    let document = manifest.toJson()
    check document["commands"].len == 3
    check document["commands"][0]["type"].getInt() == 1
    check document["commands"][1]["type"].getInt() == 2
    check document["commands"][2]["type"].getInt() == 3
    check document["commands"][0]["name"].getStr() == "inspect"
    check document["commands"][1]["name"].getStr() == "inspect"
    check document["commands"][2]["name"].getStr() == "inspect"
    check not document["commands"][1].hasKey("description")
    check not document["commands"][2].hasKey("description")

    var reversed = manifest
    reversed.commands.reverse()
    check reversed.canonicalJson == manifest.canonicalJson
    check reversed.manifestHash == manifest.manifestHash

suite "command localization manifest":
  test "serializes localized names, descriptions, options, and choices":
    let spec = initChatInputCommand(
      "birthday", "Wish a friend a happy birthday",
      options = @[
        initCommandOption(cokInteger, "age", "Your friend's age",
          nameLocalizations = initLocalizationMap({dlChineseChina: "岁数"}),
          descriptionLocalizations =
            initLocalizationMap({dlChineseChina: "你朋友的岁数"})),
        initCommandOption(cokString, "mood", "Their mood",
          choices = @[
            commandChoice("happy", "happy",
              nameLocalizations = initLocalizationMap({dlJapanese: "嬉しい"}))
          ])
      ],
      nameLocalizations = initLocalizationMap({
        dlChineseChina: "生日", dlGreek: "γενέθλια"
      }),
      descriptionLocalizations =
        initLocalizationMap({dlChineseChina: "祝你朋友生日快乐"}))
    let manifest = CommandManifest(
      schemaRevision: "2026-07-12", commands: @[spec])
    let command = manifest.toJson()["commands"][0]
    check command["name_localizations"] ==
      %*{"el": "γενέθλια", "zh-CN": "生日"}
    check command["description_localizations"] ==
      %*{"zh-CN": "祝你朋友生日快乐"}
    let ageOption = command["options"][0]
    check ageOption["type"].getInt() == 4
    check ageOption["name_localizations"]["zh-CN"].getStr() == "岁数"
    let moodOption = command["options"][1]
    check moodOption["choices"][0]["name_localizations"]["ja"].getStr() ==
      "嬉しい"

  test "hashes localized commands regardless of locale insertion order":
    let a = initChatInputCommand("greet", "Greet",
      nameLocalizations = initLocalizationMap({
        dlJapanese: "挨拶", dlGerman: "grüßen"
      }))
    let b = initChatInputCommand("greet", "Greet",
      nameLocalizations = initLocalizationMap({
        dlGerman: "grüßen", dlJapanese: "挨拶"
      }))
    let manifestA = CommandManifest(schemaRevision: "r", commands: @[a])
    let manifestB = CommandManifest(schemaRevision: "r", commands: @[b])
    check manifestA.canonicalJson == manifestB.canonicalJson
    check manifestA.manifestHash == manifestB.manifestHash

  test "channel option emits sorted channel_types":
    let spec = initChatInputCommand("move", "Move to a channel",
      options = @[
        initCommandOption(cokChannel, "target", "Destination",
          channelTypes = [cctGuildVoice, cctGuildText])
      ])
    let manifest = CommandManifest(schemaRevision: "r", commands: @[spec])
    let option = manifest.toJson()["commands"][0]["options"][0]
    check option["type"].getInt() == 7
    check option["channel_types"] == %*[0, 2]

  test "serializes choice values with their declared JSON type":
    let spec = initChatInputCommand("pick", "Pick values", options = @[
      initCommandOption(cokInteger, "count", "Count",
        choices = @[commandChoice("one", 1'i64), commandChoice("ten", 10'i64)]),
      initCommandOption(cokNumber, "ratio", "Ratio",
        choices = @[commandChoice("half", 0.5)]),
      initCommandOption(cokString, "mood", "Mood",
        choices = @[commandChoice("happy", "happy")])
    ])
    let options = CommandManifest(
      schemaRevision: "r", commands: @[spec]).toJson()["commands"][0]["options"]
    check options[0]["choices"][0]["value"].kind == JInt
    check options[0]["choices"][0]["value"].getInt() == 1
    check options[1]["choices"][0]["value"].kind == JFloat
    check options[1]["choices"][0]["value"].getFloat() == 0.5
    check options[2]["choices"][0]["value"].kind == JString
    check options[2]["choices"][0]["value"].getStr() == "happy"

  test "context-menu commands keep names but omit description locales":
    let spec = initContextMenuCommand(ckUser, "Inspect User",
      nameLocalizations = initLocalizationMap({dlJapanese: "ユーザーを検査"}))
    let command = CommandManifest(
      schemaRevision: "r", commands: @[spec]).toJson()["commands"][0]
    check command["type"].getInt() == 2
    check command.hasKey("name_localizations")
    check not command.hasKey("description")
    check not command.hasKey("description_localizations")
