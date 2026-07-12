import std/[atomics, json, options, strutils, unittest]

import chronos

import cordnim/[app, commands, components, interactions]
import cordnim/core/[bits, ids, permissions]
import cordnim/core/errors
import cordnim/core/secrets
import cordnim/rest/chronos_driver
import cordnim/rest/request
import cordnim/interactions/envelope {.all.}
import cordnim/interactions/router {.all.}

type RouterServices = object

var cancellationProbeStarted: Atomic[bool]
var cancellationProbeStopped: Atomic[bool]
var invalidResponseProbeStopped: Atomic[bool]
var restrictedHandlerCalled: Atomic[bool]

proc recordingSenderFactory(
    onSend: proc(response: ContextResponse) {.gcsafe, raises: [].}):
    InteractionSenderFactory =
  ## Builds a factory whose sender records each post-acknowledgement response.
  result = proc(applicationId: ApplicationId,
                token: Secret[InteractionToken]): ContextResponseSender
                {.gcsafe, raises: [].} =
    result = proc(response: ContextResponse): Future[void]
        {.gcsafe, raises: [].} =
      onSend(response)
      result = newFuture[void]("test.recording.sender")
      result.complete()

proc failingSenderFactory(): InteractionSenderFactory =
  ## Builds a factory whose sender always fails with a redacted transport error.
  result = proc(applicationId: ApplicationId,
                token: Secret[InteractionToken]): ContextResponseSender
                {.gcsafe, raises: [].} =
    result = proc(response: ContextResponse): Future[void]
        {.gcsafe, raises: [].} =
      result = newFuture[void]("test.failing.sender")
      result.fail(newException(ValueError,
        "transport detail must stay redacted"))

proc greet(ctx: CommandCtx[RouterServices], name: string):
    Future[CommandResult]
    {.async, discordCommand(
      name = "greet",
      description = "Greet one person",
      ack = ackAutoDefer,
      autoDeferAfterMs = 1_000
    ).} =
  return succeeded("Hello " & name)

proc slow(ctx: CommandCtx[RouterServices]): Future[CommandResult]
    {.async, discordCommand(
      name = "slow",
      description = "Exercise automatic deferral",
      ack = ackAutoDefer,
      autoDeferAfterMs = 0
    ).} =
  await sleepAsync(10.milliseconds)
  return succeeded("finished")

proc failingDeferred(ctx: CommandCtx[RouterServices]): Future[CommandResult]
    {.async, discordCommand(
      name = "failing_deferred",
      description = "Exercise deferred failure observation",
      ack = ackAutoDefer,
      autoDeferAfterMs = 0
    ).} =
  await sleepAsync(5.milliseconds)
  raise newException(ValueError, "handler detail must stay redacted")

proc componentReply(ctx: CommandCtx[RouterServices]): CommandResult
    {.discordCommand(
      name = "component_reply",
      description = "Return a Components V2 response"
    ).} =
  let message = v2Message:
    container:
      text "## Ready"
      actions:
        button "Continue", "continue:1"
  succeededPayload(message.toJson())

proc slowManual(ctx: CommandCtx[RouterServices]): Future[CommandResult]
    {.async, discordCommand(
      name = "slow_manual",
      description = "Miss a manual acknowledgement deadline"
    ).} =
  await sleepAsync(50.milliseconds)
  return succeeded("too late")

proc contextReply(ctx: CommandCtx[RouterServices]): Future[CommandResult]
    {.async, discordCommand(
      name = "context_reply",
      description = "Select a response through CommandCtx"
    ).} =
  await ctx.reply("selected by context")
  await sleepAsync(5.milliseconds)
  return succeeded("ignored compatibility result")

proc contextDefer(ctx: CommandCtx[RouterServices]): Future[CommandResult]
    {.async, discordCommand(
      name = "context_defer",
      description = "Wait for HTTP ACK before editing"
    ).} =
  await ctx.deferReply(visibility = vEphemeral)
  await ctx.editOriginal(%*{"content": "delivered first"})
  return succeeded("ignored compatibility result")

