## Shared command router for HTTP and Gateway interaction ingress.
##
## The transport supplies verified JSON and a completion sink. Command decoding,
## typed dispatch, acknowledgement policy, and response construction are shared.

import std/[json, options]

import chronos

import cordnim/[app, commands]
import cordnim/core/[bits, ids, permissions]
import cordnim/core/errors
import cordnim/rest/chronos_driver
import cordnim/rest/request
import cordnim/runtime/task_scope
import ./[context, http_server, responder]

const InitialResponseSendMarginMs = 250'i64
  # Reserve time for JSON serialization and the HTTP or Gateway write after the
  # router selects an initial response.

type
  InteractionDecodeError* = object of CatchableError
    ## Raised when a verified payload lacks required command fields.

  DeferredCompletionSink* = proc(interaction: JsonNode,
                                  result: CommandResult): Future[void]
    {.gcsafe, raises: [].}
    ## Edits the deferred original response after a command finishes.

  DeferredFailureKind* = enum
    ## Background phase that failed after an automatic defer.
    dfkHandler,    ## The deferred command handler failed.
    dfkCompletion  ## Editing the original deferred response failed.

  DeferredFailureObserver* = proc(kind: DeferredFailureKind,
                                  interactionId: Option[InteractionId])
    {.gcsafe, raises: [].}
    ## Receives redacted deferred-failure metadata for logs or metrics.

  InitialResponseSender* = proc(response: JsonNode): Future[void]
    {.gcsafe, raises: [].}
    ## Sends a Gateway interaction callback response.

  CommandRouter*[S] = ref object ## Shared typed command router and task owner.
    app*: DiscordApp[S]             ## Application whose registry is dispatched.
    tasks*: TaskScope               ## Deferred completion children.
    completionSink*: DeferredCompletionSink ## Optional post-defer editor.
    failureObserver*: DeferredFailureObserver ## Optional redacted failure hook.

proc responseData(commandResult: CommandResult): JsonNode =
  if commandResult.payload.isNil:
    result = %*{"content": commandResult.message}
  else:
    # Copy handler-owned JSON before adding transport security defaults.
    result = commandResult.payload.copy()
  if not result.hasKey("allowed_mentions"):
    result["allowed_mentions"] = %*{"parse": []}
  if commandResult.kind in {crRejected, crInvalidOptions, crNotFound}:
    result["flags"] = %64

func initialMessageResponse*(commandResult: CommandResult): JsonNode =
  ## Builds a secure type-4 interaction response with mentions disabled.
  result = newJObject()
  result["type"] = %4
  result["data"] = commandResult.responseData()

func deferredMessageResponse*(ephemeral: bool): JsonNode =
  ## Builds a type-5 deferred interaction response.
  result = newJObject()
  result["type"] = %5
  result["data"] = newJObject()
  if ephemeral:
    result["data"]["flags"] = %64

func editOriginalPayload*(commandResult: CommandResult): JsonNode =
  ## Builds the webhook message body used after an automatic defer.
  commandResult.responseData()

func commandOptions(data: JsonNode): JsonNode =
  result = newJObject()
  if not data.hasKey("options") or data["options"].kind != JArray:
    return
  for option in data["options"]:
    if option.kind != JObject or not option.hasKey("name"):
      continue
    if option.hasKey("value"):
      result[option["name"].getStr()] = option["value"]
    elif option.hasKey("options"):
      # Subcommand trees are retained under their name until the command DSL
      # grows an explicit nested-group type; silently flattening is ambiguous.
      result[option["name"].getStr()] = option["options"]

proc invokingUserId(interaction: JsonNode): UserId =
  var userIdText = ""
  if interaction.hasKey("member") and interaction["member"].kind == JObject and
      interaction["member"].hasKey("user") and
      interaction["member"]["user"].kind == JObject and
      interaction["member"]["user"].hasKey("id"):
    userIdText = interaction["member"]["user"]["id"].getStr()
  elif interaction.hasKey("user") and interaction["user"].kind == JObject and
      interaction["user"].hasKey("id"):
    userIdText = interaction["user"]["id"].getStr()
  if userIdText.len == 0:
    raise newException(InteractionDecodeError, "invoking user ID is missing")
  parseId(UserId, userIdText)

