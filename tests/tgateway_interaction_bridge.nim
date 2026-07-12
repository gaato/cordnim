## Gateway interaction bridge integration tests.

import std/[json, options, strutils, unittest]

import chronos

import cordnim/[app, commands, interactions]
import cordnim/app/gateway_interactions {.all.}
import cordnim/core/[errors, ids, secrets]
import cordnim/gateway/[dispatch_runtime, session]
import cordnim/interactions/dispatcher
import cordnim/rest/[chronos_driver, request]

type
  BridgeServices = object
  RestRecorder = ref object
    requests: seq[RawRequest]
    response: TransportResponse

proc unused(ctx: CommandCtx[BridgeServices]): CommandResult {.
    discordCommand(name = "unused", description = "Unused test command").} =
  succeeded("unused")

proc deferAndEdit(ctx: CommandCtx[BridgeServices]): Future[CommandResult] {.
    async, discordCommand(
      name = "defer_and_edit",
      description = "Exercise post-ACK Gateway transport"
    ).} =
  await ctx.deferReply(visibility = vEphemeral)
  await ctx.editOriginal(%*{"content": "finished"})
  return succeeded("ignored")

let bridgeCommands = commandSet(unused, deferAndEdit)

proc completedResponse(response: TransportResponse): Future[TransportResponse] =
  result = newFuture[TransportResponse]("test.gateway.callback")
  result.complete(response)

func text(data: openArray[byte]): string =
  result = newString(data.len)
  for index, value in data:
    result[index] = char(value)

func bytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for index, item in value:
    result[index] = byte(item)

proc transport(recorder: RestRecorder): RestTransport =
  result = proc(cordRequest: RawRequest): Future[TransportResponse] {.
      closure, gcsafe, raises: [].} =
    recorder.requests.add(cordRequest)
    let response =
      if recorder.response.status == 0:
        if cordRequest.route.canonical.contains("/callback"):
          TransportResponse(status: 204)
        else:
          TransportResponse(status: 200, body: bytes("{}"))
      else:
        recorder.response
    completedResponse(response)

suite "Gateway interaction bridge":
  test "routes the shared dispatcher through a token-safe callback request":
    let recorder = RestRecorder()
    let client = newChronosRestClient(recorder.transport())
    client.start()
    let application = newDiscordApp(
      BridgeServices(), initAppConfig(ingressGateway), bridgeCommands)
    let interactionDispatcher = newInteractionDispatcher(application)
    let handler = unsafeGatewayInteractionHandler(interactionDispatcher, client)
    let receivedAt = monotonicMillis()
    let event = initDispatchEvent(
      "INTERACTION_CREATE", ShardId(2), GatewaySequence(7), payload = $(%*{
        "id": "42",
        "application_id": "5",
        "token": "not-for-diagnostics",
        "type": 1
      }),
      receivedAtMs = int64(receivedAt)
    )

    waitFor handler(event)
    check recorder.requests.len == 1
    let cordRequest = recorder.requests[0]
    check cordRequest.route.canonical ==
      "POST /interactions/{interaction_id}/{interaction_token}/callback"
    check cordRequest.route.majorParameter.len == 0
    check cordRequest.meta.priority == rpInteractionAck
    check cordRequest.meta.idempotency == idNever
    check cordRequest.authRequirement == darNone
    check cordRequest.meta.deadline == some(receivedAt + 2_750'i64)
    check cordRequest.urlPath ==
      "/interactions/42/not-for-diagnostics/callback"
    check parseJson(cordRequest.body.bodyBytes().text()) == %*{"type": 1}

    waitFor interactionDispatcher.close()
    waitFor client.stop()

  test "the production sink wires post-ACK edits automatically":
    let recorder = RestRecorder()
    let client = newChronosRestClient(recorder.transport())
    client.start()
    let application = newDiscordApp(
      BridgeServices(), initAppConfig(ingressGateway), bridgeCommands)
    let interactionDispatcher = newInteractionDispatcher(application)
    let sink = gatewayInteractionSink(interactionDispatcher, client)
    let receivedAt = monotonicMillis()
    waitFor sink(%*{
      "id": "42",
      "application_id": "5",
      "token": "post-ack-secret",
      "type": 2,
      "context": 0,
      "guild_id": "9",
      "authorizing_integration_owners": {"0": "9"},
      "user": {"id": "7"},
      "data": {"name": "defer_and_edit", "type": 1, "options": []}
    }, int64(receivedAt))
    for _ in 0 ..< 50:
      if recorder.requests.len >= 2:
        break
      waitFor sleepAsync(1.milliseconds)

    check recorder.requests.len == 2
    check recorder.requests[0].urlPath ==
      "/interactions/42/post-ack-secret/callback"
    check recorder.requests[0].authRequirement == darNone
    check recorder.requests[1].urlPath ==
      "/webhooks/5/post-ack-secret/messages/@original"
    check recorder.requests[1].authRequirement == darNone
    check parseJson(recorder.requests[1].body.bodyBytes().text()) == %*{
      "content": "finished", "allowed_mentions": {"parse": []}}

    waitFor interactionDispatcher.close()
    waitFor client.stop()

  test "requires exact empty 204 callback responses":
    for response in [
        TransportResponse(status: 200),
        TransportResponse(status: 204, body: bytes("unexpected-body")),
    ]:
      let recorder = RestRecorder(response: response)
      let client = newChronosRestClient(recorder.transport())
      client.start()
      try:
        expect DecodeError:
          waitFor client.sendInteractionCallback(
            InteractionId.toId(42),
            initSecret[InteractionToken]("interaction-token"),
            %*{"type": 1},
            monotonicMillis())
      finally:
        waitFor client.stop()

  test "delegates non-interaction events":
    let recorder = RestRecorder()
    let client = newChronosRestClient(recorder.transport())
    client.start()
    let application = newDiscordApp(
      BridgeServices(), initAppConfig(ingressGateway), bridgeCommands)
    let interactionDispatcher = newInteractionDispatcher(application)
    var delegated = false
    let next: GatewayDispatchHandler = proc(event: DispatchEvent): Future[void] {.
        closure, gcsafe, raises: [].} =
      delegated = event.name == "READY"
      result = newFuture[void]("test.gateway.delegated")
      result.complete()
    let handler = unsafeGatewayInteractionHandler(
      interactionDispatcher, client, next)

    waitFor handler(initDispatchEvent(
      "READY", ShardId(0), GatewaySequence(1), payload = "{}"))
    check delegated
    check recorder.requests.len == 0

    waitFor interactionDispatcher.close()
    waitFor client.stop()

  test "fails malformed callback identity without exposing its token":
    let recorder = RestRecorder()
    let client = newChronosRestClient(recorder.transport())
    client.start()
    let application = newDiscordApp(
      BridgeServices(), initAppConfig(ingressGateway), bridgeCommands)
    let interactionDispatcher = newInteractionDispatcher(application)
    let handler = unsafeGatewayInteractionHandler(interactionDispatcher, client)
    let malformed = initDispatchEvent(
      "INTERACTION_CREATE", ShardId(3), GatewaySequence(8),
      payload = $(%*{"id": "bad", "token": "do-not-leak", "type": 1}))

    expect GatewayInteractionBridgeError:
      waitFor handler(malformed)
    check recorder.requests.len == 0

    waitFor interactionDispatcher.close()
    waitFor client.stop()
