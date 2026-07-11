## Deterministic command manifest serialization, hashing, and comparison.

import std/[algorithm, json, options, strutils]

import cordnim/core/bits
import ./spec

type
  ManifestChangeKind* = enum ## Difference between two command manifests.
    mckAdded, ## A command exists only in the desired manifest.
    mckRemoved, ## A command exists only in the current manifest.
    mckChanged ## A command exists in both but its schema changed.

  ManifestChange* = object ## One name-addressed command manifest change.
    kind*: ManifestChangeKind ## Change classification.
    commandName*: string ## Stable Discord command name.

  CommandManifest* = object ## Versioned, transport-independent command
                            ## manifest.
    schemaRevision*: string ## Pinned Discord schema revision used for
                            ## generation.
    commands*: seq[CommandSpec] ## Commands sorted by name.

func discordCommandKind(kind: CommandKind): int =
  case kind
  of ckChatInput: 1
  of ckUser: 2
  of ckMessage: 3

func discordOptionKind(kind: CommandOptionKind): int =
  case kind
  of cokString: 3
  of cokInteger: 4
  of cokBoolean: 5
  of cokUser: 6
  of cokChannel: 7
  of cokRole: 8
  of cokMentionable: 9
  of cokNumber: 10
  of cokAttachment: 11

func initCommandManifest*[S](commands: CommandSet[S],
                             schemaRevision: string): CommandManifest =
  ## Creates a manifest and normalizes command order by name.
  result = CommandManifest(
    schemaRevision: schemaRevision,
    commands: commands.specs
  )
  result.commands.sort(proc (left, right: CommandSpec): int =
    cmp(left.name, right.name))

func choiceJson(choice: CommandChoice): JsonNode =
  result = newJObject()
  result["name"] = %choice.name
  result["value"] = %choice.value

func optionJson(option: CommandOptionSpec): JsonNode =
  result = newJObject()
  result["name"] = %option.name
  result["description"] = %option.description
  result["type"] = %discordOptionKind(option.kind)
  result["required"] = %option.required
  if option.minimumInt.isSome:
    result["min_value"] = %option.minimumInt.get()
  if option.maximumInt.isSome:
    result["max_value"] = %option.maximumInt.get()
  if option.choices.len > 0:
    result["choices"] = newJArray()
    for choice in option.choices:
      result["choices"].add(choiceJson(choice))

func commandJson(command: CommandSpec): JsonNode =
  result = newJObject()
  result["name"] = %command.name
  result["type"] = %discordCommandKind(command.kind)
  if command.kind == ckChatInput:
    result["description"] = %command.description

  result["integration_types"] = newJArray()
  for install in CommandInstallContext:
    if install in command.installs:
      result["integration_types"].add(%ord(install))

  result["contexts"] = newJArray()
  for context in CommandInteractionContext:
    if context in command.contexts:
      result["contexts"].add(%ord(context))

  if command.kind == ckChatInput:
    result["options"] = newJArray()
    for option in command.options:
      result["options"].add(optionJson(option))

  # Runtime-only metadata is namespaced so the same file can drive both the
  # Discord synchronization CLI and the local interaction dispatcher.
  result["cordnim"] = newJObject()
  result["cordnim"]["ack"] = %($command.ack)
  result["cordnim"]["auto_defer_after_ms"] = %command.autoDeferAfterMs
  result["cordnim"]["ephemeral"] = %command.ephemeral
  result["cordnim"]["required_bot_permissions"] =
    %command.requiredBotPermissions.toDecimal()

func toJson*(manifest: CommandManifest): JsonNode =
  ## Converts a manifest to a JSON tree with stable field insertion order.
  result = newJObject()
  result["schema_revision"] = %manifest.schemaRevision
  result["commands"] = newJArray()
  var sortedCommands = manifest.commands
  sortedCommands.sort(proc (left, right: CommandSpec): int =
    cmp(left.name, right.name))
  for command in sortedCommands:
    result["commands"].add(commandJson(command))

func canonicalJson*(manifest: CommandManifest): string =
  ## Serializes a manifest to compact deterministic JSON.
  $manifest.toJson()

func manifestHash*(manifest: CommandManifest): string =
  ## Returns a stable 64-bit FNV-1a content identifier as lowercase hex.
  ##
  ## This hash detects manifest drift; it is not a cryptographic signature.
  var hash = 14695981039346656037'u64
  for byteValue in manifest.canonicalJson():
    hash = hash xor uint64(ord(byteValue))
    hash = hash * 1099511628211'u64
  hash.toHex(16).toLowerAscii()

func diff*(current, desired: CommandManifest): seq[ManifestChange] =
  ## Computes added, removed, and changed commands in deterministic name order.
  var currentCommands = current.commands
  var desiredCommands = desired.commands
  currentCommands.sort(proc (left, right: CommandSpec): int =
    cmp(left.name, right.name))
  desiredCommands.sort(proc (left, right: CommandSpec): int =
    cmp(left.name, right.name))

  var currentIndex = 0
  var desiredIndex = 0
  while currentIndex < currentCommands.len or
      desiredIndex < desiredCommands.len:
    if currentIndex >= currentCommands.len:
      result.add(ManifestChange(kind: mckAdded,
        commandName: desiredCommands[desiredIndex].name))
      inc desiredIndex
    elif desiredIndex >= desiredCommands.len:
      result.add(ManifestChange(kind: mckRemoved,
        commandName: currentCommands[currentIndex].name))
      inc currentIndex
    else:
      let currentCommand = currentCommands[currentIndex]
      let desiredCommand = desiredCommands[desiredIndex]
      if currentCommand.name < desiredCommand.name:
        result.add(ManifestChange(kind: mckRemoved,
          commandName: currentCommand.name))
        inc currentIndex
      elif desiredCommand.name < currentCommand.name:
        result.add(ManifestChange(kind: mckAdded,
          commandName: desiredCommand.name))
        inc desiredIndex
      else:
        if commandJson(currentCommand) != commandJson(desiredCommand):
          result.add(ManifestChange(kind: mckChanged,
            commandName: currentCommand.name))
        inc currentIndex
        inc desiredIndex