proc permissionValue(interaction: JsonNode, name: string): Permissions =
  if not interaction.hasKey(name):
    return initDiscordBits[Permission]()
  if interaction[name].kind != JString:
    raise newException(InteractionDecodeError,
      "interaction " & name & " must be a decimal string")
  try:
    parsePermissions(interaction[name].getStr())
  except ValueError as error:
    raise newException(InteractionDecodeError,
      "invalid interaction " & name & ": " & error.msg)

proc invocationContext*(interaction: JsonNode): InvocationContext =
  ## Decodes installation owners, typed IDs, permissions, and visibility rules.
  if interaction.kind != JObject:
    raise newException(InteractionDecodeError,
      "interaction payload must be an object")
  result.invokingUserId = interaction.invokingUserId()

  if interaction.hasKey("guild_id") and interaction["guild_id"].kind == JString:
    result.guildId = some(parseId(GuildId, interaction["guild_id"].getStr()))

  if interaction.hasKey("context") and interaction["context"].kind == JInt:
    case interaction["context"].getInt()
    of 0: result.surface = isGuildChannel
    of 1: result.surface = isBotDm
    of 2: result.surface = isPrivateChannel
    else:
      raise newException(InteractionDecodeError,
        "unknown interaction context value")
  elif result.guildId.isSome:
    result.surface = isGuildChannel
  else:
    result.surface = isBotDm

  if interaction.hasKey("authorizing_integration_owners"):
    let owners = interaction["authorizing_integration_owners"]
    if owners.kind != JObject:
      raise newException(InteractionDecodeError,
        "authorizing_integration_owners must be an object")
    if owners.hasKey("0") and owners["0"].kind == JString:
      result.integrationOwners.add IntegrationOwner(
        kind: iiGuildInstall,
        guildId: parseId(GuildId, owners["0"].getStr())
      )
    if owners.hasKey("1") and owners["1"].kind == JString:
      result.integrationOwners.add IntegrationOwner(
        kind: iiUserInstall,
        userId: parseId(UserId, owners["1"].getStr())
      )

  result.appPermissions = interaction.permissionValue("app_permissions")
  if interaction.hasKey("member") and interaction["member"].kind == JObject and
      interaction["member"].hasKey("permissions"):
    let memberPermissions = %*{
      "permissions": interaction["member"]["permissions"]
    }
    result.memberPermissions = some(
      memberPermissions.permissionValue("permissions"))

  let userOnlyGuildInstall = result.surface == isGuildChannel and
    result.hasOwner(iiUserInstall) and not result.hasOwner(iiGuildInstall)
  let publicAllowed = not userOnlyGuildInstall or
    result.appPermissions.contains(Permission.useExternalApps)
  result.responsePolicy = ResponsePolicy(
    publicResponseAllowed: publicAllowed,
    reason: if publicAllowed:
      none(string)
    else:
      some("user-installed app lacks USE_EXTERNAL_APPS in this guild")
  )
  if result.hasOwner(iiUserInstall) and not result.hasOwner(iiGuildInstall):
    result.followupBudget = some(5)

