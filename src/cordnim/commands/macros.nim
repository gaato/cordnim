## Compile-time command schema and dispatcher generation.
##
## The macros in this module compile declarations into plain metadata and
## narrow adapters. Network I/O and asynchronous control flow remain visible
## in the runtime layer.

import std/[algorithm, json, macros, options, strutils, unicode]
import chronos

import cordnim/app/context
import cordnim/core/ids
import cordnim/core/[bits, permissions]
import ./spec

type
  CommandOptionDecodeError = object of CatchableError

  ParameterInfo = object
    sourceName: string
    wireName: string
    symbol: NimNode
    typeNode: NimNode
    defaultValue: NimNode
    isOptional: bool
    valueType: NimNode
    spec: NimNode

  CommandInfo = object
    kind: CommandKind
    name: string
    handler: NimNode
    servicesType: NimNode
    spec: NimNode
    parameters: seq[ParameterInfo]
    asyncHandler: bool

proc optionObject(invocation: CommandInvocation): JsonNode =
  ## Returns the invocation's options as a JSON object.
  ##
  ## A nil node represents omitted options. A present node with another JSON
  ## kind is malformed and must not be mistaken for an empty option set.
  if invocation.options.isNil:
    newJObject()
  elif invocation.options.kind != JObject:
    raise newException(CommandOptionDecodeError,
      "command options must be a JSON object")
  else:
    invocation.options

proc requiredOption(options: JsonNode, name: string): JsonNode =
  if options.isNil or options.kind != JObject:
    raise newException(CommandOptionDecodeError,
      "command options must be a JSON object")
  if not options.hasKey(name) or options[name].kind == JNull:
    raise newException(CommandOptionDecodeError,
      "missing required command option: " & name)
  options[name]

proc decodeString(node: JsonNode, name: string): string =
  if node.kind != JString:
    raise newException(CommandOptionDecodeError,
      "command option '" & name & "' must be a string")
  node.getStr()

proc decodeBoolean(node: JsonNode, name: string): bool =
  if node.kind != JBool:
    raise newException(CommandOptionDecodeError,
      "command option '" & name & "' must be a boolean")
  node.getBool()

proc decodeInteger[T: SomeInteger](node: JsonNode, name: string): T =
  if node.kind != JInt:
    raise newException(CommandOptionDecodeError,
      "command option '" & name & "' must be an integer")
  let value = node.getBiggestInt()
  if value < BiggestInt(low(T)) or value > BiggestInt(high(T)):
    raise newException(CommandOptionDecodeError,
      "command option '" & name & "' is outside its declared range")
  T(value)

proc decodeNumber[T: SomeFloat](node: JsonNode, name: string): T =
  if node.kind notin {JInt, JFloat}:
    raise newException(CommandOptionDecodeError,
      "command option '" & name & "' must be a number")
  T(node.getFloat())

proc wireName(sourceName: string): string =
  # Nim permits camelCase parameter names while Discord command option names
  # use lowercase ASCII. Preserve word boundaries for readable manifests.
  for character in sourceName:
    if character in {'A'..'Z'}:
      if result.len > 0:
        result.add('_')
      result.add(character.toLowerAscii())
    else:
      result.add(character)

proc isNamed(node: NimNode, name: string): bool =
  node.kind in {nnkIdent, nnkSym} and node.strVal == name

proc idBasename(rendered: string): string =
  ## Returns a type name without module qualification, so only the exact
  ## Discord ID types match (e.g. `SuperUserId`/`MyAttachmentId` do not).
  let dot = rendered.rfind('.')
  if dot >= 0: rendered[dot + 1 .. ^1] else: rendered

const discordIdTypeNames = ["UserId", "ChannelId", "RoleId", "AttachmentId"]

proc optionValueType(typeNode: NimNode): tuple[optional: bool, value: NimNode] =
  if typeNode.kind == nnkBracketExpr and typeNode.len == 2 and
      typeNode[0].isNamed("Option"):
    (true, typeNode[1])
  else:
    (false, typeNode)

proc enumFields(typeNode: NimNode): seq[string] =
  let implementation = typeNode.getTypeImpl()
  if implementation.kind != nnkEnumTy:
    return
  for index in 1..<implementation.len:
    let field = implementation[index]
    case field.kind
    of nnkSym, nnkIdent:
      result.add(field.strVal)
    of nnkEnumFieldDef:
      result.add(field[0].strVal)
    else:
      discard

