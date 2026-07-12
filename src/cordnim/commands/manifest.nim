## Deterministic command manifest serialization, hashing, and comparison.

import std/[algorithm, json, options, strutils]

import cordnim/core/bits
import ./spec

type
  ManifestChangeKind* = enum ## Difference between two command manifests.
    mckAdded, ## A command exists only in the desired manifest.
    mckRemoved, ## A command exists only in the current manifest.
    mckChanged ## A command exists in both but its schema changed.

  ManifestChange* = object ## One command-key-addressed manifest change.
    kind*: ManifestChangeKind ## Change classification.
    command*: CommandKey ## Stable Discord command identity.

  CommandManifest* = object ## Versioned, transport-independent command
                            ## manifest.
    schemaRevision*: string ## Pinned Discord schema revision used for
                            ## generation.
    commands*: seq[CommandSpec] ## Commands sorted by kind and name.

func compareCommands(left, right: CommandSpec): int =
  if left.key < right.key:
    -1
  elif right.key < left.key:
    1
  else:
    0

func initCommandManifest*[S](commands: CommandSet[S],
                             schemaRevision: string): CommandManifest =
  ## Creates a manifest and normalizes command order by kind and name.
  result = CommandManifest(
    schemaRevision: schemaRevision,
    commands: commands.specs
  )
  result.commands.sort(compareCommands)

func choiceJson(choice: CommandChoice): JsonNode =
  result = newJObject()
  result["name"] = %choice.name
  if choice.nameLocalizations.len > 0:
    result["name_localizations"] = choice.nameLocalizations.toJson()
  case choice.kind
  of ccvString: result["value"] = %choice.stringValue
  of ccvInteger: result["value"] = %choice.integerValue
  of ccvNumber: result["value"] = %choice.numberValue

func sortedChannelTypesJson(types: seq[CommandChannelType]): JsonNode =
  var ordinals: seq[int]
  for value in types:
    if ord(value) notin ordinals:
      ordinals.add(ord(value))
  ordinals.sort()
  result = newJArray()
  for value in ordinals:
    result.add(%value)

func optionJson(option: CommandOptionSpec): JsonNode =
  result = newJObject()
  result["type"] = %discordType(option.kind)
  result["name"] = %option.name
  if option.nameLocalizations.len > 0:
    result["name_localizations"] = option.nameLocalizations.toJson()
  result["description"] = %option.description
  if option.descriptionLocalizations.len > 0:
    result["description_localizations"] =
      option.descriptionLocalizations.toJson()
  case option.kind
  of cokSubCommand, cokSubCommandGroup:
    # Structural options never carry `required`, ranges, choices, or channel
    # constraints; they only nest further options.
    result["options"] = newJArray()
    for child in option.options:
      result["options"].add(optionJson(child))
  else:
    result["required"] = %option.required
    if option.minimumInt.isSome:
      result["min_value"] = %option.minimumInt.get()
    if option.maximumInt.isSome:
      result["max_value"] = %option.maximumInt.get()
    if option.minimumNumber.isSome:
      result["min_value"] = %option.minimumNumber.get()
    if option.maximumNumber.isSome:
      result["max_value"] = %option.maximumNumber.get()
    if option.minLength.isSome:
      result["min_length"] = %option.minLength.get()
    if option.maxLength.isSome:
      result["max_length"] = %option.maxLength.get()
    if option.channelTypes.len > 0:
      result["channel_types"] = sortedChannelTypesJson(option.channelTypes)
    if option.choices.len > 0:
      result["choices"] = newJArray()
      for choice in option.choices:
        result["choices"].add(choiceJson(choice))
    if option.autocomplete:
      result["autocomplete"] = %true

func commandJson(command: CommandSpec): JsonNode =
  result = newJObject()
  result["name"] = %command.name
  if command.nameLocalizations.len > 0:
    result["name_localizations"] = command.nameLocalizations.toJson()
  result["type"] = %discordType(command.kind)
  # Context-menu commands omit both description and description_localizations
  # from outbound create/edit payloads.
  if command.kind == ckChatInput:
    result["description"] = %command.description
    if command.descriptionLocalizations.len > 0:
      result["description_localizations"] =
        command.descriptionLocalizations.toJson()

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
  sortedCommands.sort(compareCommands)
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
  ## Computes changes in deterministic command-key order.
  var currentCommands = current.commands
  var desiredCommands = desired.commands
  currentCommands.sort(compareCommands)
  desiredCommands.sort(compareCommands)

  var currentIndex = 0
  var desiredIndex = 0
  while currentIndex < currentCommands.len or
      desiredIndex < desiredCommands.len:
    if currentIndex >= currentCommands.len:
      result.add(ManifestChange(kind: mckAdded,
        command: desiredCommands[desiredIndex].key))
      inc desiredIndex
    elif desiredIndex >= desiredCommands.len:
      result.add(ManifestChange(kind: mckRemoved,
        command: currentCommands[currentIndex].key))
      inc currentIndex
    else:
      let currentCommand = currentCommands[currentIndex]
      let desiredCommand = desiredCommands[desiredIndex]
      if currentCommand.key < desiredCommand.key:
        result.add(ManifestChange(kind: mckRemoved,
          command: currentCommand.key))
        inc currentIndex
      elif desiredCommand.key < currentCommand.key:
        result.add(ManifestChange(kind: mckAdded,
          command: desiredCommand.key))
        inc desiredIndex
      else:
        if commandJson(currentCommand) != commandJson(desiredCommand):
          result.add(ManifestChange(kind: mckChanged,
            command: currentCommand.key))
        inc currentIndex
        inc desiredIndex

