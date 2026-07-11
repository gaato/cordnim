## `cordnim` command-line interface for schema inspection and command sync.

import std/[algorithm, json, os, sequtils, sets, strutils, tables]

import chronos

import cordnim/core/secrets
import cordnim/core/ids
import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import cordnim/raw/routes/applications
import cordnim/raw/routes/oauth2
import cordnim/raw/schema_info
import cordnim/rest as runtime_rest

const CliVersion* = "0.1.0" ## Version of the installed `cordnim` executable.

type
  CliError = object of CatchableError

  SyncOptions = object
    manifestPath: string
    currentPath: string
    applicationId: string
    guildId: string
    apply: bool
    yes: bool

proc usage(): string =
  """cordnim - Discord application compiler and operator

Usage:
  cordnim schema
  cordnim doctor [--offline]
  cordnim manifest validate <file>
  cordnim manifest hash <file>
  cordnim commands diff --current <file> --desired <file>
  cordnim commands sync --manifest <file> --application <id> [--guild <id>]
                         [--current <file>] [--dry-run]
                         [--apply --yes]
  cordnim --version

`commands sync` is a dry run unless both --apply and --yes are present. Network
operations read `DISCORD_BOT_TOKEN` (or `DISCORD_TOKEN`) from the environment or
a literal `.env` assignment and never print it. `.env` is parsed, not executed.
"""

proc unquoteEnv(value: string): string =
  result = value.strip()
  if result.len >= 2 and
      ((result[0] == '"' and result[^1] == '"') or
       (result[0] == '\'' and result[^1] == '\'')):
    result = result[1 .. ^2]

proc botTokenText(): string =
  result = getEnv("DISCORD_BOT_TOKEN")
  if result.len == 0:
    result = getEnv("DISCORD_TOKEN")
  if result.len != 0 or not fileExists(".env"):
    return
  try:
    for line in lines(".env"):
      let stripped = line.strip()
      if stripped.len > 0 and stripped[0] != '#':
        let separator = stripped.find('=')
        if separator > 0:
          let key = stripped[0..<separator].strip()
          if key in ["DISCORD_BOT_TOKEN", "DISCORD_TOKEN"]:
            return unquoteEnv(stripped[separator + 1..^1])
  except IOError:
    discard

proc loadJson(path: string): JsonNode =
  if path.len == 0:
    raise newException(CliError, "manifest path is required")
  try:
    parseFile(path)
  except CatchableError as error:
    raise newException(CliError, "cannot read JSON file '" & path & "': " &
      error.msg)

proc commandArray(document: JsonNode): JsonNode =
  if document.kind == JArray:
    return document
  if document.kind == JObject and document.hasKey("commands") and
      document["commands"].kind == JArray:
    return document["commands"]
  raise newException(CliError,
    "command manifest must be an array or an object containing commands")

proc validateManifest(document: JsonNode): seq[string] =
  var names = initHashSet[string]()
  let commands =
    try:
      document.commandArray()
    except CliError as error:
      return @[error.msg]
  for index in 0..<commands.len:
    let command = commands[index]
    if command.kind != JObject:
      result.add $index & ": command must be an object"
    elif not command.hasKey("name") or command["name"].kind != JString:
      result.add $index & ": command name is required"
    else:
      let name = command["name"].getStr()
      if name in names:
        result.add $index & ": duplicate command name '" & name & "'"
      names.incl name
      if not command.hasKey("type") or command["type"].kind != JInt:
        result.add name & ": numeric command type is required"
      if command.getOrDefault("type").getInt(1) == 1 and
          (not command.hasKey("description") or
            command["description"].kind != JString):
        result.add name & ": chat-input description is required"

proc manifestHash(document: JsonNode): string =
  var value = 14695981039346656037'u64
  for character in $document:
    value = (value xor uint64(ord(character))) * 1099511628211'u64
  value.toHex(16).toLowerAscii()

proc normalizedCommand(command: JsonNode): JsonNode =
  result = newJObject()
  if command.kind != JObject:
    return
  const serverOwned = [
    "id", "application_id", "guild_id", "version", "cordnim"
  ]
  var names: seq[string]
  for name in command.keys:
    if name notin serverOwned:
      names.add name
  names.sort()
  for name in names:
    result[name] = command[name]

proc normalizedCommands(document: JsonNode): Table[string, JsonNode] =
  result = initTable[string, JsonNode]()
  for command in document.commandArray():
    let kind = if command.hasKey("type"): command["type"].getInt(1) else: 1
    let key = command["name"].getStr() & ":" & $kind
    result[key] = command.normalizedCommand()