proc cancellationProbe(ctx: CommandCtx[RouterServices]): Future[CommandResult]
    {.async, discordCommand(
      name = "cancellation_probe",
      description = "Expose pre-ack cancellation cleanup",
      ack = ackManual
    ).} =
  discard ctx
  cancellationProbeStarted.store(true)
  try:
    await sleepAsync(30.seconds)
  finally:
    cancellationProbeStopped.store(true)
  return succeeded("unreachable")

proc invalidResponseProbe(ctx: CommandCtx[RouterServices]):
    Future[CommandResult]
    {.async, discordCommand(
      name = "invalid_response_probe",
      description = "Reject invalid response data before claiming the ack",
      ack = ackManual
    ).} =
  try:
    await ctx.reply(%*["not", "a", "message", "object"])
    await sleepAsync(30.seconds)
  finally:
    invalidResponseProbeStopped.store(true)
  return succeeded("unreachable")

proc inspectSlash(ctx: CommandCtx[RouterServices]): CommandResult
    {.discordCommand(name = "inspect", description = "Inspect a resource").} =
  succeeded("slash")

proc inspectUser(ctx: CommandCtx[RouterServices]): CommandResult
    {.discordCommand(name = "inspect", kind = ckUser).} =
  succeeded("user:" & $ctx.targetUser().get())

proc inspectMessage(ctx: CommandCtx[RouterServices]): CommandResult
    {.discordCommand(name = "inspect", kind = ckMessage).} =
  succeeded("message:" & $ctx.targetMessage().get())

proc inspectMixedCase(ctx: CommandCtx[RouterServices]): CommandResult
    {.discordCommand(name = "Inspect User", kind = ckUser).} =
  succeeded("mixed:" & $ctx.targetUser().get())

proc restricted(ctx: CommandCtx[RouterServices]): CommandResult
    {.discordCommand(
      name = "restricted",
      description = "Exercise command availability"
    ).} =
  restrictedHandlerCalled.store(true)
  succeeded("unexpected")

proc payload(): JsonNode =
  %*{
    "id": "100",
    "application_id": "200",
    "type": 2,
    "token": "not-logged",
    "context": 0,
    "guild_id": "300",
    "authorizing_integration_owners": {"0": "300"},
    "data": {
      "name": "greet",
      "type": 1,
      "options": [{"name": "name", "type": 3, "value": "Nim"}]
    },
    "user": {"id": "42"}
  }

proc slowPayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"slow"
  result["data"]["options"] = newJArray()

proc componentPayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"component_reply"
  result["data"]["options"] = newJArray()

proc slowManualPayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"slow_manual"
  result["data"]["options"] = newJArray()

proc failingDeferredPayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"failing_deferred"
  result["data"]["options"] = newJArray()

proc contextReplyPayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"context_reply"
  result["data"]["options"] = newJArray()

proc contextDeferPayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"context_defer"
  result["data"]["options"] = newJArray()

proc cancellationProbePayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"cancellation_probe"
  result["data"]["options"] = newJArray()

proc invalidResponseProbePayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"invalid_response_probe"
  result["data"]["options"] = newJArray()

proc jsonBytes(node: JsonNode): seq[byte] =
  let text = $node
  result = newSeq[byte](text.len)
  for index, value in text:
    result[index] = byte(ord(value))

proc unknownPayload(): JsonNode =
  result = payload()
  result["data"]["name"] = %"not_registered"
  result["data"]["options"] = newJArray()

proc userCommandPayload(): JsonNode =
  result = payload()
  result["data"] = %*{
    "name": "inspect_user",
    "type": 2,
    "target_id": "99",
    "resolved": {"users": {"99": {"id": "99", "username": "target"}}}
  }

proc commandPayload(name: string, kind: int, targetId = ""): JsonNode =
  result = payload()
  result["data"] = %*{
    "name": name,
    "type": kind
  }
  if targetId.len != 0:
    result["data"]["target_id"] = %targetId

