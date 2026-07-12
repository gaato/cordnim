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
import ./[context, exchange, http_server, responder]
import ./dispatch_core {.all.}
import ./envelope {.all.}

export dispatch_core.SelectedResponse, dispatch_core.InteractionClass,
  dispatch_core.classify
export envelope.InteractionSnapshot

# The initial-response send margin and correlation-ID extraction are shared with
# every other interaction router through `dispatch_core`.

type
  InteractionDecodeError* = object of CatchableError ## Raised when a verified
    ## payload lacks required command fields.

  CommandApplicationError* = object of CatchableError ## Stable, redacted failure
    ## of a command handler or middleware before acknowledgement. Its message is
    ## fixed so no handler or middleware detail crosses the dispatch boundary.

  CommandRouterClosedError* = object of CatchableError ## A route, selection, or
    ## adapter call was attempted after the router began closing.

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

  CommandRouter*[S] = ref object ## Shared typed command router and task owner.
    ## One Chronos event-loop owner serializes selection, routing, and close.
    ##
    ## Post-acknowledgement authority is a capability owned by each interaction's
    ## envelope, not a payload retained by the router: the router keeps only a
    ## credential-blind `senderFactory` and never holds an interaction JsonNode
    ## past selection.
    app: DiscordApp[S]
    tasks: TaskScope
    senderFactory: InteractionSenderFactory
    failureObserver: DeferredFailureObserver
    closed: bool
    closeTask: Future[void].Raising([])

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
  if not data.hasKey("options"):
    return
  if data["options"].kind != JArray:
    raise newException(InteractionDecodeError,
      "interaction command options must be an array")
  for option in data["options"]:
    if option.kind != JObject or not option.hasKey("name") or
        option["name"].kind != JString:
      raise newException(InteractionDecodeError,
        "interaction command option is malformed")
    let hasValue = option.hasKey("value")
    let hasChildren = option.hasKey("options")
    if hasValue == hasChildren:
      raise newException(InteractionDecodeError,
        "interaction command option must contain value or options")
    let name = option["name"].getStr()
    if result.hasKey(name):
      raise newException(InteractionDecodeError,
        "interaction command option name is duplicated")
    if hasValue:
      result[name] = option["value"]
    else:
      if option["options"].kind != JArray:
        raise newException(InteractionDecodeError,
          "nested interaction command options must be an array")
      # Subcommand trees stay under their name until the command DSL grows an
      # explicit nested-group type; silently flattening is ambiguous.
      result[name] = option["options"]

proc commandKind(data: JsonNode): CommandKind =
  if not data.hasKey("type") or data["type"].kind != JInt:
    raise newException(InteractionDecodeError,
      "interaction command type is missing")
  case data["type"].getInt()
  of 1: ckChatInput
  of 2: ckUser
  of 3: ckMessage
  else:
    raise newException(InteractionDecodeError,
      "interaction command type is unsupported")

func supportsInstall(spec: CommandSpec, context: InvocationContext): bool =
  for owner in context.integrationOwners:
    case owner.kind
    of iiGuildInstall:
      if guildInstall in spec.installs:
        return true
    of iiUserInstall:
      if userInstall in spec.installs:
        return true

func supportsSurface(spec: CommandSpec, context: InvocationContext): bool =
  case context.surface
  of isGuildChannel:
    guildChannel in spec.contexts
  of isBotDm:
    botDm in spec.contexts
  of isPrivateChannel:
    privateChannel in spec.contexts

