## `cordnim` command-line interface for schema inspection and command sync.

import std/[algorithm, json, os, sequtils, sets, strutils, tables]

import chronos

import cordnim/build_info
import cordnim/core/secrets
import cordnim/core/ids
import cordnim/commands/spec as command_spec
import cordnim/commands/manifest as command_manifest
import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import cordnim/raw/routes/applications
import cordnim/raw/routes/oauth2
import cordnim/raw/schema_info
import cordnim/rest as runtime_rest

const CliVersion* = CordnimBuildLabel
  ## Build label reported by the installed `cordnim` executable.

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
  ## Validates each command by decoding it into a `CommandSpec` and running the
  ## shared command-layer `validate`, so the CLI enforces the same naming,
  ## nesting, localization, numeric/string, install, and context rules as the
  ## compiler and explicit builders instead of a drifting shallow copy.
  var keys = initHashSet[string]()
  let commands =
    try:
      document.commandArray()
    except CliError as error:
      return @[error.msg]
  for index in 0..<commands.len:
    let command = commands[index]
    if command.kind != JObject:
      result.add $index & ": command must be an object"
      continue
    let spec =
      try:
        command_manifest.parseCommandSpec(command)
      except CommandSpecError as error:
        result.add $index & ": " & error.msg
        continue
    try:
      command_spec.validate(spec)
    except CommandSpecError as error:
      result.add spec.name & ": " & error.msg
    # Discord keys application commands by name and type; validate is per
    # command, so duplicate identities are checked across the manifest here.
    let key = spec.name & ":" & $command_spec.discordType(spec.kind)
    if key in keys:
      result.add $index & ": duplicate command '" & spec.name &
        "' of type " & $command_spec.discordType(spec.kind)
    keys.incl key

proc canonicalize(node: JsonNode): JsonNode =
  ## Recursively sorts object keys so a JSON object key reorder does not change
  ## the hash. Array order is preserved because it is semantically meaningful
  ## for options and choices.
  case node.kind
  of JObject:
    result = newJObject()
    var keys: seq[string]
    for key in node.keys:
      keys.add(key)
    keys.sort()
    for key in keys:
      result[key] = canonicalize(node[key])
  of JArray:
    result = newJArray()
    for item in node:
      result.add(canonicalize(item))
  else:
    result = node

proc manifestHash(document: JsonNode): string =
  var value = 14695981039346656037'u64
  for character in $canonicalize(document):
    value = (value xor uint64(ord(character))) * 1099511628211'u64
  value.toHex(16).toLowerAscii()

const serverOwnedFields = [
  "id", "application_id", "guild_id", "version", "cordnim",
  "name_localized", "description_localized"
]
  ## Fields Discord owns in responses or that carry only local runtime
  ## metadata; they never participate in synchronization comparisons.

proc isDefaultCommandField(command: JsonNode, name: string): bool =
  ## Reports whether a fetched command field equals a Discord default that our
  ## manifests omit, so dropping it cannot hide a managed difference.
  let node = command[name]
  case name
  of "nsfw": node.kind == JBool and not node.getBool()
  of "default_permission": node.kind == JBool and node.getBool()
  of "default_member_permissions": node.kind == JNull
  of "dm_permission":
    # Discord still echoes the deprecated field as true when it was omitted.
    # True is the documented default, so it must not make a freshly applied
    # manifest appear dirty; false remains a managed restriction.
    node.kind == JNull or (node.kind == JBool and node.getBool())
  of "name_localizations", "description_localizations":
    node.kind == JNull or (node.kind == JObject and node.len == 0)
  of "options": node.kind == JArray and node.len == 0
  of "description":
    # USER and MESSAGE commands cannot carry a description; Discord echoes "".
    command.getOrDefault("type").getInt(1) != 1 and
      node.kind == JString and node.getStr().len == 0
  else: false

proc sortedIntSet(node: JsonNode): JsonNode =
  ## Returns a sorted, de-duplicated copy of an integer array so unordered
  ## Discord sets (integration_types, contexts, channel_types) compare equal
  ## regardless of wire order.
  if node.kind != JArray:
    return node
  var values: seq[int]
  for item in node:
    if item.kind == JInt and item.getInt() notin values:
      values.add(item.getInt())
  values.sort()
  result = newJArray()
  for value in values:
    result.add(%value)

proc canonicalNumber(node: JsonNode): JsonNode =
  ## Canonicalizes a NUMBER (Discord type 10) value so 1 and 1.0 compare equal.
  ## Non-numeric nodes are returned unchanged; INTEGER values are never routed
  ## here, preserving strict integer semantics.
  if node.kind in {JInt, JFloat}: %node.getFloat() else: node

proc canonicalNumberChoice(choice: JsonNode): JsonNode =
  if choice.kind != JObject:
    return choice
  result = newJObject()
  for key in choice.keys:
    result[key] =
      if key == "value": canonicalNumber(choice[key]) else: choice[key]

