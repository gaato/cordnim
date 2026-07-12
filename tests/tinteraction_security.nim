## Adversarial coverage for the interaction credential boundary.
##
## These tests assert the authority-ownership guarantees directly: the interaction
## token never appears in any handler-visible renderer, the former raw escape
## hatches no longer compile, mutating caller-owned JSON after dispatch cannot
## redirect a later request, and Gateway `INTERACTION_CREATE` ingress reaches only
## the interaction path while its correct token still reaches transport I/O.

import std/[json, jsonutils, options, strutils, unittest]

import chronos

import cordnim/[app, commands, interactions]
import cordnim/app/context as appctx
import cordnim/app/gateway_interactions
import cordnim/core/[errors, ids, secrets]
import cordnim/gateway/[dispatch_runtime, payloads, session]
import cordnim/interactions/envelope {.all.}
import cordnim/interactions/capability
import cordnim/interactions/dispatcher {.all.}
import cordnim/interactions/webhook_completion {.all.}
import cordnim/rest/[chronos_driver, request]
import cordnim/rest

const Sentinel = "SENTINEL_TOKEN_bd91"

type
  SecServices = object
  FactoryCounter = ref object
    builds: int
  RestRecorder = ref object
    requests: seq[RawRequest]

func bytesOf(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for index, item in value:
    result[index] = byte(item)

func text(data: openArray[byte]): string =
  result = newString(data.len)
  for index, value in data:
    result[index] = char(value)

proc transport(recorder: RestRecorder): RestTransport =
  result = proc(request: RawRequest): Future[TransportResponse] {.
      closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      recorder.requests.add(request)
    result = newFuture[TransportResponse]("test.security.transport")
    # A webhook edit expects a body-bearing 200; a callback expects an empty 204.
    if request.route.canonical.contains("/callback"):
      result.complete(TransportResponse(status: 204))
    else:
      result.complete(TransportResponse(status: 200, body: bytesOf("{}")))

proc commandInteraction(): JsonNode =
  %*{
    "id": "100",
    "application_id": "200",
    "token": Sentinel,
    "type": 2,
    "context": 0,
    "guild_id": "300",
    "authorizing_integration_owners": {"0": "300"},
    "user": {"id": "42"},
    "data": {"name": "greet", "type": 1, "options": []}
  }

proc unused(ctx: CommandCtx[SecServices]): CommandResult {.
    discordCommand(name = "greet", description = "n/a").} =
  for rendered in [$ctx, repr(ctx), $(%ctx), $jsonutils.toJson(ctx),
                   $ctx.invocation, repr(ctx.invocation),
                   $(%ctx.invocation), $jsonutils.toJson(ctx.invocation)]:
    doAssert Sentinel notin rendered
  succeeded("ok")

proc countingFactory(counter: FactoryCounter): InteractionSenderFactory =
  result = proc(applicationId: ApplicationId,
                token: Secret[InteractionToken]): ContextResponseSender
                {.gcsafe, raises: [].} =
    discard applicationId
    discard token
    {.cast(gcsafe).}:
      inc counter.builds
    result = proc(response: ContextResponse): Future[void]
        {.gcsafe, raises: [].} =
      discard response
      result = newFuture[void]("test.counting.sender")
      result.complete()

let secCommands = commandSet(unused)

proc runPostAck(envelope: InteractionEnvelope, client: ChronosRestClient,
                action: ResponseAction): Future[void] {.async.} =
  await envelope.postAckSender()(ContextResponse(
    action: action, visibility: vPublic, body: %*{"content": "x"}))
  await client.stop()

suite "interaction credential boundary":
  test "dispatcher forms one envelope before command handler execution":
    let counter = FactoryCounter()
    let application = newDiscordApp(
      SecServices(), initAppConfig(ingressHttp), secCommands)
    let dispatcher = newInteractionDispatcherWithSenderFactory(
      application, counter.countingFactory())
    let selected = waitFor dispatcher.dispatch(
      commandInteraction(), monotonicMillis())
    check selected.body["type"].getInt() == 4
    check counter.builds == 1
    waitFor dispatcher.close()

  test "the token never appears in snapshot renderers or its raw JSON":
    let envelope = looseInteractionEnvelope(commandInteraction())
    let snap = envelope.snapshot()
    check Sentinel notin $snap
    check Sentinel notin repr(snap)
    check Sentinel notin $(%snap)
    check Sentinel notin $(snap.toJson())
    check not snap.rawJson().hasKey("token")
    check snap.rawJson()["application_id"].getStr() == "200"
    check $snap.interactionId() == "100"
    check $snap.applicationId() == "200"

  test "raw escape hatches and token accessors do not compile":
    check not compiles(ComponentInvocation().raw)
    check not compiles(ModalInvocation().raw)
    check not compiles(InteractionSnapshot().token)
    check not compiles(InteractionSnapshot().reveal)
    check not compiles(CommandInvocation().token)
    check not compiles(CommandInvocation().raw)

  test "mutating the original JSON after dispatch cannot redirect a follow-up":
    proc scenario(): Future[RawRequest] {.async.} =
      let recorder = RestRecorder()
      let client = newChronosRestClient(recorder.transport())
      client.start()
      var interaction = commandInteraction()
      let envelope = looseInteractionEnvelope(
        interaction, interactionWebhookSenderFactory(client))

      # The caller retains and mutates the original tree after the envelope was
      # formed. Ownership has already moved into the envelope's sender.
      interaction["token"] = %"MUTATED_TOKEN"
      interaction["application_id"] = %"999"

      await envelope.postAckSender()(ContextResponse(
        action: raEditOriginal, visibility: vPublic,
        body: %*{"content": "edit"}))
      await client.stop()
      return recorder.requests[0]

    let request = waitFor scenario()
    check Sentinel in request.urlPath
    check "MUTATED_TOKEN" notin request.urlPath
    check request.urlPath.startsWith("/webhooks/200/")
    check "999" notin request.urlPath

  test "mutating a returned rawJson tree cannot alter retained authority":
    let recorder = RestRecorder()
    let client = newChronosRestClient(recorder.transport())
    client.start()
    let envelope = looseInteractionEnvelope(
      commandInteraction(), interactionWebhookSenderFactory(client))
    let snap = envelope.snapshot()

    var raw = snap.rawJson()
    raw["token"] = %"INJECTED_TOKEN"
    raw["application_id"] = %"888"
    # The snapshot's own copy is unaffected by the caller mutating the result.
    check not snap.rawJson().hasKey("token")
    check snap.rawJson()["application_id"].getStr() == "200"

    waitFor runPostAck(envelope, client, raFollowup)
    let request = recorder.requests[0]
    check Sentinel in request.urlPath
    check "INJECTED_TOKEN" notin request.urlPath
    check request.urlPath == "/webhooks/200/" & Sentinel

  test "decoder JSON cannot mutate the envelope or a later snapshot":
    let envelope = looseInteractionEnvelope(commandInteraction())
    var decoding = envelope.decodingJson()
    decoding["token"] = %"REINTRODUCED_TOKEN"
    decoding["application_id"] = %"999"
    let snap = envelope.snapshot()
    check not snap.rawJson().hasKey("token")
    check snap.rawJson()["application_id"].getStr() == "200"

  test "Context, exchange, SelectedResponse, and capabilities stay token-free":
    let recorder = RestRecorder()
    let client = newChronosRestClient(recorder.transport())
    client.start()
    let envelope = looseInteractionEnvelope(
      commandInteraction(), interactionWebhookSenderFactory(client))
    let exch = newInteractionExchange(
      ikApplicationCommand,
      ResponsePolicy(publicResponseAllowed: true),
      newInteractionResponder(monotonicMillis()),
      none(int),
      envelope.postAckSender())
    let ctx = appctx.newContext(exch)

    for rendered in [$exch, repr(exch), $(%exch), $exch.toJson(),
                     $ctx, repr(ctx), $(%ctx), $ctx.toJson()]:
      check Sentinel notin rendered

    exch.selectInitial(ContextResponse(
      action: raReply, visibility: vPublic, body: %*{"content": "hi"}))
    let selected = exch.selectedFromExchange()
    for rendered in [$selected, repr(selected), $(%selected),
                     $selected.toJson()]:
      check Sentinel notin rendered

    let capability = freshInteraction(ikApplicationCommand, monotonicMillis())
    for rendered in [$capability, repr(capability), $(%capability),
                     $capability.toJson()]:
      check Sentinel notin rendered

    var pendingSource = freshInteraction(
      ikApplicationCommand, monotonicMillis())
    var begun = beginReply(move pendingSource, monotonicMillis())
    check begun.ok
    for rendered in [$begun, repr(begun), $(%begun),
                     $jsonutils.toJson(begun)]:
      check "atomicState" notin rendered
      check "owner" notin rendered
      check "deadlines" notin rendered
    let pending = move begun.pending
    for rendered in [$pending, repr(pending), $(%pending),
                     $jsonutils.toJson(pending)]:
      check "atomicState" notin rendered
      check "owner" notin rendered
      check "deadlines" notin rendered
    waitFor client.stop()

  test "Gateway DispatchEvent diagnostics never dump the payload":
    let event = initDispatchEvent(
      "INTERACTION_CREATE", ShardId(1), GatewaySequence(3),
      payload = $(%*{"id": "100", "token": Sentinel, "type": 2}))
    check Sentinel notin $event
    check Sentinel notin repr(event)
    check Sentinel notin $(%event)
    check Sentinel notin $event.toJson()
    # The raw payload remains available at the explicit low-level boundary.
    check Sentinel in event.payload

  test "Gateway wire projections redact diagnostics but preserve wire encoding":
    let wire = %*{
      "op": 0,
      "s": 7,
      "t": "INTERACTION_CREATE",
      "d": {"id": "100", "token": Sentinel, "type": 2}
    }
    let dispatch = decodeGatewayDispatch(wire.copy())
    let payload = decodeGatewayPayload(wire.copy())
    for rendered in [$dispatch, repr(dispatch), $(%dispatch),
                     $jsonutils.toJson(dispatch),
                     $payload, repr(payload), $(%payload),
                     $jsonutils.toJson(payload)]:
      check Sentinel notin rendered
    check Sentinel in $dispatch.toJson()
    check Sentinel in $payload.toJson()

proc pingWithIdentity(): JsonNode =
  %*{"id": "100", "application_id": "200", "token": Sentinel, "type": 1}

suite "gateway interaction ingress isolation":
  setup:
    let recorder = RestRecorder()
    let client = newChronosRestClient(recorder.transport())
    client.start()
    let application = newDiscordApp(
      SecServices(), initAppConfig(ingressGateway), secCommands)
    let dispatcher = newInteractionDispatcher(application)

  teardown:
    waitFor dispatcher.close()
    waitFor client.stop()

  test "INTERACTION_CREATE reaches interaction dispatch exactly once, never next":
    var nextCalls = 0
    let next: GatewayDispatchHandler = proc(event: DispatchEvent): Future[void] {.
        closure, gcsafe, raises: [].} =
      nextCalls.inc
      result = newFuture[void]("test.next")
      result.complete()
    let handler = unsafeGatewayInteractionHandler(dispatcher, client, next)

    waitFor handler(initDispatchEvent(
      "INTERACTION_CREATE", ShardId(0), GatewaySequence(1),
      payload = $pingWithIdentity()))
    check nextCalls == 0
    check recorder.requests.len == 1

    waitFor handler(initDispatchEvent(
      "READY", ShardId(0), GatewaySequence(2), payload = "{}"))
    check nextCalls == 1
    check recorder.requests.len == 1

  test "malformed INTERACTION_CREATE fails without exposing its token":
    let handler = unsafeGatewayInteractionHandler(dispatcher, client)
    let malformed = initDispatchEvent(
      "INTERACTION_CREATE", ShardId(0), GatewaySequence(1),
      payload = $(%*{"id": "bad", "token": Sentinel, "type": 1}))
    var message = ""
    try:
      waitFor handler(malformed)
    except GatewayInteractionBridgeError as error:
      message = error.msg
    check message.len > 0
    check Sentinel notin message
    check recorder.requests.len == 0

  test "the direct shard-runner sink routes the correct token and drops noise":
    let sink = gatewayInteractionSink(dispatcher, client)
    waitFor sink(pingWithIdentity(), int64(monotonicMillis()))
    check recorder.requests.len == 1
    check recorder.requests[0].urlPath == "/interactions/100/" & Sentinel &
      "/callback"

    # A payload without a callback identity is dropped, never raised or sent.
    waitFor sink(%*{"type": 1}, int64(monotonicMillis()))
    check recorder.requests.len == 1