func availableIn(spec: CommandSpec, context: InvocationContext): bool =
  spec.supportsInstall(context) and spec.supportsSurface(context)

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
  if interaction.kind != JObject or not interaction.hasKey("type") or
      interaction["type"].kind != JInt or interaction["type"].getInt() != 2:
    raise newException(InteractionDecodeError,
      "interaction is not an application command")
  if not interaction.hasKey("data") or
      interaction["data"].kind != JObject:
    raise newException(InteractionDecodeError,
      "interaction command data is missing")
  let data = interaction["data"]
  if not data.hasKey("name") or data["name"].kind != JString:
    raise newException(InteractionDecodeError,
      "interaction command name is missing")

  let kind = data.commandKind()
  let context = interaction.invocationContext()
  var channelId = none(ChannelId)
  if interaction.hasKey("channel_id"):
    if interaction["channel_id"].kind != JString:
      raise newException(InteractionDecodeError,
        "interaction channel_id must be a string")
    try:
      channelId = some(parseId(
        ChannelId, interaction["channel_id"].getStr()))
    except ValueError:
      raise newException(InteractionDecodeError,
        "interaction channel_id is not a valid snowflake")
  result = CommandInvocation(
    kind: kind,
    name: data["name"].getStr(),
    options: data.commandOptions(),
    userId: context.invokingUserId,
    guildId: context.guildId,
    channelId: channelId,
    context: context,
    resolved: if data.hasKey("resolved"): data["resolved"] else: newJObject()
  )
  result.withInteractionLocales(interaction)
  case kind
  of ckChatInput:
    if data.hasKey("target_id"):
      raise newException(InteractionDecodeError,
        "chat-input command cannot contain target_id")
  of ckUser, ckMessage:
    if not data.hasKey("target_id"):
      raise newException(InteractionDecodeError,
        "context-menu command target ID is missing")
    if data["target_id"].kind != JString:
      raise newException(InteractionDecodeError,
        "context command target ID must be a string")
    let targetId = data["target_id"].getStr()
    case kind
    of ckUser:
      result.target = some(CommandTarget(
        kind: ctkUser,
        targetUserId: parseId(UserId, targetId)
      ))
    of ckMessage:
      result.target = some(CommandTarget(
        kind: ctkMessage,
        targetMessageId: parseId(MessageId, targetId)
      ))
    of ckChatInput:
      discard

proc newCommandRouterWithSenderFactory[S](
    app: DiscordApp[S],
    senderFactory: InteractionSenderFactory,
    failureObserver: DeferredFailureObserver = nil): CommandRouter[S] =
  ## Creates a router with a structured scope for deferred commands.
  ##
  ## `senderFactory` builds one immutable post-acknowledgement sender per
  ## interaction from the credentials the ingress envelope captured. The router
  ## never sees an interaction token and never retains a mutable payload.
  if app.isNil:
    raise newException(ValueError, "command router requires an application")
  CommandRouter[S](
    app: app,
    tasks: newTaskScope(),
    senderFactory: senderFactory,
    failureObserver: failureObserver
  )

proc newCommandRouter*[S](app: DiscordApp[S],
                          failureObserver: DeferredFailureObserver = nil):
                          CommandRouter[S] =
  ## Creates a credential-blind router for direct tests and custom selection.
  newCommandRouterWithSenderFactory(app, nil, failureObserver)

proc reportDeferredFailure[S](router: CommandRouter[S],
                              interactionId: Option[InteractionId],
                              kind: DeferredFailureKind) =
  # Exception messages are intentionally excluded: handlers and transports may
  # embed secrets. Observability still gets a stable phase and correlation ID.
  if not router.failureObserver.isNil:
    router.failureObserver(kind, interactionId)

proc completeDeferred[S](router: CommandRouter[S],
                         interactionId: Option[InteractionId],
                         exchange: InteractionExchange,
                         commandFuture: Future[CommandResult]): Future[void] {.
                         async: (raises: []).} =
  var commandResult: CommandResult
  try:
    commandResult = await commandFuture
  except CancelledError:
    return
  except CatchableError:
    router.reportDeferredFailure(interactionId, dfkHandler)
    return

  try:
    # A selected type-5 response is not an acknowledgement until the ingress
    # transport confirms its write. `sendAfterDelivery` waits on that receipt and
    # then uses the envelope-owned sender, so the webhook PATCH can neither
    # overtake the write nor run after an ambiguous delivery, and mutating the
    # caller's original JSON cannot redirect it.
    await exchange.sendAfterDelivery(ContextResponse(
      action: raEditOriginal,
      visibility: vPublic,
      body: commandResult.editOriginalPayload()))
  except CancelledError:
    # Scope shutdown is an expected lifecycle event, not a handler failure.
    discard
  except CatchableError:
    router.reportDeferredFailure(interactionId, dfkCompletion)

proc observeBackground[S](router: CommandRouter[S],
                          interactionId: Option[InteractionId],
                          commandFuture: Future[CommandResult]): Future[void] {.
                          async: (raises: []).} =
  ## Retains a handler that deliberately acknowledged before it completed.
  try:
    discard await commandFuture
  except CancelledError:
    discard
  except CatchableError:
    router.reportDeferredFailure(interactionId, dfkHandler)

func safeInitialDelay(responder: InteractionResponder,
                      now: MonoMillis): int64 =
  max(0'i64,
    responder.remainingAckMs(now) - InitialResponseSendMarginMs)

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
  ))

