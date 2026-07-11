## Command macro schema and typed dispatch tests.

import std/[json, options, strutils, unittest]
import chronos

import cordnim/commands
import cordnim/core/[bits, ids, permissions]

type
  Environment = enum
    staging
    production

  TestServices = object
    prefix: string

proc deploy(ctx: CommandCtx[TestServices], environment: Environment,
            replicas: range[1 .. 20], dryRun = false,
            note: Option[string] = none(string)): CommandResult
    {.discordCommand(
      name = "deploy",
      description = "Deploy an application",
      installs = {guildInstall, userInstall},
      contexts = {guildChannel, privateChannel},
      ack = ackAutoDefer,
      autoDeferAfterMs = 1_500,
      ephemeral = true,
      requiredBotPermissions = {
        Permission.sendMessages, Permission.attachFiles
      }
    ).} =
  let suffix = if note.isSome: ":" & note.get() else: ""
  succeeded(ctx.services.prefix & $environment & ":" & $replicas &
    ":" & $dryRun & suffix)

proc about(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(
      name = "about",
      description = "Show application information",
      contexts = {botDm, guildChannel}
    ).} =
  succeeded(ctx.services.prefix & $ctx.invocation.userId)

proc asyncStatus(ctx: CommandCtx[TestServices], value: string):
    Future[CommandResult]
    {.async, discordCommand(
      name = "async_status",
      description = "Exercise an asynchronous command"
    ).} =
  await sleepAsync(0.milliseconds)
  return succeeded(ctx.services.prefix & value)

proc localized(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(
      name = "配備",
      description = "アプリケーションを配備します"
    ).} =
  succeeded(ctx.services.prefix)

let commandsUnderTest = commandSet(deploy, about)

suite "command compiler":
  test "accepts Discord-supported uncased Unicode command metadata":
    let localizedCommands = commandSet(localized)
    check localizedCommands.specs[0].name == "配備"
    check localizedCommands.specs[0].description == "アプリケーションを配備します"

  test "sorts explicit registrations and generates option schema":
    check commandsUnderTest.len == 2
    check commandsUnderTest.specs[0].name == "about"
    check commandsUnderTest.specs[1].name == "deploy"

    let deploySpec = commandsUnderTest.specs[1]
    check deploySpec.installs == {guildInstall, userInstall}
    check deploySpec.contexts == {guildChannel, privateChannel}
    check deploySpec.ack == ackAutoDefer
    check deploySpec.autoDeferAfterMs == 1_500
    check deploySpec.requiredBotPermissions.contains(Permission.sendMessages)
    check deploySpec.requiredBotPermissions.contains(Permission.attachFiles)
    check deploySpec.options.len == 4
    check deploySpec.options[0].kind == cokString
    check deploySpec.options[0].choices.len == 2
    check deploySpec.options[1].kind == cokInteger
    check deploySpec.options[1].minimumInt == some(1'i64)
    check deploySpec.options[1].maximumInt == some(20'i64)
    check not deploySpec.options[2].required
    check deploySpec.options[2].name == "dry_run"
    check not deploySpec.options[3].required

  test "decodes typed values and applies defaults":
    let invocation = CommandInvocation(
      name: "deploy",
      options: %*{
        "environment": "staging",
        "replicas": 3
      },
      userId: toId(UserId, 42),
      guildId: some(toId(GuildId, 7))
    )
    let result = waitFor commandsUnderTest.dispatch(
      TestServices(prefix: "run:"), invocation)
    check result.kind == crSucceeded
    check result.message == "run:staging:3:false"

  test "reports a missing or out-of-range option without invoking handler":
    let missing = waitFor commandsUnderTest.dispatch(TestServices(), CommandInvocation(
      name: "deploy",
      options: %*{"environment": "production"},
      userId: toId(UserId, 42)
    ))
    check missing.kind == crInvalidOptions
    check "replicas" in missing.message

    let outside = waitFor commandsUnderTest.dispatch(TestServices(), CommandInvocation(
      name: "deploy",
      options: %*{"environment": "production", "replicas": 21},
      userId: toId(UserId, 42)
    ))
    check outside.kind == crInvalidOptions
    check "outside" in outside.message

  test "returns an explicit not-found result":
    let result = waitFor commandsUnderTest.dispatch(TestServices(), CommandInvocation(
      name: "missing",
      options: newJObject(),
      userId: toId(UserId, 42)
    ))
    check result.kind == crNotFound

  test "awaits a native Chronos command handler":
    let asyncCommands = commandSet(asyncStatus)
    let result = waitFor asyncCommands.dispatch(
      TestServices(prefix: "async:"),
      CommandInvocation(
        name: "async_status",
        options: %*{"value": "ready"},
        userId: toId(UserId, 42)
      )
    )
    check result.message == "async:ready"
