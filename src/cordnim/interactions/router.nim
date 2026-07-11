## Shared command router for HTTP and Gateway interaction ingress.
##
## The transport supplies verified JSON and a completion sink. Command decoding,
## typed dispatch, acknowledgement policy, and response construction are shared.

import std/[json, options]

import chronos

import cordnim/[app, commands]
import cordnim/app/context as appcontext
import cordnim/core/[bits, ids, permissions]
import cordnim/core/errors
import cordnim/rest/chronos_driver
import cordnim/rest/request
import cordnim/runtime/task_scope
import ./[context, exchange, http_server, responder, response_codec]

const InitialResponseSendMarginMs = 250'i64
  # Reserve time for JSON serialization and the HTTP or Gateway write after the
  # router selects an initial response.

type
  InteractionDecodeError* = object of CatchableError ## Raised when a verified
    ## payload lacks required command fields.

  DeferredCompletionSink* = proc(interaction: JsonNode,
                                  result: CommandResult): Future[void]
    {.gcsafe, raises: [].} ## Edits the deferred original response after a
    ## command finishes.

  DeferredFailureKind* = enum ## Background phase that failed after an
    ## automatic defer.
    dfkHandler, ## The deferred command handler failed.
    dfkCompletion ## Editing the original deferred response failed.

  DeferredFailureObserver* = proc(kind: DeferredFailureKind,
                                  interactionId: Option[InteractionId])
    {.gcsafe, raises: [].} ## Receives redacted deferred-failure metadata for
    ## logs or metrics.

  InitialResponseSender* = proc(response: JsonNode): Future[void]
    {.gcsafe, raises: [].} ## Sends a Gateway interaction callback response.

  PostAckResponseSink* = proc(interaction: JsonNode,
                              response: ContextResponse):
                              Future[void]
    {.gcsafe, raises: [].} ## Sends an edit or follow-up after acknowledgement.

  CommandRouter*[S] = ref object ## Shared typed command router and task owner.
    app: DiscordApp[S]
    tasks: TaskScope
    completionSink: DeferredCompletionSink
    failureObserver: DeferredFailureObserver
    postAckSink: PostAckResponseSink

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
    if option.kind == JObject and option.hasKey("name"):
      if option.hasKey("value"):
        result[option["name"].getStr()] = option["value"]
      elif option.hasKey("options"):
        # Subcommand trees stay under their name until the command DSL grows an
        # explicit nested-group type; silently flattening is ambiguous.
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
      result.integrationOwners.add(IntegrationOwner(
        kind: iiGuildInstall,
        guildId: parseId(GuildId, owners["0"].getStr())
      ))
    if owners.hasKey("1") and owners["1"].kind == JString:
      result.integrationOwners.add(IntegrationOwner(
        kind: iiUserInstall,
        userId: parseId(UserId, owners["1"].getStr())
      ))

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
                          failureObserver: DeferredFailureObserver = nil,
                          postAckSink: PostAckResponseSink = nil):
                          CommandRouter[S] =
  ## Creates a router with a structured scope for deferred commands.
  if app.isNil:
    raise newException(ValueError, "command router requires an application")
  CommandRouter[S](
    app: app,
    tasks: newTaskScope(),
    completionSink: completionSink,
    failureObserver: failureObserver,
    postAckSink: postAckSink
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
                         exchange: InteractionExchange,
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
    # A selected type-5 response is not an acknowledgement until the ingress
    # transport confirms its write. Do not let the webhook PATCH overtake that
    # write or run after an ambiguous delivery.
    await exchange.deliveryReceipt()
    await router.completionSink(interaction, commandResult)
  except CancelledError:
    # Scope shutdown is an expected lifecycle event, not a handler failure.
    discard
  except CatchableError:
    router.reportDeferredFailure(interaction, dfkCompletion)

proc observeBackground[S](router: CommandRouter[S], interaction: JsonNode,
                          commandFuture: Future[CommandResult]): Future[void] {.
                          async: (raises: []).} =
  ## Retains a handler that deliberately acknowledged before it completed.
  try:
    discard await commandFuture
  except CancelledError:
    discard
  except CatchableError:
    router.reportDeferredFailure(interaction, dfkHandler)

func safeInitialDelay(responder: InteractionResponder,
                      now: MonoMillis): int64 =
  max(0'i64,
    responder.remainingAckMs(now) - InitialResponseSendMarginMs)

type SelectedInitialResponse = object
  body: JsonNode
  exchange: InteractionExchange

proc selectCommandResult(exchange: InteractionExchange,
                         commandResult: CommandResult) =
  exchange.selectInitial(ContextResponse(
    action: raReply,
    visibility: exchange.effectiveVisibility(
      if commandResult.kind in {crRejected, crInvalidOptions, crNotFound}:
        vEphemeral
      else:
        vPublic),
    body: commandResult.responseData()
  ), irkMessage)

proc selectedResponse(exchange: InteractionExchange):
                      SelectedInitialResponse =
  let response = exchange.initialResponse.read()
  SelectedInitialResponse(
    body: response.initialResponseJson(),
    exchange: exchange
  )

proc selectResponse[S](router: CommandRouter[S], interaction: JsonNode,
                       receivedAt: MonoMillis):
                       Future[SelectedInitialResponse] {.async.} =
  ## Selects an ACK body; the ingress transport confirms delivery separately.
  if router.isNil or router.app.isNil:
    raise newException(ValueError, "command router is not initialized")

  let invocation = interaction.commandInvocation()
  let responder = newInteractionResponder(receivedAt)

  proc sendPostAck(response: ContextResponse): Future[void] {.
      closure, gcsafe, raises: [CatchableError].} =
    if router.postAckSink.isNil:
      raise newException(InteractionExchangeError,
        "post-acknowledgement response transport is not configured")
    {.cast(gcsafe).}:
      return router.postAckSink(interaction, response)

  let exchange = newInteractionExchange(
    ikApplicationCommand,
    invocation.context.responsePolicy,
    responder,
    invocation.context.followupBudget,
    sendPostAck
  )
  let commandIndex = router.app.commands.find(invocation.name)
  if commandIndex < 0:
    if responder.remainingAckMs(monotonicMillis()) <=
        InitialResponseSendMarginMs:
      raise newDiscordError(InteractionExpiredError,
        "interaction not-found response send budget was exhausted")
    exchange.selectCommandResult(notFound(invocation.name))
    return exchange.selectedResponse()

  let spec = router.app.commands.specs[commandIndex]
  let context = appcontext.newContext(exchange)
  let commandFuture = router.app.dispatch(context, invocation)
  var commandRetained = false
  var timer: Future[void]

  template retainExplicitHandler() =
    discard router.tasks.spawn(
      router.observeBackground(interaction, commandFuture))
    commandRetained = true

  try:
    if spec.ack == ackManual:
      timer = sleepAsync(
        responder.safeInitialDelay(monotonicMillis()).milliseconds)
      discard await race(
        FutureBase(commandFuture), FutureBase(exchange.initialResponse),
        FutureBase(timer))

      if exchange.initialResponse.finished:
        let selected = exchange.selectedResponse()
        retainExplicitHandler()
        return selected

      if commandFuture.finished and
          responder.remainingAckMs(monotonicMillis()) >
            InitialResponseSendMarginMs:
        let commandResult = commandFuture.read()
        if exchange.initialResponse.finished:
          let selected = exchange.selectedResponse()
          retainExplicitHandler()
          return selected
        exchange.selectCommandResult(commandResult)
        return exchange.selectedResponse()

      raise newDiscordError(InteractionExpiredError,
        "interaction initial response send budget was exhausted")

    let timerDelay = min(int64(spec.autoDeferAfterMs),
      responder.safeInitialDelay(monotonicMillis()))
    timer = sleepAsync(timerDelay.milliseconds)
    discard await race(
      FutureBase(commandFuture), FutureBase(exchange.initialResponse),
      FutureBase(timer))

    if exchange.initialResponse.finished:
      let selected = exchange.selectedResponse()
      retainExplicitHandler()
      return selected

    let remaining = responder.remainingAckMs(monotonicMillis())
    if commandFuture.finished and remaining > InitialResponseSendMarginMs:
      let commandResult = commandFuture.read()
      if exchange.initialResponse.finished:
        let selected = exchange.selectedResponse()
        retainExplicitHandler()
        return selected
      exchange.selectCommandResult(commandResult)
      return exchange.selectedResponse()

    if remaining == 0:
      raise newDiscordError(InteractionExpiredError,
        "interaction acknowledgement deadline expired before auto-defer")

    try:
      exchange.selectInitial(ContextResponse(
        action: raDefer,
        visibility: exchange.effectiveVisibility(
          if spec.ephemeral: vEphemeral else: vPublic),
        body: newJNull()
      ), irkDeferredMessage)
    except InteractionExchangeError:
      # Handler and timer can become runnable in the same event-loop turn. The
      # exchange's atomic responder decides which one selected the ACK.
      if exchange.initialResponse.finished:
        let selected = exchange.selectedResponse()
        retainExplicitHandler()
        return selected
      raise

    let selected = exchange.selectedResponse()
    discard router.tasks.spawn(
      router.completeDeferred(interaction, exchange, commandFuture))
    commandRetained = true
    return selected
  finally:
    # Chronos `race` deliberately leaves losing operands running. Until a
    # handler is transferred into the router's TaskScope, this frame owns both
    # it and the acknowledgement timer on every return, exception, and cancel.
    if not timer.isNil:
      await timer.cancelAndWait()
    if not commandRetained:
      await commandFuture.cancelAndWait()

proc route*[S](router: CommandRouter[S], interaction: JsonNode,
               receivedAt: MonoMillis): Future[JsonNode] {.async.} =
  ## Selects and confirms a response for direct test/harness callers.
  ##
  ## Real HTTP ingress uses `asHttpHandler`, which confirms only after the
  ## Chronos socket write succeeds.
  let selected = await router.selectResponse(interaction, receivedAt)
  selected.exchange.confirmInitialDelivery()
  return selected.body

proc asHttpHandler*[S](router: CommandRouter[S]): InteractionHttpHandler =
  ## Adapts the shared router to verified HTTP ingress.
  if router.isNil or router.app.isNil or
      router.app.config.interactionIngress != ingressHttp:
    raise newException(ValueError,
      "HTTP interaction handler requires HTTP interaction ingress")
  result = proc(body: seq[byte], receivedAt: MonoMillis):
      Future[InteractionHttpResponse] {.gcsafe, raises: [].} =
    proc dispatch(): Future[InteractionHttpResponse] {.async.} =
      var bodyText = newString(body.len)
      for index, value in body:
        bodyText[index] = char(value)
      let interaction = parseJson(bodyText)
      if interaction.kind == JObject and interaction.hasKey("type") and
          interaction["type"].kind == JInt and
          interaction["type"].getInt() == 1:
        # Discord's endpoint-validation PING is transport protocol, not an
        # application command, and must bypass the command dispatcher.
        let serialized = $(%*{"type": 1})
        var bytes = newSeq[byte](serialized.len)
        for index, value in serialized:
          bytes[index] = byte(ord(value))
        return jsonInteractionResponse(bytes)

      let selected = await router.selectResponse(interaction, receivedAt)
      let serialized = $selected.body
      var bytes = newSeq[byte](serialized.len)
      for index, value in serialized:
        bytes[index] = byte(ord(value))

      let exchange = selected.exchange
      proc confirmDelivery() {.closure, gcsafe, raises: [].} =
        exchange.confirmInitialDelivery()
      proc markDeliveryUnknown() {.closure, gcsafe, raises: [].} =
        exchange.markInitialDeliveryUnknown()
      return jsonInteractionResponse(
        bytes,
        deliveryConfirmed = confirmDelivery,
        deliveryUnknown = markDeliveryUnknown)
    {.cast(gcsafe).}:
      return dispatch()

proc routeGateway*[S](router: CommandRouter[S], interaction: JsonNode,
                      receivedAt: MonoMillis,
                      sender: InitialResponseSender): Future[void] {.async.} =
  ## Routes the same command model through a Gateway callback sender.
  if sender.isNil:
    raise newException(ValueError, "Gateway interaction sender is required")
  if router.isNil or router.app.isNil or
      router.app.config.interactionIngress != ingressGateway:
    raise newException(ValueError,
      "Gateway interaction route requires Gateway interaction ingress")
  let selected = await router.selectResponse(interaction, receivedAt)
  try:
    await sender(selected.body)
    selected.exchange.confirmInitialDelivery()
  except CancelledError:
    selected.exchange.markInitialDeliveryUnknown()
    raise
  except CatchableError:
    selected.exchange.markInitialDeliveryUnknown()
    raise

proc close*[S](router: CommandRouter[S]): Future[void] {.
               async: (raises: []).} =
  ## Cancels and joins deferred command completions.
  if not router.isNil:
    await router.tasks.cancelAndJoin()