proc optionKind(typeNode: NimNode, parameter: NimNode): CommandOptionKind =
  let rendered = typeNode.repr
  let implementation = typeNode.getTypeImpl()
  if rendered == "string":
    cokString
  elif rendered == "bool":
    cokBoolean
  elif rendered in ["float", "float32", "float64"]:
    cokNumber
  elif rendered in ["uint", "uint64"]:
    error(
      "unsigned 64-bit option type '" & rendered &
        "' exceeds Discord's signed safe integer range and overflows " &
        "BiggestInt; use int/int64 or a bounded range[a..b]",
      parameter
    )
  elif rendered in ["int", "int8", "int16", "int32", "int64",
                    "uint8", "uint16", "uint32"] or
      (typeNode.kind == nnkBracketExpr and typeNode[0].isNamed("range")):
    cokInteger
  elif implementation.kind == nnkEnumTy:
    cokString
  elif idBasename(rendered) == "UserId":
    cokUser
  elif idBasename(rendered) == "ChannelId":
    cokChannel
  elif idBasename(rendered) == "RoleId":
    cokRole
  elif idBasename(rendered) == "AttachmentId":
    cokAttachment
  else:
    error(
      "unsupported Discord command option type '" & rendered &
        "'; add a typed transformer or use a Discord-native option type",
      parameter
    )

proc choiceExpr(name: string): NimNode =
  # Enum options generate string choices whose wire value is the member name.
  let choiceType = bindSym"CommandChoice"
  result = newTree(nnkObjConstr, choiceType,
    newTree(nnkExprColonExpr, ident"kind", bindSym"ccvString"),
    newTree(nnkExprColonExpr, ident"name", newLit(name)),
    newTree(nnkExprColonExpr, ident"stringValue", newLit(name)))

proc optionSpecExpr(parameterName: string, typeNode: NimNode,
                    required: bool, parameter: NimNode): NimNode =
  let kind = optionKind(typeNode, parameter)
  let fields = enumFields(typeNode)
  if fields.len > 25:
    error("enum option '" & parameterName & "' has " & $fields.len &
      " choices, but Discord permits at most 25; replace static choices " &
      "with an autocomplete transformer", parameter)

  let specType = bindSym"CommandOptionSpec"
  let kindNode = newCall(bindSym"CommandOptionKind", newLit(ord(kind)))
  let requiredNode = newLit(required)
  let description = newLit("Value for `" & parameterName & "`.")
  var choices = newTree(nnkPrefix, ident"@", newTree(nnkBracket))
  for field in fields:
    choices[1].add(choiceExpr(field))

  var minimum = quote do: none(int64)
  var maximum = quote do: none(int64)
  if typeNode.kind == nnkBracketExpr and typeNode[0].isNamed("range"):
    let bounds = typeNode[1]
    if bounds.kind == nnkInfix and bounds.len == 3 and bounds[0].isNamed(".."):
      let lowerBound = bounds[1]
      let upperBound = bounds[2]
      minimum = quote do: some(int64(`lowerBound`))
      maximum = quote do: some(int64(`upperBound`))

  result = newTree(nnkObjConstr, specType,
    newTree(nnkExprColonExpr, ident"name", newLit(parameterName)),
    newTree(nnkExprColonExpr, ident"description", description),
    newTree(nnkExprColonExpr, ident"kind", kindNode),
    newTree(nnkExprColonExpr, ident"required", requiredNode),
    newTree(nnkExprColonExpr, ident"minimumInt", minimum),
    newTree(nnkExprColonExpr, ident"maximumInt", maximum),
    newTree(nnkExprColonExpr, ident"choices", choices))

proc enumSetExpr(node, enumType: NimNode,
                 names: openArray[string]): NimNode =
  result = newTree(nnkCurly)
  for value in node:
    let ordinal = value.intVal.int
    if ordinal < 0 or ordinal >= names.len:
      error("invalid enum value in discordCommand metadata", value)
    result.add(newCall(enumType, newLit(ordinal)))