# --- JSON to CommandSpec decoding for external manifest validation ---

proc requireField(node: JsonNode, field: string, kinds: set[JsonNodeKind],
                  what: string): JsonNode =
  ## Returns the field node when present, requiring one of `kinds`, or `nil`
  ## when absent. A present field of the wrong type is rejected so that a
  ## present-but-wrong-typed field is never silently treated as absent.
  if not node.hasKey(field):
    return nil
  result = node[field]
  if result.kind notin kinds:
    raise newException(CommandSpecError,
      what & " field '" & field & "' has an invalid type")

proc parseLocalizations(node: JsonNode): LocalizationMap =
  ## Decodes a localization dictionary. `node` is `nil` (absent) or `JNull`
  ## (Discord's "none") for an empty map, otherwise a `JObject`; an unknown
  ## locale key or non-string value raises `CommandSpecError`.
  if node.isNil or node.kind == JNull:
    return initLocalizationMap()
  var pairs: seq[(DiscordLocale, string)]
  for key, value in node:
    if value.kind != JString:
      raise newException(CommandSpecError,
        "localization '" & key & "' must be a string")
    let locale = try:
        parseDiscordLocale(key)
      except ValueError:
        raise newException(CommandSpecError, "unknown locale '" & key & "'")
    pairs.add((locale, value.getStr()))
  initLocalizationMap(pairs)

proc parseChoice(node: JsonNode, optionKind: CommandOptionKind): CommandChoice =
  if node.isNil or node.kind != JObject:
    raise newException(CommandSpecError, "choice must be a JSON object")
  let nameNode = requireField(node, "name", {JString}, "choice")
  let name = if nameNode != nil: nameNode.getStr() else: ""
  let localizations = parseLocalizations(
    requireField(node, "name_localizations", {JObject, JNull}, "choice"))
  if not node.hasKey("value"):
    raise newException(CommandSpecError, "choice '" & name & "' has no value")
  let value = node["value"]
  # Choice value type follows the parent option kind, not the JSON kind, so a
  # NUMBER option accepts the integral literal 1 as 1.0 while INTEGER stays
  # strict.
  case optionKind
  of cokString:
    if value.kind != JString:
      raise newException(CommandSpecError,
        "string choice '" & name & "' value must be a string")
    commandChoice(name, value.getStr(), localizations)
  of cokInteger:
    if value.kind != JInt:
      raise newException(CommandSpecError,
        "integer choice '" & name & "' value must be an integer")
    commandChoice(name, value.getBiggestInt(), localizations)
  of cokNumber:
    if value.kind notin {JInt, JFloat}:
      raise newException(CommandSpecError,
        "number choice '" & name & "' value must be a number")
    commandChoice(name, value.getFloat(), localizations)
  else:
    raise newException(CommandSpecError,
      "choices are only valid for string, integer, or number options")

