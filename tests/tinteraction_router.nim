import std/[atomics, json, options, unittest]

import chronos

import cordnim/[app, commands, components, interactions]
import cordnim/core/[bits, ids, permissions]
import cordnim/core/errors
import cordnim/rest/chronos_driver
import cordnim/rest/request

type RouterServices = object

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

proc payload(): JsonNode =
  %*{
    "id": "100",
    "application_id": "200",
    "type": 2,
    "token": "not-logged",
    "data": {
      "name": "greet",
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

suite "shared interaction router":
  test "HTTP-style routing decodes typed command options":
    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let router = newCommandRouter(application)
      let response = await router.route(payload(), monotonicMillis())
      await router.close()
      return response
    let response = waitFor scenario()
    check response["type"].getInt() == 4
    check response["data"]["content"].getStr() == "Hello Nim"
    check response["data"]["allowed_mentions"]["parse"].len == 0

  test "Gateway ingress uses the same command dispatcher":
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
      let router = newCommandRouter(application)
      await router.routeGateway(payload(), monotonicMillis(), sender)
      await router.close()
    waitFor scenario()

  test "auto-defer returns promptly and retains the completion task":
    var completed: Atomic[bool]
    completed.store(false)
    proc sink(interaction: JsonNode,
              commandResult: CommandResult): Future[void]
              {.gcsafe, raises: [].} =
      doAssert commandResult.message == "finished"
      completed.store(true)
      let future = newFuture[void]("test.completion.sink")
      future.complete()
      future

    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(slow))
      let router = newCommandRouter(application, sink)
      let response = await router.route(slowPayload(), monotonicMillis())
      await sleepAsync(20.milliseconds)
      await router.close()
      return response

    let response = waitFor scenario()
    check response["type"].getInt() == 5
    check completed.load()

  test "auto-defer clamps itself to the remaining acknowledgement budget":
    var completed: Atomic[bool]
    completed.store(false)
    proc sink(interaction: JsonNode,
              commandResult: CommandResult): Future[void]
              {.gcsafe, raises: [].} =
      discard interaction
      doAssert commandResult.message == "Hello Nim"
      completed.store(true)
      let future = newFuture[void]("test.late-ingress.sink")
      future.complete()
      future

    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(greet))
      let router = newCommandRouter(application, sink)
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
    proc failingSink(interaction: JsonNode,
                     commandResult: CommandResult): Future[void]
                     {.gcsafe, raises: [].} =
      discard interaction
      discard commandResult
      result = newFuture[void]("test.failing-completion.sink")
      result.fail(newException(ValueError,
        "transport detail must stay redacted"))
    proc observer(kind: DeferredFailureKind,
                  interactionId: Option[InteractionId])
                  {.gcsafe, raises: [].} =
      if kind == dfkCompletion and interactionId.isSome:
        observed.store(1)

    proc scenario(): Future[JsonNode] {.async.} =
      let application = newDiscordApp(
        RouterServices(), initAppConfig(ingressHttp), commandSet(slow))
      let router = newCommandRouter(application, failingSink, observer)
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
    check invocation.target.get().kind == ctkUser
    check $invocation.target.get().targetUserId == "99"
    check invocation.resolved["users"]["99"]["username"].getStr() == "target"