proc permissionBitsExpr(node: NimNode): NimNode =
  var values = node
  while values.kind in {nnkHiddenStdConv, nnkHiddenSubConv} and values.len > 0:
    values = values[^1]
  var low = 0'u64
  for value in values:
    let position = value.intVal.int
    if position < 0 or position >= 64:
      error("declared bot permission is outside the known low limb", value)
    low = low or (1'u64 shl position)
  let initializer = newTree(
    nnkBracketExpr, bindSym"initDiscordBits", bindSym"Permission")
  newCall(initializer, newLit(low))

proc discordPragma(implementation: NimNode): NimNode =
  for pragma in implementation[4]:
    if pragma.kind == nnkCall and pragma.len > 0 and
        pragma[0].isNamed("discordCommand"):
      return pragma
  newEmptyNode()

proc parameterInfo(definition: NimNode, symbol: NimNode): ParameterInfo =
  result.sourceName = symbol.strVal
  result.wireName = wireName(result.sourceName)
  result.symbol = symbol
  result.typeNode = symbol.getTypeInst()
  result.defaultValue = definition[^1]
  let unpacked = optionValueType(result.typeNode)
  result.isOptional = unpacked.optional
  result.valueType = unpacked.value
  let required = not result.isOptional and result.defaultValue.kind == nnkEmpty
  result.spec = optionSpecExpr(result.wireName, result.valueType,
    required, symbol)

proc commandInfo(handler: NimNode): CommandInfo =
  let implementation = handler.getImpl()
  if implementation.kind notin {nnkProcDef, nnkFuncDef}:
    error("commandSet accepts procedure symbols", handler)

  let metadata = discordPragma(implementation)
  if metadata.kind == nnkEmpty:
    error("command procedure must use {.discordCommand(...).}", handler)
  # Semchecked custom pragmas currently retain a duplicate argument tail. Only
  # the first expanded parameter set is part of the declaration contract.
  if metadata.len < 10:
    error("invalid discordCommand metadata", handler)

  let kindOrdinal = metadata[5].intVal.int
  result.kind = CommandKind(kindOrdinal)
  result.name = metadata[1].strVal
  let description = metadata[2].strVal
  case result.kind
  of ckChatInput:
    if not validChatInputName(result.name):
      error(
        "chat-input command name must use Discord's 1-32 character " &
          "lowercase slash-command syntax",
        handler
      )
    if description.runeLen notin 1..100:
      error("chat-input command description must contain 1-100 characters",
        handler)
  of ckUser, ckMessage:
    if not validContextMenuName(result.name):
      error(
        "context-menu command name must contain 1-32 visible characters",
        handler
      )
    if description.len != 0:
      error("user and message commands cannot declare a description", handler)

  let parameters = implementation[3]
  if parameters.len < 2:
    error("command procedure must begin with CommandCtx[Services]", handler)
  let contextType = parameters[1][0].getTypeInst()
  if contextType.kind != nnkBracketExpr or contextType.len != 2 or
      not contextType[0].isNamed("CommandCtx"):
    error("first command parameter must be CommandCtx[Services]", parameters[1])
  result.servicesType = contextType[1]
  result.handler = handler

  let returnType = parameters[0]
  let renderedReturn = returnType.repr.replace(" ", "")
  if renderedReturn == "CommandResult":
    result.asyncHandler = false
  elif renderedReturn == "Future[CommandResult]":
    result.asyncHandler = true
  else:
    error("command procedure must return CommandResult or " &
      "Future[CommandResult] from Chronos", handler)

  for index in 2..<parameters.len:
    let definition = parameters[index]
    for symbolIndex in 0 ..< definition.len - 2:
      result.parameters.add(parameterInfo(definition, definition[symbolIndex]))

  if kindOrdinal != ord(ckChatInput) and result.parameters.len > 0:
    error(
      "user and message context commands cannot declare slash options",
      handler
    )
  if result.parameters.len > 25:
    error(
      "Discord chat-input commands permit at most 25 top-level options",
      handler
    )

  # Discord requires every required option to precede the optional ones.
  var sawOptional = false
  for parameter in result.parameters:
    let required = not parameter.isOptional and
      parameter.defaultValue.kind == nnkEmpty
    if required and sawOptional:
      error(
        "required option '" & parameter.wireName &
          "' must be declared before optional options",
        parameter.symbol
      )
    if not required:
      sawOptional = true

  let installsExpr = enumSetExpr(metadata[3], bindSym"CommandInstallContext",
    ["guildInstall", "userInstall"])
  let contextsExpr = enumSetExpr(metadata[4],
    bindSym"CommandInteractionContext",
    ["guildChannel", "botDm", "privateChannel"])
  let kindExpr = newCall(bindSym"CommandKind", newLit(kindOrdinal))
  let ackExpr = newCall(bindSym"CommandAckKind",
    newLit(metadata[6].intVal.int))
  let ackOrdinal = metadata[6].intVal.int
  let delayExpr = newLit(metadata[7].intVal.int)
  let ephemeralExpr = newLit(metadata[8].intVal != 0)
  let requiredPermissionsExpr = permissionBitsExpr(metadata[9])
  if delayExpr.intVal < 0:
    error("autoDeferAfterMs cannot be negative", handler)
  if ackOrdinal != ord(ackManual) and delayExpr.intVal >= 3_000:
    error(
      "automatic defer must run before Discord's 3-second ACK deadline",
      handler
    )

  var optionsExpr = newTree(nnkPrefix, ident"@", newTree(nnkBracket))
  for parameter in result.parameters:
    optionsExpr[1].add(parameter.spec)
  let specType = bindSym"CommandSpec"
  result.spec = newTree(nnkObjConstr, specType,
    newTree(nnkExprColonExpr, ident"name", newLit(result.name)),
    newTree(nnkExprColonExpr, ident"description", newLit(description)),
    newTree(nnkExprColonExpr, ident"kind", kindExpr),
    newTree(nnkExprColonExpr, ident"installs", installsExpr),
    newTree(nnkExprColonExpr, ident"contexts", contextsExpr),
    newTree(nnkExprColonExpr, ident"ack", ackExpr),
    newTree(nnkExprColonExpr, ident"autoDeferAfterMs", delayExpr),
    newTree(nnkExprColonExpr, ident"ephemeral", ephemeralExpr),
    newTree(nnkExprColonExpr, ident"requiredBotPermissions",
      requiredPermissionsExpr),
    newTree(nnkExprColonExpr, ident"options", optionsExpr))

proc decodeExpr(typeNode, node, wireNameNode: NimNode): NimNode =
  let rendered = typeNode.repr
  let implementation = typeNode.getTypeImpl()
  if rendered == "string":
    let decode = bindSym"decodeString"
    result = quote do: `decode`(`node`, `wireNameNode`)
  elif idBasename(rendered) in discordIdTypeNames:
    # Attachment options arrive as a snowflake; the resolved attachment object
    # stays available in `invocation.resolved`. `typedesc[...]` is required so
    # the spliced type binds to parseId's typedesc parameter rather than being
    # read as a value.
    let decode = bindSym"decodeString"
    let parse = bindSym"parseId"
    result = quote do:
      `parse`(typedesc[`typeNode`], `decode`(`node`, `wireNameNode`))
  elif rendered == "bool":
    let decode = bindSym"decodeBoolean"
    result = quote do: `decode`(`node`, `wireNameNode`)
  elif rendered in ["float", "float32", "float64"]:
    let decode = bindSym"decodeNumber"
    result = quote do: `decode`[`typeNode`](`node`, `wireNameNode`)
  elif rendered in ["int", "int8", "int16", "int32", "int64",
                    "uint8", "uint16", "uint32"] or
      (typeNode.kind == nnkBracketExpr and typeNode[0].isNamed("range")):
    let decode = bindSym"decodeInteger"
    result = quote do: `decode`[`typeNode`](`node`, `wireNameNode`)
  elif implementation.kind == nnkEnumTy:
    let decode = bindSym"decodeString"
    let parse = bindSym"parseEnum"
    result = quote do: `parse`[`typeNode`](`decode`(`node`, `wireNameNode`))
  else:
    error("no generated decoder for command option type '" & rendered & "'",
      typeNode)

proc adapterExpr(command: CommandInfo): NimNode =
  let services = genSym(nskParam, "services")
  let responseContext = genSym(nskParam, "responseContext")
  let invocation = genSym(nskParam, "invocation")
  let commandContext = genSym(nskLet, "commandContext")
  let handler = command.handler
  let servicesType = command.servicesType
  let servicesRefType = newTree(nnkRefTy, servicesType)
  let invocationType = bindSym"CommandInvocation"
  let resultType = bindSym"CommandResult"
  let futureType = newTree(nnkBracketExpr, bindSym"Future", resultType)
  let responseContextType = bindSym"Context"
  let initContext = bindSym"initCommandCtx"
  let invalid = bindSym"invalidOptions"
  let required = bindSym"requiredOption"

  var body = newStmtList()
  body.add quote do:
    let `commandContext` = `initContext`(
      `services`, `responseContext`, `invocation`)

  let optionsSym = genSym(nskLet, "options")
  if command.parameters.len > 0:
    let optionObjectSym = bindSym"optionObject"
    body.add quote do:
      let `optionsSym` = try:
        `optionObjectSym`(`invocation`)
      except CatchableError as decodeError:
        return `invalid`(decodeError.msg)

  var arguments = @[commandContext]
  for parameter in command.parameters:
    let local = genSym(nskLet, parameter.sourceName)
    let wireNameNode = newLit(parameter.wireName)
    let optionsNode = optionsSym
    let hasKey = newCall(bindSym"hasKey", optionsNode, wireNameNode)
    let indexed = newTree(nnkBracketExpr, optionsNode, wireNameNode)
    var value: NimNode
    if parameter.isOptional:
      let someProc = bindSym"some"
      let noneProc = bindSym"none"
      let decoded = decodeExpr(parameter.valueType, indexed, wireNameNode)
      let valueType = parameter.valueType
      let present = newTree(nnkInfix, ident"and", hasKey,
        newTree(nnkInfix, ident"!=", newDotExpr(indexed, ident"kind"),
          bindSym"JNull"))
      let emptyOption = newCall(newTree(nnkBracketExpr, noneProc, valueType))
      value = quote do:
        (if `present`: `someProc`(`decoded`) else: `emptyOption`)
    elif parameter.defaultValue.kind != nnkEmpty:
      let decoded = decodeExpr(parameter.valueType, indexed, wireNameNode)
      let defaultValue = parameter.defaultValue
      value = quote do:
        (if `hasKey`: `decoded` else: `defaultValue`)
    else:
      let requiredNode = newCall(required, optionsNode, wireNameNode)
      value = decodeExpr(parameter.valueType, requiredNode, wireNameNode)

    body.add quote do:
      let `local` = try:
        `value`
      except CatchableError as decodeError:
        return `invalid`(decodeError.msg)
    arguments.add(local)

  let handlerCall = newCall(handler, arguments)
  if command.asyncHandler:
    body.add quote do:
      return await `handlerCall`
  else:
    body.add(newTree(nnkReturnStmt, handlerCall))
  result = newProc(
    params = [futureType,
      newIdentDefs(services, servicesRefType),
      newIdentDefs(responseContext, responseContextType),
      newIdentDefs(invocation, invocationType)],
    body = body,
    procType = nnkLambda,
    pragmas = newTree(nnkPragma, bindSym"async"))

macro commandSet*(handlers: varargs[typed]): untyped =
  ## Compiles typed command procedures into an explicit schema and dispatcher.
  ##
  ## All procedures must use `discordCommand`, share one `CommandCtx[S]`
  ## services type, and return `CommandResult` or Chronos
  ## `Future[CommandResult]`. The resulting registry is sorted by command kind
  ## and name, so manifest output does not depend on registration order.
  ## Generated adapters combine app-owned services, the ingress response
  ## capability, and middleware-normalized invocation in `CommandCtx[S]`.
  ##
  ## Parameters map from strings, booleans, integer ranges, floating-point
  ## values, enums, and typed user, channel, role, and attachment values.
  ## `Option[T]` and Nim defaults control requiredness; camel-case parameter
  ## names become snake-case Discord option names. A decode failure returns
  ## `crInvalidOptions` without invoking its handler.
  ##
  ## Calling `commandSet` without handlers, duplicate command keys, mixed
  ## services types, invalid command metadata, and unsupported parameter types
  ## are compile-time errors.
  if handlers.len == 0:
    error(
      "empty commandSet has no services type; use initCommandSet[Services]()"
    )

  var commands: seq[CommandInfo]
  for handler in handlers:
    commands.add(commandInfo(handler))
  commands.sort(proc (left, right: CommandInfo): int =
    let kindOrder = cmp(ord(left.kind), ord(right.kind))
    if kindOrder != 0: kindOrder else: cmp(left.name, right.name))

  for index in 1..<commands.len:
    if commands[index - 1].kind == commands[index].kind and
        commands[index - 1].name == commands[index].name:
      error("duplicate Discord command key '" & commands[index].name & "'",
        commands[index].handler)
    if commands[index].servicesType.repr != commands[0].servicesType.repr:
      error("all procedures in one commandSet must use the same Services type",
        commands[index].handler)

  var specs = newTree(nnkPrefix, ident"@", newTree(nnkBracket))
  var adapters = newTree(nnkPrefix, ident"@", newTree(nnkBracket))
  for command in commands:
    specs[1].add(command.spec)
    let handlerType = newTree(nnkBracketExpr, bindSym"CommandHandler",
      command.servicesType)
    adapters[1].add(newCall(handlerType, adapterExpr(command)))
  let initialize = bindSym"initCommandSet"
  result = newCall(initialize, specs, adapters)