proc normalizedOption(option: JsonNode): JsonNode =
  ## Drops option defaults Discord echoes but our manifests omit, recursing
  ## into nested subcommand options so comparisons stay structural. NUMBER
  ## option ranges and choice values are canonicalized so 1 and 1.0 are equal.
  if option.kind != JObject:
    return option
  result = newJObject()
  let optionType = option.getOrDefault("type").getInt(0)
  var names: seq[string]
  for name in option.keys:
    case name
    of "name_localized", "description_localized": continue
    of "required", "autocomplete":
      if option[name].kind == JBool and not option[name].getBool(): continue
    of "name_localizations", "description_localizations":
      if option[name].kind == JNull or
          (option[name].kind == JObject and option[name].len == 0): continue
    of "options":
      if option[name].kind == JArray and option[name].len == 0: continue
    else: discard
    names.add name
  names.sort()
  for name in names:
    if name == "options" and option[name].kind == JArray:
      var nested = newJArray()
      for child in option[name]:
        nested.add(normalizedOption(child))
      result[name] = nested
    elif name == "channel_types":
      result[name] = sortedIntSet(option[name])
    elif optionType == 10 and name in ["min_value", "max_value"]:
      result[name] = canonicalNumber(option[name])
    elif optionType == 10 and name == "choices" and
        option[name].kind == JArray:
      var canonical = newJArray()
      for choice in option[name]:
        canonical.add(canonicalNumberChoice(choice))
      result[name] = canonical
    else:
      result[name] = option[name]

proc normalizedCommand(command: JsonNode, guildScoped = false): JsonNode =
  result = newJObject()
  if command.kind != JObject:
    return
  var names: seq[string]
  for name in command.keys:
    if name in serverOwnedFields:
      continue
    # integration_types and contexts are global-only fields; a guild command
    # neither sends nor receives them, so they must not enter a guild-scoped
    # comparison or outbound body.
    if guildScoped and name in ["integration_types", "contexts"]:
      continue
    if command.isDefaultCommandField(name):
      continue
    names.add name
  names.sort()
  for name in names:
    if name == "options" and command[name].kind == JArray:
      var nested = newJArray()
      for child in command[name]:
        nested.add(normalizedOption(child))
      result[name] = nested
    elif name in ["integration_types", "contexts"]:
      result[name] = sortedIntSet(command[name])
    else:
      result[name] = command[name]

proc commandShapeProblems(document: JsonNode): seq[string] =
  ## Validates the minimum shape needed to diff a command array (each command an
  ## object with a string name and, if present, an integer type). Returns
  ## problems so malformed input becomes a typed CliError, never a Defect.
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
      result.add $index & ": command name must be a string"
    elif command.hasKey("type") and command["type"].kind != JInt:
      result.add command["name"].getStr() & ": command type must be an integer"

proc normalizedCommands(document: JsonNode,
                        guildScoped = false): Table[string, JsonNode] =
  result = initTable[string, JsonNode]()
  for command in document.commandArray():
    if command.kind != JObject:
      continue # shape is validated separately; never index a non-object here
    let kind = command.getOrDefault("type").getInt(1)
    let key = command.getOrDefault("name").getStr() & ":" & $kind
    result[key] = command.normalizedCommand(guildScoped)

proc diffCommands(current, desired: JsonNode,
                  guildScoped = false): seq[string] =
  let currentByName = current.normalizedCommands(guildScoped)
  let desiredByName = desired.normalizedCommands(guildScoped)
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
  let guildScoped = options.guildId.len != 0
  var body: JsonNode
  if write:
    body = newJArray()
    # Runtime metadata is useful in the manifest but is not part of Discord's
    # bulk-overwrite request schema; global-only fields are dropped for guilds.
    for command in desired.commandArray():
      body.add(command.normalizedCommand(guildScoped))
  result = raw_request.initRawRequest(route, options.syncParameters(), body)
  if not write:
    # List endpoints return only the requester-locale `name_localized` and
    # `description_localized` fields by default. Request the full localization
    # dictionaries so localized manifests compare against complete data instead
    # of diffing forever. Writes carry localizations in the body, not the query.
    result.addQuery("with_localizations", "true")

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
        let current = loadJson(currentPath)
        let desired = loadJson(desiredPath)
        # Desired is the source of truth: full schema validation. Current is
        # fetched/authored: validate at least its shape so a malformed file is
        # a typed error instead of a defect during normalization.
        let desiredProblems = desired.validateManifest()
        if desiredProblems.len != 0:
          raise newException(CliError, desiredProblems.join("; "))
        let currentProblems = current.commandShapeProblems()
        if currentProblems.len != 0:
          raise newException(CliError, currentProblems.join("; "))
        let changes = diffCommands(current, desired)
        for change in changes:
          stdout.writeLine(change)
        return if changes.len == 0: 0 else: 2
      if arguments[1] == "sync":
        let options = parseSyncOptions(arguments[2..^1])
        let desired = loadJson(options.manifestPath)
        let problems = desired.validateManifest()
        if problems.len != 0:
          raise newException(CliError, problems.join("; "))
        let guildScoped = options.guildId.len != 0
        if options.currentPath.len != 0 and not options.apply:
          let current = loadJson(options.currentPath)
          let currentProblems = current.commandShapeProblems()
          if currentProblems.len != 0:
            raise newException(CliError, currentProblems.join("; "))
          let changes = diffCommands(current, desired, guildScoped)
          for change in changes:
            stdout.writeLine(change)
          if changes.len > 0:
            stdout.writeLine("Dry run: no Discord state changed.")
          return if changes.len == 0: 0 else: 2
        let current = waitFor(discordRequest(options, desired, false))
        let liveProblems = current.commandShapeProblems()
        if liveProblems.len != 0:
          raise newException(CliError,
            "Discord returned malformed command data: " &
              liveProblems.join("; "))
        let changes = diffCommands(current, desired, guildScoped)
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