proc diffCommands(current, desired: JsonNode): seq[string] =
  let currentByName = current.normalizedCommands()
  let desiredByName = desired.normalizedCommands()
  var keys = initHashSet[string]()
  for key in currentByName.keys:
    keys.incl key
  for key in desiredByName.keys:
    keys.incl key
  var sortedKeys = toSeq(keys)
  sortedKeys.sort()
  for key in sortedKeys:
    if not currentByName.hasKey(key):
      result.add "+ " & key
    elif not desiredByName.hasKey(key):
      result.add "- " & key
    elif currentByName.getOrDefault(key) != desiredByName.getOrDefault(key):
      result.add "~ " & key

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc syncParameters(options: SyncOptions): seq[raw_route.RawParameter] =
  result.add(
    raw_route.initRawParameter("application_id", options.applicationId))
  if options.guildId.len != 0:
    result.add(raw_route.initRawParameter("guild_id", options.guildId))

proc makeRawRequest(options: SyncOptions, write: bool,
                    desired: JsonNode): raw_request.RawRequest =
  let route = if options.guildId.len == 0:
    if write: bulkSetApplicationCommands else: listApplicationCommands
  else:
    if write: bulkSetGuildApplicationCommands else: listGuildApplicationCommands
  var body: JsonNode
  if write:
    body = newJArray()
    # Runtime metadata is useful in the manifest but is not part of Discord's
    # bulk-overwrite request schema.
    for command in desired.commandArray():
      body.add(command.normalizedCommand())
  raw_request.initRawRequest(route, options.syncParameters(), body)

proc performRequest(client: ChronosRestClient,
                    request: raw_request.RawRequest,
                    write: bool): Future[JsonNode] {.async.} =
  var meta = defaultRequestMeta()
  meta.priority = rpBackground
  meta.idempotency = if write: idExplicit else: idSafe
  let response = await client.submit(request.toRuntimeRequest(meta))
  if response.status < 200 or response.status >= 300:
    raise newException(CliError,
      "Discord command request failed with HTTP " & $response.status)
  if response.body.len == 0:
    return newJArray()
  try:
    return parseJson(response.body.bytesToString())
  except CatchableError:
    raise newException(CliError, "Discord returned invalid JSON")

proc executeDiscordRequest(raw: raw_request.RawRequest,
                           write: bool): Future[JsonNode] {.async.} =
  let tokenText = botTokenText()
  if tokenText.len == 0:
    raise newException(CliError,
      "DISCORD_BOT_TOKEN is required for Discord access")
  let transport = newDiscordHttpTransport(initSecret[BotToken](tokenText))
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    return await client.performRequest(raw, write)
  finally:
    await client.stop()
    await transport.close()

proc discordRequest(options: SyncOptions, desired: JsonNode,
                    write: bool): Future[JsonNode] {.async.} =
  return await executeDiscordRequest(
    options.makeRawRequest(write, desired), write)

proc parseSyncOptions(arguments: seq[string]): SyncOptions =
  var index = 0
  while index < arguments.len:
    case arguments[index]
    of "--manifest":
      inc index
      if index >= arguments.len:
        raise newException(CliError, "--manifest needs a file")
      result.manifestPath = arguments[index]
    of "--current":
      inc index
      if index >= arguments.len:
        raise newException(CliError, "--current needs a file")
      result.currentPath = arguments[index]
    of "--application":
      inc index
      if index >= arguments.len:
        raise newException(CliError, "--application needs an ID")
      result.applicationId = arguments[index]
    of "--guild":
      inc index
      if index >= arguments.len:
        raise newException(CliError, "--guild needs an ID")
      result.guildId = arguments[index]
    of "--apply": result.apply = true
    of "--yes": result.yes = true
    of "--dry-run": result.apply = false
    else:
      raise newException(CliError, "unknown sync option: " & arguments[index])
    inc index
  if result.manifestPath.len == 0:
    raise newException(CliError, "commands sync requires --manifest")
  if result.applicationId.len == 0 and result.currentPath.len == 0:
    raise newException(CliError,
      "commands sync requires --application for Discord access")
  if result.apply and result.applicationId.len == 0:
    raise newException(CliError,
      "commands sync --apply requires --application")
  if result.applicationId.len != 0:
    try:
      discard parseId(ApplicationId, result.applicationId)
    except ValueError as error:
      raise newException(CliError, "invalid application ID: " & error.msg)
  if result.guildId.len != 0:
    try:
      discard parseId(GuildId, result.guildId)
    except ValueError as error:
      raise newException(CliError, "invalid guild ID: " & error.msg)