proc commandInvocation*(interaction: JsonNode): CommandInvocation =
  ## Decodes a Discord application-command interaction into typed IDs/options.
  if interaction.kind != JObject or not interaction.hasKey("data") or
      interaction["data"].kind != JObject:
    raise newException(InteractionDecodeError,
      "interaction command data is missing")
  let data = interaction["data"]
  if not data.hasKey("name") or data["name"].kind != JString:
    raise newException(InteractionDecodeError,
      "interaction command name is missing")

  let context = interaction.invocationContext()
  result = CommandInvocation(
    name: data["name"].getStr(),
    options: data.commandOptions(),
    userId: context.invokingUserId,
    guildId: context.guildId,
    context: context,
    resolved: if data.hasKey("resolved"): data["resolved"] else: newJObject()
  )
  if data.hasKey("target_id"):
    if data["target_id"].kind != JString:
      raise newException(InteractionDecodeError,
        "context command target ID must be a string")
    let targetId = data["target_id"].getStr()
    let commandType = if data.hasKey("type") and data["type"].kind == JInt:
      data["type"].getInt()
    else:
      1
    case commandType
    of 2:
      result.target = some(CommandTarget(
        kind: ctkUser,
        targetUserId: parseId(UserId, targetId)
      ))
    of 3:
      result.target = some(CommandTarget(
        kind: ctkMessage,
        targetMessageId: parseId(MessageId, targetId)
      ))
    else:
      raise newException(InteractionDecodeError,
        "chat-input command cannot contain target_id")

proc newCommandRouter*[S](app: DiscordApp[S],
                          completionSink: DeferredCompletionSink = nil,
                          failureObserver: DeferredFailureObserver = nil):
                          CommandRouter[S] =
  ## Creates a router with a structured scope for deferred commands.
  if app.isNil:
    raise newException(ValueError, "command router requires an application")
  CommandRouter[S](
    app: app,
    tasks: newTaskScope(),
    completionSink: completionSink,
    failureObserver: failureObserver
  )

proc observedInteractionId(interaction: JsonNode): Option[InteractionId] =
  if interaction.kind != JObject:
    return none(InteractionId)
  let idNode = interaction{"id"}
  if idNode.isNil or idNode.kind != JString:
    return none(InteractionId)
  try:
    some(parseId(InteractionId, idNode.getStr()))
  except ValueError:
    none(InteractionId)

proc reportDeferredFailure[S](router: CommandRouter[S], interaction: JsonNode,
                              kind: DeferredFailureKind) =
  # Exception messages are intentionally excluded: handlers and transports may
  # embed secrets. Observability still gets a stable phase and correlation ID.
  if not router.failureObserver.isNil:
    router.failureObserver(kind, interaction.observedInteractionId())

proc completeDeferred[S](router: CommandRouter[S], interaction: JsonNode,
                         commandFuture: Future[CommandResult]): Future[void] {.
                         async: (raises: []).} =
  var commandResult: CommandResult
  try:
    commandResult = await commandFuture
  except CancelledError:
    return
  except CatchableError:
    router.reportDeferredFailure(interaction, dfkHandler)
    return

  if router.completionSink.isNil:
    return
  try:
    await router.completionSink(interaction, commandResult)
  except CancelledError:
    discard
  except CatchableError:
    router.reportDeferredFailure(interaction, dfkCompletion)

func safeInitialDelay(responder: InteractionResponder,
                      now: MonoMillis): int64 =
  max(0'i64,
    responder.remainingAckMs(now) - InitialResponseSendMarginMs)

