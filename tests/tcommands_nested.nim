## Nested chat-input subcommand schema, validation, and routing tests.

import std/[json, options, unittest]
import chronos

import cordnim/commands
import cordnim/app/context as appcontext

type NestedServices = object

let configSpec = initChatInputCommand("config", "Configure the bot",
  options = @[
    subCommand("set", "Set a value", @[
      initCommandOption(cokString, "key", "Key", required = true),
      initCommandOption(cokString, "value", "Value", required = true)
    ]),
    subCommand("show", "Show configuration"),
    subCommandGroup("role", "Role configuration", @[
      subCommand("add", "Add a role", @[
        initCommandOption(cokString, "name", "Role name", required = true)
      ])
    ])
  ])

suite "nested subcommand schema":
  test "rejects mixing scalar options with subcommands":
    expect CommandSpecError:
      discard initChatInputCommand("bad", "Bad", options = @[
        subCommand("a", "A"),
        initCommandOption(cokString, "s", "Scalar")
      ])

  test "subcommand groups may contain only subcommands":
    expect CommandSpecError:
      discard subCommandGroup("g", "Group", @[
        initCommandOption(cokString, "s", "Scalar")
      ])

  test "rejects nesting deeper than one group level":
    expect CommandSpecError:
      discard subCommandGroup("g", "Group", @[
        subCommandGroup("inner", "Inner", @[subCommand("x", "X")])
      ])
    expect CommandSpecError:
      discard subCommand("s", "Sub", @[subCommand("inner", "Inner")])

  test "rejects an empty subcommand group":
    expect CommandSpecError:
      discard subCommandGroup("g", "Group", @[])

  test "serializes nested options with structural types":
    let options = CommandManifest(
      schemaRevision: "r", commands: @[configSpec]
    ).toJson()["commands"][0]["options"]
    check options[0]["type"].getInt() == 1
    check options[0]["name"].getStr() == "set"
    check not options[0].hasKey("required")
    check options[0]["options"][0]["name"].getStr() == "key"
    check options[0]["options"][0]["required"].getBool()
    check options[2]["type"].getInt() == 2
    check options[2]["name"].getStr() == "role"
    check options[2]["options"][0]["type"].getInt() == 1
    check options[2]["options"][0]["options"][0]["name"].getStr() == "name"

suite "nested subcommand routing":
  test "resolves a top-level subcommand path":
    let invocation = CommandInvocation(kind: ckChatInput, name: "config",
      options: %*{"set": [
        {"name": "key", "type": 3, "value": "color"},
        {"name": "value", "type": 3, "value": "blue"}
      ]})
    let resolved = resolveSubcommand(invocation)
    check resolved.isSome
    check resolved.get().group.isNone
    check resolved.get().name == "set"
    check resolved.get().options["key"].getStr() == "color"
    check resolved.get().options["value"].getStr() == "blue"

  test "resolves a subcommand inside a group":
    let invocation = CommandInvocation(kind: ckChatInput, name: "config",
      options: %*{"role": [
        {"name": "add", "type": 1, "options": [
          {"name": "name", "type": 3, "value": "admin"}
        ]}
      ]})
    let resolved = resolveSubcommand(invocation)
    check resolved.isSome
    check resolved.get().group == some("role")
    check resolved.get().name == "add"
    check resolved.get().options["name"].getStr() == "admin"

  test "returns none for a flat command without subcommands":
    let invocation = CommandInvocation(kind: ckChatInput, name: "ping",
      options: %*{"target": "here"})
    check resolveSubcommand(invocation).isNone

  test "dispatches through an explicit nested handler registry":
    let handler: CommandHandler[NestedServices] = proc(
        services: ref NestedServices,
        context: appcontext.Context,
        invocation: CommandInvocation): Future[CommandResult] {.async.} =
      let path = resolveSubcommand(invocation)
      if path.isNone:
        return notFound(invocation.key)
      case path.get().name
      of "set":
        return succeeded("set:" & path.get().options["key"].getStr())
      of "add":
        return succeeded(
          path.get().group.get() & "/add:" &
            path.get().options["name"].getStr())
      else:
        return rejected("unknown subcommand")

    let commands = initCommandSet(@[configSpec], @[handler])
    check commands.len == 1

    let setResult = waitFor commands.dispatch(NestedServices(),
      CommandInvocation(kind: ckChatInput, name: "config",
        options: %*{"set": [
          {"name": "key", "type": 3, "value": "theme"}
        ]}))
    check setResult.kind == crSucceeded
    check setResult.message == "set:theme"

    let addResult = waitFor commands.dispatch(NestedServices(),
      CommandInvocation(kind: ckChatInput, name: "config",
        options: %*{"role": [
          {"name": "add", "type": 1, "options": [
            {"name": "name", "type": 3, "value": "mod"}
          ]}
        ]}))
    check addResult.message == "role/add:mod"

suite "explicit registration invariants":
  test "initCommandSet rejects duplicate command keys":
    let spec = initChatInputCommand("dup", "Duplicate")
    let handler: CommandHandler[NestedServices] = proc(
        services: ref NestedServices, context: appcontext.Context,
        invocation: CommandInvocation): Future[CommandResult] {.async.} =
      return succeeded()
    expect CommandSpecError:
      discard initCommandSet(@[spec, spec], @[handler, handler])