proc parseOption(node: JsonNode): CommandOptionSpec =
  if node.isNil or node.kind != JObject:
    raise newException(CommandSpecError, "option must be a JSON object")
  let typeNode = requireField(node, "type", {JInt}, "option")
  if typeNode == nil:
    raise newException(CommandSpecError, "option type is required")
  let kind = try:
      toCommandOptionKind(typeNode.getInt())
    except ValueError as error:
      raise newException(CommandSpecError, error.msg)
  let nameNode = requireField(node, "name", {JString}, "option")
  let descNode = requireField(node, "description", {JString}, "option")
  result = CommandOptionSpec(
    kind: kind,
    name: if nameNode != nil: nameNode.getStr() else: "",
    description: if descNode != nil: descNode.getStr() else: "",
    nameLocalizations: parseLocalizations(
      requireField(node, "name_localizations", {JObject, JNull}, "option")),
    descriptionLocalizations: parseLocalizations(requireField(
      node, "description_localizations", {JObject, JNull}, "option")))
  case kind
  of cokSubCommand, cokSubCommandGroup:
    # Structural options carry only nested options; scalar-only fields present
    # here are rejected rather than silently dropped.
    for forbidden in ["required", "autocomplete", "choices", "min_value",
        "max_value", "min_length", "max_length", "channel_types"]:
      if node.hasKey(forbidden):
        raise newException(CommandSpecError,
          "subcommand option '" & result.name & "' cannot declare '" &
            forbidden & "'")
    let nested = requireField(node, "options", {JArray}, "option")
    if nested != nil:
      for child in nested:
        result.options.add(parseOption(child))
  else:
    if node.hasKey("options"):
      raise newException(CommandSpecError,
        "scalar option '" & result.name & "' cannot declare nested options")
    let requiredNode = requireField(node, "required", {JBool}, "option")
    if requiredNode != nil:
      result.required = requiredNode.getBool()
    let autoNode = requireField(node, "autocomplete", {JBool}, "option")
    if autoNode != nil:
      result.autocomplete = autoNode.getBool()
    let numericKinds = if kind == cokNumber: {JInt, JFloat} else: {JInt}
    let minValue = requireField(node, "min_value", numericKinds, "option")
    if minValue != nil:
      if kind == cokNumber: result.minimumNumber = some(minValue.getFloat())
      else: result.minimumInt = some(minValue.getBiggestInt())
    let maxValue = requireField(node, "max_value", numericKinds, "option")
    if maxValue != nil:
      if kind == cokNumber: result.maximumNumber = some(maxValue.getFloat())
      else: result.maximumInt = some(maxValue.getBiggestInt())
    let minLength = requireField(node, "min_length", {JInt}, "option")
    if minLength != nil:
      result.minLength = some(minLength.getInt())
    let maxLength = requireField(node, "max_length", {JInt}, "option")
    if maxLength != nil:
      result.maxLength = some(maxLength.getInt())
    let channelTypes = requireField(node, "channel_types", {JArray}, "option")
    if channelTypes != nil:
      for entry in channelTypes:
        if entry.kind != JInt:
          raise newException(CommandSpecError,
            "channel_types entries must be integers")
        result.channelTypes.add(
          try: toCommandChannelType(entry.getInt())
          except ValueError as error:
            raise newException(CommandSpecError, error.msg))
    let choices = requireField(node, "choices", {JArray}, "option")
    if choices != nil:
      for choice in choices:
        result.choices.add(parseChoice(choice, kind))

proc parseInstalls(node: JsonNode): set[CommandInstallContext] =
  for entry in node:
    if entry.kind != JInt:
      raise newException(CommandSpecError,
        "integration_types entries must be integers")
    case entry.getInt()
    of 0: result.incl(guildInstall)
    of 1: result.incl(userInstall)
    else:
      raise newException(CommandSpecError,
        "unknown integration type " & $entry.getInt())

proc parseContexts(node: JsonNode): set[CommandInteractionContext] =
  for entry in node:
    if entry.kind != JInt:
      raise newException(CommandSpecError, "contexts entries must be integers")
    case entry.getInt()
    of 0: result.incl(guildChannel)
    of 1: result.incl(botDm)
    of 2: result.incl(privateChannel)
    else:
      raise newException(CommandSpecError,
        "unknown interaction context " & $entry.getInt())

proc parseCommandSpec*(node: JsonNode): CommandSpec =
  ## Decodes one Discord application-command JSON object into a `CommandSpec`.
  ##
  ## Present fields are strictly type-checked; unknown fields are ignored for
  ## forward compatibility. Omitted `integration_types`/`contexts` take a legal
  ## default, but an explicitly empty array is preserved so `validate` rejects
  ## it. Raises `CommandSpecError` on a malformed shape, unknown enum, or
  ## unknown locale. Pair with `validate` for the full schema rules.
  if node.isNil or node.kind != JObject:
    raise newException(CommandSpecError, "command must be a JSON object")
  let nameNode = requireField(node, "name", {JString}, "command")
  if nameNode == nil:
    raise newException(CommandSpecError, "command name is required")
  let typeNode = requireField(node, "type", {JInt}, "command")
  let typeValue = if typeNode != nil: typeNode.getInt() else: 1
  let kind = try:
      toCommandKind(typeValue)
    except ValueError as error:
      raise newException(CommandSpecError, error.msg)
  result = CommandSpec(
    name: nameNode.getStr(),
    kind: kind,
    nameLocalizations: parseLocalizations(
      requireField(node, "name_localizations", {JObject, JNull}, "command")))
  if kind == ckChatInput:
    let descNode = requireField(node, "description", {JString}, "command")
    result.description = if descNode != nil: descNode.getStr() else: ""
    result.descriptionLocalizations = parseLocalizations(requireField(
      node, "description_localizations", {JObject, JNull}, "command"))
    let options = requireField(node, "options", {JArray}, "command")
    if options != nil:
      for child in options:
        result.options.add(parseOption(child))
  else:
    # Context-menu commands cannot carry these; rejecting (not dropping) keeps
    # the outbound JSON and the validated spec in agreement before sync.
    for forbidden in ["description", "description_localizations", "options"]:
      if node.hasKey(forbidden):
        raise newException(CommandSpecError,
          "context-menu command '" & result.name & "' cannot declare '" &
            forbidden & "'")
  let installs = requireField(node, "integration_types", {JArray}, "command")
  result.installs =
    if installs == nil: {guildInstall} else: parseInstalls(installs)
  let contexts = requireField(node, "contexts", {JArray}, "command")
  result.contexts =
    if contexts == nil: {guildChannel} else: parseContexts(contexts)