proc route*[S](router: CommandRouter[S], interaction: JsonNode,
               receivedAt: MonoMillis): Future[JsonNode] {.async.} =
  ## Dispatches one command and applies its generated acknowledgement policy.
  let responder = newInteractionResponder(receivedAt)
  let claim = responder.beginInitial(monotonicMillis())
  if not claim.ok:
    raise newException(InteractionDecodeError,
      "interaction acknowledgement deadline already expired")

  let invocation = interaction.commandInvocation()
  let commandIndex = router.app.commands.find(invocation.name)
  if commandIndex < 0:
    if responder.remainingAckMs(monotonicMillis()) <=
        InitialResponseSendMarginMs:
      raise newDiscordError(InteractionExpiredError,
        "interaction not-found response send budget was exhausted")
    discard claim.claim.commit(irkMessage)
    return initialMessageResponse(notFound(invocation.name))
  let spec = router.app.commands.specs[commandIndex]

  let commandFuture = router.app.dispatch(invocation)
  if spec.ack == ackManual:
    if commandFuture.finished and
        responder.remainingAckMs(monotonicMillis()) >
          InitialResponseSendMarginMs:
      let commandResult = commandFuture.read()
      discard claim.claim.commit(irkMessage)
      return commandResult.initialMessageResponse()

    let timer = sleepAsync(
      responder.safeInitialDelay(monotonicMillis()).milliseconds)
    let winner = await race(FutureBase(commandFuture), FutureBase(timer))
    if winner != FutureBase(commandFuture) or
        responder.remainingAckMs(monotonicMillis()) <=
          InitialResponseSendMarginMs:
      await commandFuture.cancelAndWait()
      raise newDiscordError(InteractionExpiredError,
        "interaction initial response send budget was exhausted")
    await timer.cancelAndWait()
    let commandResult = await commandFuture
    discard claim.claim.commit(irkMessage)
    return commandResult.initialMessageResponse()

  let timerDelay = min(int64(spec.autoDeferAfterMs),
    responder.safeInitialDelay(monotonicMillis()))
  let timer = sleepAsync(timerDelay.milliseconds)
  let winner = await race(FutureBase(commandFuture), FutureBase(timer))
  let remaining = responder.remainingAckMs(monotonicMillis())
  if winner == FutureBase(commandFuture) and
      remaining > InitialResponseSendMarginMs:
    await timer.cancelAndWait()
    let commandResult = commandFuture.read()
    discard claim.claim.commit(irkMessage)
    return commandResult.initialMessageResponse()

  if winner == FutureBase(commandFuture):
    await timer.cancelAndWait()
  if remaining == 0:
    if not commandFuture.finished:
      await commandFuture.cancelAndWait()
    raise newDiscordError(InteractionExpiredError,
      "interaction acknowledgement deadline expired before auto-defer")

  discard claim.claim.commit(
    if spec.ack == ackAutoDeferUpdate: irkDeferredUpdate else: irkDeferredMessage
  )
  discard router.tasks.spawn(
    router.completeDeferred(interaction, commandFuture)
  )
  deferredMessageResponse(spec.ephemeral)

proc asHttpHandler*[S](router: CommandRouter[S]): InteractionHttpHandler =
  ## Adapts the shared router to verified HTTP ingress.
  result = proc(body: seq[byte], receivedAt: MonoMillis):
      Future[InteractionHttpResponse] {.gcsafe, raises: [].} =
    proc dispatch(): Future[InteractionHttpResponse] {.async.} =
      var bodyText = newString(body.len)
      for index, value in body:
        bodyText[index] = char(value)
      let interaction = parseJson(bodyText)
      let response =
        if interaction.kind == JObject and interaction.hasKey("type") and
            interaction["type"].kind == JInt and
            interaction["type"].getInt() == 1:
          # Discord's endpoint-validation PING is transport protocol, not an
          # application command, and must bypass the command dispatcher.
          %*{"type": 1}
        else:
          await router.route(interaction, receivedAt)
      let serialized = $response
      var bytes = newSeq[byte](serialized.len)
      for index, value in serialized:
        bytes[index] = byte(ord(value))
      return jsonInteractionResponse(bytes)
    {.cast(gcsafe).}:
      return dispatch()

proc routeGateway*[S](router: CommandRouter[S], interaction: JsonNode,
                      receivedAt: MonoMillis,
                      sender: InitialResponseSender): Future[void] {.async.} =
  ## Routes the same command model through a Gateway callback sender.
  if sender.isNil:
    raise newException(ValueError, "Gateway interaction sender is required")
  let response = await router.route(interaction, receivedAt)
  await sender(response)

proc close*[S](router: CommandRouter[S]): Future[void] {.
               async: (raises: []).} =
  ## Cancels and joins deferred command completions.
  if not router.isNil:
    await router.tasks.cancelAndJoin()