proc runCli*(arguments = commandLineParams()): int =
  ## Runs the `cordnim` CLI and returns a process exit code.
  try:
    if arguments.len == 0 or arguments[0] in ["help", "--help", "-h"]:
      stdout.write(usage())
      return 0
    if arguments[0] in ["--version", "version"]:
      stdout.writeLine("cordnim " & CliVersion)
      return 0
    case arguments[0]
    of "schema":
      stdout.writeLine("Discord API v" & $discordApiVersion)
      stdout.writeLine("schema revision " & discordSchemaRevision)
      stdout.writeLine("source commit " & discordSchemaSourceCommit)
      stdout.writeLine($discordOperationCount & " stable operations, " &
        $discordSchemaCount & " schemas")
      return 0
    of "doctor":
      if arguments.len > 2 or
          (arguments.len == 2 and arguments[1] != "--offline"):
        raise newException(CliError, "usage: cordnim doctor [--offline]")
      stdout.writeLine("schema: " & discordSchemaRevision & " (" &
        $discordOperationCount & " operations)")
      stdout.writeLine("Chronos: configured")
      let tokenPresent = botTokenText().len != 0
      stdout.writeLine(
        "bot token: " & (if tokenPresent: "present" else: "missing"))
      if arguments.len == 2:
        return if tokenPresent: 0 else: 1
      if not tokenPresent:
        return 1
      let application = waitFor(executeDiscordRequest(
        raw_request.initRawRequest(getMyOauth2Application), false))
      if application.kind != JObject or not application.hasKey("id"):
        raise newException(CliError,
          "Discord authentication succeeded but application metadata is " &
          "malformed")
      stdout.writeLine("Discord application: " & application["id"].getStr())
      stdout.writeLine("Discord API: reachable")
      return 0
    of "manifest":
      if arguments.len != 3 or arguments[1] notin ["validate", "hash"]:
        raise newException(CliError,
          "usage: cordnim manifest validate|hash <file>")
      let document = loadJson(arguments[2])
      if arguments[1] == "hash":
        stdout.writeLine(document.manifestHash())
        return 0
      let problems = document.validateManifest()
      if problems.len == 0:
        stdout.writeLine("Manifest is valid.")
        return 0
      for problem in problems:
        stderr.writeLine(problem)
      return 1
    of "commands":
      if arguments.len < 2:
        raise newException(CliError, "commands requires diff or sync")
      if arguments[1] == "diff":
        var currentPath, desiredPath: string
        var index = 2
        while index < arguments.len:
          if arguments[index] == "--current" and index + 1 < arguments.len:
            inc index
            currentPath = arguments[index]
          elif arguments[index] == "--desired" and index + 1 < arguments.len:
            inc index
            desiredPath = arguments[index]
          else:
            raise newException(CliError,
              "unknown diff option: " & arguments[index])
          inc index
        let changes = diffCommands(loadJson(currentPath), loadJson(desiredPath))
        for change in changes:
          stdout.writeLine(change)
        return if changes.len == 0: 0 else: 2
      if arguments[1] == "sync":
        let options = parseSyncOptions(arguments[2..^1])
        let desired = loadJson(options.manifestPath)
        let problems = desired.validateManifest()
        if problems.len != 0:
          raise newException(CliError, problems.join("; "))
        if options.currentPath.len != 0 and not options.apply:
          let changes = diffCommands(loadJson(options.currentPath), desired)
          for change in changes:
            stdout.writeLine(change)
          if changes.len > 0:
            stdout.writeLine("Dry run: no Discord state changed.")
          return if changes.len == 0: 0 else: 2
        let current = waitFor(discordRequest(options, desired, false))
        let changes = diffCommands(current, desired)
        if changes.len == 0:
          stdout.writeLine("No command changes.")
          return 0
        for change in changes:
          stdout.writeLine(change)
        if not options.apply:
          stdout.writeLine("Dry run: no Discord state changed.")
          return 2
        if not options.yes:
          raise newException(CliError, "--apply also requires --yes")
        discard waitFor(discordRequest(options, desired, true))
        stdout.writeLine("Discord commands synchronized.")
        return 0
      raise newException(CliError,
        "unknown commands subcommand: " & arguments[1])
    else:
      raise newException(CliError, "unknown command: " & arguments[0])
  except CliError as error:
    stderr.writeLine("cordnim: " & error.msg)
    1