proc selectedResponse(exchange: InteractionExchange): SelectedResponse =
  exchange.selectedFromExchange()

proc ensureOpen[S](router: CommandRouter[S]) =
  if router.isNil or router.app.isNil:
    raise newException(ValueError, "command router is not initialized")
  if router.closed:
    raise newException(CommandRouterClosedError, "command router is closed")

proc commandResultOrRedact[S](router: CommandRouter[S],
                              interactionId: Option[InteractionId],
                              commandFuture: Future[CommandResult]):
                              CommandResult =
  ## Reads a finished command future's result, redacting a pre-acknowledgement
  ## handler or middleware failure.
  ##
  ## A successful result (including a deliberate rejection) is returned as-is. A
  ## failure is translated to a fixed `CommandApplicationError` and reported once
  ## to the failure observer with the handler phase, so no handler or middleware
  ## exception message crosses the dispatch boundary. `CancelledError` is
  ## preserved. The post-selection retained tails observe their own failures, so
  ## this path never reports twice.
  try:
    result = commandFuture.read()
  except CancelledError:
    raise
  except CatchableError:
    router.reportDeferredFailure(interactionId, dfkHandler)
    raise newException(CommandApplicationError,
      "command application failed before acknowledgement")

proc selectResponse[S](router: CommandRouter[S],
                        envelope: InteractionEnvelope,
                        receivedAt: MonoMillis):
                        Future[SelectedResponse] {.async.} =
  ## Selects one ACK body for a command; delivery is confirmed by the adapter.
  ##
  ## The unified `InteractionDispatcher` forms the envelope at ingress and calls
  ## this after classifying an application command, so HTTP and Gateway ingress
  ## share the exact selection, auto-defer, and retention logic. The exchange
  ## retains only the envelope's preconstructed sender; the interaction payload
  ## is decoded from the envelope's token-free copy. A handler or middleware
  ## failure before acknowledgement surfaces only as a redacted
  ## `CommandApplicationError`.
  router.ensureOpen()

  let interaction = envelope.decodingJson()
  let interactionId = envelope.observedInteractionId()
  let invocation = interaction.commandInvocation()
  let responder = newInteractionResponder(receivedAt)

  let exchange = newInteractionExchange(
    ikApplicationCommand,
    invocation.context.responsePolicy,
    responder,
    invocation.context.followupBudget,
    envelope.postAckSender()
  )
  let commandIndex = router.app.commands.find(invocation.key)
  if commandIndex < 0:
    if responder.remainingAckMs(monotonicMillis()) <=
        InitialResponseSendMarginMs:
      raise newDiscordError(InteractionExpiredError,
        "interaction not-found response send budget was exhausted")
    exchange.selectCommandResult(notFound(invocation.key))
    return exchange.selectedResponse()

  let spec = router.app.commands.specs[commandIndex]
  if not spec.availableIn(invocation.context):
    if responder.remainingAckMs(monotonicMillis()) <=
        InitialResponseSendMarginMs:
      raise newDiscordError(InteractionExpiredError,
        "interaction rejection response send budget was exhausted")
    exchange.selectCommandResult(rejected(
      "command is unavailable in this installation or interaction context"))
    return exchange.selectedResponse()

  let context = appcontext.newContext(exchange)
  let commandFuture = router.app.dispatch(context, invocation)
  let selection = exchange.waitInitialSelection()
  var commandRetained = false
  var timer: Future[void]

  template retainExplicitHandler() =
    if router.tasks.isClosed:
      await commandFuture.cancelAndWait()
    else:
      discard router.tasks.spawn(
        router.observeBackground(interactionId, commandFuture))
    commandRetained = true

  try:
    if spec.ack == ackManual:
      timer = sleepAsync(
        responder.safeInitialDelay(monotonicMillis()).milliseconds)
      discard await race(
        FutureBase(commandFuture), FutureBase(selection),
        FutureBase(timer))

      if exchange.initialResponseReady:
        let selected = exchange.selectedResponse()
        retainExplicitHandler()
        return selected

      if commandFuture.finished and
          responder.remainingAckMs(monotonicMillis()) >
            InitialResponseSendMarginMs:
        let commandResult = router.commandResultOrRedact(
          interactionId, commandFuture)
        if exchange.initialResponseReady:
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
      FutureBase(commandFuture), FutureBase(selection),
      FutureBase(timer))

    if exchange.initialResponseReady:
      let selected = exchange.selectedResponse()
      retainExplicitHandler()
      return selected

    let remaining = responder.remainingAckMs(monotonicMillis())
    if commandFuture.finished and remaining > InitialResponseSendMarginMs:
      let commandResult = router.commandResultOrRedact(
          interactionId, commandFuture)
      if exchange.initialResponseReady:
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
      ))
    except InteractionExchangeError:
      # Handler and timer can become runnable in the same event-loop turn. The
      # exchange's atomic responder decides which one selected the ACK.
      if exchange.initialResponseReady:
        let selected = exchange.selectedResponse()
        retainExplicitHandler()
        return selected
      raise

    let selected = exchange.selectedResponse()
    if router.tasks.isClosed:
      await commandFuture.cancelAndWait()
    else:
      discard router.tasks.spawn(
        router.completeDeferred(interactionId, exchange, commandFuture))
    commandRetained = true
    return selected
  finally:
    # Chronos `race` deliberately leaves losing operands running. Until a
    # handler is transferred into the router's TaskScope, this frame owns both
    # it and the acknowledgement timer on every return, exception, and cancel.
    if not timer.isNil:
      await timer.cancelAndWait()
    await selection.cancelAndWait()
    if not commandRetained:
      await commandFuture.cancelAndWait()