suite "shared interaction router":
  test "HTTP command ingress runs through the shared dispatcher":
    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let dispatcher = newInteractionDispatcher(application)
      let response = await dispatcher.asHttpHandler()(
        payload().jsonBytes(), monotonicMillis())
      await dispatcher.close()
      var text = newString(response.body.len)
      for index, value in response.body:
        text[index] = char(value)
      return parseJson(text)
    let response = waitFor scenario()
    check response["type"].getInt() == 4
    check response["data"]["content"].getStr() == "Hello Nim"
    check response["data"]["allowed_mentions"]["parse"].len == 0

  test "Gateway command ingress runs through the shared dispatcher":
    proc sender(response: JsonNode): Future[void]
        {.gcsafe, raises: [].} =
      doAssert response.getOrDefault("data").getOrDefault("content").getStr() ==
        "Hello Nim"
      let future = newFuture[void]("test.gateway.sender")
      future.complete()
      future

    proc scenario(): Future[void] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressGateway), commandSet(greet))
      let dispatcher = newInteractionDispatcher(application)
      await dispatcher.asGatewayHandler()(payload(), monotonicMillis(), sender)
      await dispatcher.close()
    waitFor scenario()

  test "routes the same spelling by Discord command kind":
    proc scenario(): Future[seq[JsonNode]] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp),
        commandSet(inspectMessage, inspectSlash, inspectUser))
      let router = newCommandRouter(application)
      result.add await router.route(
        commandPayload("inspect", 1), monotonicMillis())
      result.add await router.route(
        commandPayload("inspect", 2, "91"), monotonicMillis())
      result.add await router.route(
        commandPayload("inspect", 3, "92"), monotonicMillis())
      await router.close()

    let responses = waitFor scenario()
    check responses[0]["data"]["content"].getStr() == "slash"
    check responses[1]["data"]["content"].getStr() == "user:91"
    check responses[2]["data"]["content"].getStr() == "message:92"

  test "routes a mixed-case context-menu command name":
    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp),
        commandSet(inspectMixedCase))
      let router = newCommandRouter(application)
      result = await router.route(
        commandPayload("Inspect User", 2, "93"), monotonicMillis())
      await router.close()

    let response = waitFor scenario()
    check response["data"]["content"].getStr() == "mixed:93"

  test "requires a target exactly for context-menu commands":
    let missingUserTarget = commandPayload("inspect", 2)
    expect InteractionDecodeError:
      discard missingUserTarget.commandInvocation()

    let missingMessageTarget = commandPayload("inspect", 3)
    expect InteractionDecodeError:
      discard missingMessageTarget.commandInvocation()

    let unexpectedSlashTarget = commandPayload("inspect", 1, "94")
    expect InteractionDecodeError:
      discard unexpectedSlashTarget.commandInvocation()

  test "rejects malformed command option containers and children":
    var wrongContainer = commandPayload("inspect", 1)
    wrongContainer["data"]["options"] = %*{"name": "value"}
    expect InteractionDecodeError:
      discard wrongContainer.commandInvocation()

    var wrongChild = commandPayload("inspect", 1)
    wrongChild["data"]["options"] = %*[1]
    expect InteractionDecodeError:
      discard wrongChild.commandInvocation()

    var wrongNested = commandPayload("inspect", 1)
    wrongNested["data"]["options"] = %*[
      {"name": "group", "options": {"name": "child"}}
    ]
    expect InteractionDecodeError:
      discard wrongNested.commandInvocation()

  test "rejects install and surface mismatches before dispatch":
    restrictedHandlerCalled.store(false)

    proc scenario(): Future[seq[JsonNode]] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(restricted))
      let router = newCommandRouter(application)

      var wrongInstall = commandPayload("restricted", 1)
      wrongInstall["authorizing_integration_owners"] = %*{"1": "42"}
      result.add await router.route(wrongInstall, monotonicMillis())

      var wrongSurface = commandPayload("restricted", 1)
      wrongSurface["context"] = %1
      result.add await router.route(wrongSurface, monotonicMillis())
      await router.close()

    let responses = waitFor scenario()
    check not restrictedHandlerCalled.load()
    for response in responses:
      check response["data"]["flags"].getInt() == 64
      check response["data"]["content"].getStr().contains("unavailable")

  test "auto-defer returns promptly and retains the completion task":
    var completed: Atomic[bool]
    completed.store(false)
    proc onSend(response: ContextResponse) {.gcsafe, raises: [].} =
      doAssert response.action == raEditOriginal
      doAssert response.body{"content"}.getStr() == "finished"
      completed.store(true)

    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(slow))
      let router = newCommandRouterWithSenderFactory(
        application, recordingSenderFactory(onSend))
      let response = await router.route(slowPayload(), monotonicMillis())
      await sleepAsync(20.milliseconds)
      await router.close()
      return response

    let response = waitFor scenario()
    check response["type"].getInt() == 5
    check completed.load()

  test "HTTP auto-defer completion waits for confirmed socket delivery":
    var completed: Atomic[bool]
    completed.store(false)
    proc onSend(response: ContextResponse) {.gcsafe, raises: [].} =
      doAssert response.action == raEditOriginal
      doAssert response.body{"content"}.getStr() == "finished"
      completed.store(true)

    proc scenario(): Future[InteractionHttpResponse] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(slow))
      let router = newCommandRouterWithSenderFactory(
        application, recordingSenderFactory(onSend))
      let handler = router.asHttpHandler()
      let response = await handler(slowPayload().jsonBytes(), monotonicMillis())
      await sleepAsync(20.milliseconds)
      doAssert not completed.load()
      response.deliveryConfirmed()
      await sleepAsync(5.milliseconds)
      doAssert completed.load()
      await router.close()
      return response

    let response = waitFor scenario()
    var text = newString(response.body.len)
    for index, value in response.body:
      text[index] = char(value)
    check parseJson(text)["type"].getInt() == 5

  test "auto-defer clamps itself to the remaining acknowledgement budget":
    var completed: Atomic[bool]
    completed.store(false)
    proc onSend(response: ContextResponse) {.gcsafe, raises: [].} =
      doAssert response.action == raEditOriginal
      doAssert response.body{"content"}.getStr() == "Hello Nim"
      completed.store(true)

    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let router = newCommandRouterWithSenderFactory(
        application, recordingSenderFactory(onSend))
      let response = await router.route(
        payload(), monotonicMillis() + -2_850'i64)
      await sleepAsync(5.milliseconds)
      await router.close()
      return response

    let response = waitFor scenario()
    check response["type"].getInt() == 5
    check completed.load()

  test "deferred handler failures reach the redacted observer":
    var observed: Atomic[int]
    observed.store(0)
    proc observer(kind: DeferredFailureKind,
                  interactionId: Option[InteractionId])
                  {.gcsafe, raises: [].} =
      if kind == dfkHandler and interactionId.isSome and
          $interactionId.get() == "100":
        observed.store(1)

    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp),
        commandSet(failingDeferred))
      let router = newCommandRouter(application,
        failureObserver = observer)
      let response = await router.route(
        failingDeferredPayload(), monotonicMillis())
      await sleepAsync(15.milliseconds)
      await router.close()
      return response

    let response = waitFor scenario()
    check response["type"].getInt() == 5
    check observed.load() == 1

  test "deferred completion failures reach the redacted observer":
    var observed: Atomic[int]
    observed.store(0)
    proc observer(kind: DeferredFailureKind,
                  interactionId: Option[InteractionId])
                  {.gcsafe, raises: [].} =
      if kind == dfkCompletion and interactionId.isSome:
        observed.store(1)

    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(slow))
      let router = newCommandRouterWithSenderFactory(
        application, failingSenderFactory(), observer)
      let response = await router.route(slowPayload(), monotonicMillis())
      await sleepAsync(20.milliseconds)
      await router.close()
      return response

    let response = waitFor scenario()
    check response["type"].getInt() == 5
    check observed.load() == 1

  test "Components V2 payloads retain their flag and secure mention default":
    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp),
        commandSet(componentReply))
      let router = newCommandRouter(application)
      let response = await router.route(componentPayload(), monotonicMillis())
      await router.close()
      return response

    let response = waitFor scenario()
    check response["type"].getInt() == 4
    check response["data"]["flags"].getInt() == ComponentsV2MessageFlag
    check response["data"]["components"][0]["type"].getInt() == 17
    check response["data"]["allowed_mentions"]["parse"].len == 0

  test "keeps installation owners separate and predicts forced visibility":
    var interaction = payload()
    interaction["context"] = %0
    interaction["guild_id"] = %"300"
    interaction["app_permissions"] = %"0"
    interaction["authorizing_integration_owners"] = %*{"1": "42"}
    let decoded = interaction.commandInvocation()
    check decoded.context.hasOwner(iiUserInstall)
    check not decoded.context.hasOwner(iiGuildInstall)
    check decoded.context.followupBudget.get() == 5
    check decoded.context.actualVisibility(true).ephemeral

    interaction["app_permissions"] = %"1125899906842624"
    let withExternalApps = interaction.commandInvocation()
    check withExternalApps.context.appPermissions.contains(
      Permission.useExternalApps)
    check not withExternalApps.context.actualVisibility(true).ephemeral

  test "HTTP ingress answers Discord PING before command decoding":
    proc scenario(): Future[InteractionHttpResponse] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let router = newCommandRouter(application)
      let handler = router.asHttpHandler()
      let response = await handler(@[
        byte '{', byte '"', byte 't', byte 'y', byte 'p', byte 'e',
        byte '"', byte ':', byte '1', byte '}'
      ], monotonicMillis())
      await router.close()
      return response

    let response = waitFor scenario()
    var text = newString(response.body.len)
    for index, value in response.body:
      text[index] = char(value)
    check parseJson(text)["type"].getInt() == 1

  test "manual acknowledgement cannot finish after the three-second deadline":
    proc scenario(): Future[bool] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(slowManual))
      let router = newCommandRouter(application)
      try:
        discard await router.route(
          slowManualPayload(), monotonicMillis() + -2_980'i64)
      except InteractionExpiredError:
        await router.close()
        return true
      await router.close()
      return false

    check waitFor scenario()

  test "not-found responses still respect the acknowledgement send margin":
    proc scenario(): Future[bool] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let router = newCommandRouter(application)
      try:
        discard await router.route(
          unknownPayload(), monotonicMillis() + -2_850'i64)
      except InteractionExpiredError:
        await router.close()
        return true
      await router.close()
      return false

    check waitFor scenario()

  test "context-menu targets are typed and resolved data stays lossless":
    let invocation = userCommandPayload().commandInvocation()
    check invocation.kind == ckUser
    check invocation.target.get().kind == ctkUser
    check $invocation.target.get().targetUserId == "99"
    check invocation.resolved["users"]["99"]["username"].getStr() == "target"

  test "Context selection owns the response and its CommandResult is ignored":
    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(contextReply))
      let router = newCommandRouter(application)
      let response = await router.route(
        contextReplyPayload(), monotonicMillis())
      await sleepAsync(10.milliseconds)
      await router.close()
      return response

    let response = waitFor scenario()
    check response["type"].getInt() == 4
    check response["data"]["content"].getStr() == "selected by context"

  test "HTTP post-ACK work waits for the socket delivery receipt":
    var edits: Atomic[int]
    edits.store(0)
    proc onSend(response: ContextResponse) {.gcsafe, raises: [].} =
      doAssert response.action == raEditOriginal
      doAssert response.body{"content"}.getStr() == "delivered first"
      edits.store(edits.load() + 1)

    proc scenario(): Future[InteractionHttpResponse] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(contextDefer))
      let router = newCommandRouterWithSenderFactory(
        application, recordingSenderFactory(onSend))
      let handler = router.asHttpHandler()
      let response = await handler(
        contextDeferPayload().jsonBytes(), monotonicMillis())
      doAssert edits.load() == 0
      doAssert not response.deliveryConfirmed.isNil
      response.deliveryConfirmed()
      await sleepAsync(5.milliseconds)
      doAssert edits.load() == 1
      await router.close()
      return response

    let response = waitFor scenario()
    var text = newString(response.body.len)
    for index, value in response.body:
      text[index] = char(value)
    let payload = parseJson(text)
    check payload["type"].getInt() == 5
    check payload["data"]["flags"].getInt() == 64

  test "cancelling response selection joins the unretained handler":
    cancellationProbeStarted.store(false)
    cancellationProbeStopped.store(false)

    proc scenario(): Future[void] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp),
        commandSet(cancellationProbe))
      let router = newCommandRouter(application)
      let handler = router.asHttpHandler()
      let pending = handler(
        cancellationProbePayload().jsonBytes(), monotonicMillis())
      while not cancellationProbeStarted.load():
        await sleepAsync(1.milliseconds)
      await pending.cancelAndWait()
      doAssert cancellationProbeStopped.load()
      await router.close()

    waitFor scenario()

  test "invalid Context payload fails before consuming response authority":
    invalidResponseProbeStopped.store(false)

    proc scenario(): Future[void] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp),
        commandSet(invalidResponseProbe))
      let router = newCommandRouter(application)
      let handler = router.asHttpHandler()
      try:
        discard await handler(
          invalidResponseProbePayload().jsonBytes(), monotonicMillis())
        doAssert false, "invalid response unexpectedly reached HTTP delivery"
      except CommandApplicationError as error:
        # The handler's invalid-response failure is redacted at the pre-ack
        # command boundary, so its detail never crosses into the transport.
        doAssert error.msg == "command application failed before acknowledgement"
      doAssert invalidResponseProbeStopped.load()
      await router.close()

    waitFor scenario()

  test "configured ingress rejects the other interaction transport":
    let httpApp = newDiscordApp(
      RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
    let httpRouter = newCommandRouter(httpApp)
    proc sender(response: JsonNode): Future[void] {.gcsafe, raises: [].} =
      discard response
      result = newFuture[void]("test.wrong-ingress")
      result.complete()
    doAssertRaises ValueError:
      waitFor httpRouter.routeGateway(payload(), monotonicMillis(), sender)
    waitFor httpRouter.close()

    let gatewayApp = newDiscordApp(
      RouterServices(), initAppConfig(ingressGateway), commandSet(greet))
    let gatewayRouter = newCommandRouter(gatewayApp)
    doAssertRaises ValueError:
      discard gatewayRouter.asHttpHandler()
    waitFor gatewayRouter.close()

  test "a retained router reference rejects every operation after close":
    proc scenario(): Future[int] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let router = newCommandRouter(application)
      await router.close()
      var rejected = 0
      try:
        discard await router.route(payload(), monotonicMillis())
      except CommandRouterClosedError:
        inc rejected
      try:
        discard await router.selectResponse(payload(), monotonicMillis())
      except CommandRouterClosedError:
        inc rejected
      # A handler obtained after close still rejects at call time.
      let handler = router.asHttpHandler()
      try:
        discard await handler(payload().jsonBytes(), monotonicMillis())
      except CommandRouterClosedError:
        inc rejected
      return rejected

    check waitFor(scenario()) == 3

  test "concurrent and repeated close share one join-safe shutdown":
    proc scenario(): Future[bool] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let router = newCommandRouter(application)
      # Both calls are issued before the first await, so they must share one
      # shutdown rather than race two cancellations of the same scope.
      let firstClose = router.close()
      let secondClose = router.close()
      await firstClose
      await secondClose
      await router.close()          # a later repeat close is still safe
      return true

    check waitFor scenario()
