## Tests for application-facing typed Gateway event registration.

import std/json

import chronos

import cordnim/[app, commands, events]
import cordnim/gateway/[dispatch_runtime, session]
import cordnim/testing/fixtures

type EventServices = object
  handled: ref int

proc unusedCommand(context: CommandCtx[EventServices]): CommandResult {.
    discordCommand(name = "unused", description = "Unused").} =
  discard context
  succeeded()

proc dispatch(envelope: JsonNode): DispatchEvent =
  initDispatchEvent(
    envelope["t"].getStr(),
    ShardId(2),
    GatewaySequence(envelope["s"].getBiggestInt()),
    partitionKey = 42,
    payload = $envelope["d"],
    receivedAtMs = 123,
  )

proc newTestRouter(counter: ref int): GatewayEventRouter[EventServices] =
  let application = newDiscordApp(
    EventServices(handled: counter),
    initAppConfig(
      ingressGateway,
      gatewaySubscriptions({giGuildMessages, giMessageContent}),
    ),
    commandSet(unusedCommand),
  )
  newGatewayEventRouter(application)

proc messageScenario(): Future[void] {.async.} =
  var counter: ref int
  new counter
  let router = newTestRouter(counter)
  let envelope = messageCreateDispatch("typed route")
  let expectedSequence = GatewaySequence(envelope["s"].getBiggestInt())
  router.onMessageCreate proc(
      context: GatewayEventContext[EventServices]; event: Message
  ): Future[void] {.async.} =
    doAssert context.kind == gekMessageCreate
    doAssert context.eventName == "MESSAGE_CREATE"
    doAssert context.shardId == ShardId(2)
    doAssert context.sequence == expectedSequence
    doAssert context.partitionKey == 42
    doAssert context.receivedAtMs == 123
    doAssert event.content == "typed route"
    inc context.services.handled[]

  await router.asGatewayHandler()(dispatch(envelope))
  doAssert counter[] == 1

proc unknownScenario(): Future[void] {.async.} =
  var counter: ref int
  new counter
  let router = newTestRouter(counter)
  router.onUnknown proc(
      context: GatewayEventContext[EventServices];
      event: UnknownGatewayEvent
  ): Future[void] {.async.} =
    doAssert context.kind == gekUnknown
    doAssert event.name == "CORDNIM_FUTURE_EVENT"
    doAssert event.rawData()["future"].getInt() == 42
    inc context.services.handled[]

  await router.asGatewayHandler()(initDispatchEvent(
    "CORDNIM_FUTURE_EVENT",
    ShardId(2),
    GatewaySequence(9),
    payload = $(%*{"future": 42}),
  ))
  doAssert counter[] == 1

proc fallbackScenario(): Future[void] {.async.} =
  var counter: ref int
  new counter
  let router = newTestRouter(counter)
  router.onUnhandled proc(
      context: GatewayEventContext[EventServices]; event: GatewayEvent
  ): Future[void] {.async.} =
    doAssert context.kind == gekResumed
    doAssert event.kind == gekResumed
    inc context.services.handled[]

  await router.asGatewayHandler()(initDispatchEvent(
    "RESUMED", ShardId(2), GatewaySequence(10), payload = "{}"))
  doAssert counter[] == 1

proc delegationScenario(): Future[void] {.async.} =
  var counter: ref int
  new counter
  let router = newTestRouter(counter)
  let next: GatewayDispatchHandler = proc(
      event: DispatchEvent
  ): Future[void] {.async, gcsafe.} =
    doAssert event.name == "RESUMED"
    inc counter[]

  await router.asGatewayHandler(next)(initDispatchEvent(
    "RESUMED", ShardId(2), GatewaySequence(11), payload = "{}"))
  doAssert counter[] == 1

block typed_message_handler:
  waitFor messageScenario()

block future_event_handler:
  waitFor unknownScenario()

block decoded_fallback_handler:
  waitFor fallbackScenario()

block raw_delegation_handler:
  waitFor delegationScenario()

block duplicate_registration_is_rejected:
  var counter: ref int
  new counter
  let router = newTestRouter(counter)
  let handler: GatewayEventHandler[EventServices, MessageDeleteEvent] = proc(
      context: GatewayEventContext[EventServices]; event: MessageDeleteEvent
  ): Future[void] {.async.} =
    discard context
    discard event
  router.onMessageDelete(handler)
  doAssertRaises ValueError:
    router.onMessageDelete(handler)

block codec_kinds_are_explicit:
  doAssert readyEvent().kind == gekReady
  doAssert guildMemberUpdateEvent().kind == gekGuildMemberUpdate
  doAssert messageReactionRemoveEmojiEvent().kind ==
    gekMessageReactionRemoveEmoji
  doAssert subscriptionDeleteEvent().kind == gekSubscriptionDelete