proc selectResponse[S](router: CommandRouter[S], interaction: JsonNode,
                        receivedAt: MonoMillis):
                        Future[SelectedResponse] {.async.} =
  ## Forms the ingress envelope for a verified payload, then selects a response.
  ##
  ## Adapters and harness callers pass raw JSON; the envelope captures the
  ## credentials and builds the post-acknowledgement sender exactly once here,
  ## before any handler runs.
  return await router.selectResponse(
    looseInteractionEnvelope(interaction, router.senderFactory), receivedAt)

proc route[S](router: CommandRouter[S], interaction: JsonNode,
               receivedAt: MonoMillis): Future[JsonNode] {.used, async.} =
  ## Selects and confirms a response for direct test/harness callers.
  ##
  ## Real HTTP ingress uses `asHttpHandler`, which confirms only after the
  ## Chronos socket write succeeds.
  let selected = await router.selectResponse(interaction, receivedAt)
  selected.confirmDelivery()
  return selected.body

proc asHttpHandler[S](router: CommandRouter[S]): UnsafeInteractionHttpHandler {.
    used.} =
  ## Adapts the shared router to verified HTTP ingress.
  if router.isNil or router.app.isNil or
      router.app.config.interactionIngress != ingressHttp:
    raise newException(ValueError,
      "HTTP interaction handler requires HTTP interaction ingress")
  result = proc(body: seq[byte], receivedAt: MonoMillis):
      Future[InteractionHttpResponse] {.gcsafe, raises: [].} =
    proc dispatch(): Future[InteractionHttpResponse] {.async.} =
      router.ensureOpen()
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

      let delivery = selected.deliveryAuthority()
      proc confirmDelivery() {.closure, gcsafe, raises: [].} =
        delivery.confirmInitialDelivery()
      proc markDeliveryUnknown() {.closure, gcsafe, raises: [].} =
        delivery.markInitialDeliveryUnknown()
      return jsonInteractionResponse(
        bytes,
        deliveryConfirmed = confirmDelivery,
        deliveryUnknown = markDeliveryUnknown)
    {.cast(gcsafe).}:
      return dispatch()

proc routeGateway[S](router: CommandRouter[S], interaction: JsonNode,
                      receivedAt: MonoMillis,
                      sender: InitialResponseSender): Future[void] {.
                      used, async.} =
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
    selected.confirmDelivery()
  except CancelledError:
    selected.markDeliveryUnknown()
    raise
  except CatchableError:
    selected.markDeliveryUnknown()
    raise

proc close*[S](router: CommandRouter[S]): Future[void] {.
               async: (raises: []).} =
  ## Cancels and joins deferred command completions. Idempotent and join-safe.
  ##
  ## The router is sealed before the first await, so concurrent or repeated
  ## `close` calls share one shutdown and observe the same result, and any later
  ## `selectResponse`, `route`, `routeGateway`, or HTTP-handler call is rejected
  ## with `CommandRouterClosedError` instead of dispatching into a closing scope.
  if router.isNil:
    return
  if not router.closed:
    router.closed = true
    router.closeTask = router.tasks.cancelAndJoin()
  if not router.closeTask.isNil:
    await router.closeTask
