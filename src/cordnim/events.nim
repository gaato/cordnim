## Application-facing typed Gateway event registration.
##
## `GatewayEventRouter` binds the semantic event decoder to the services owned
## by a `DiscordApp`. Each `onX` registration receives only the payload type for
## that event plus ingress metadata in `GatewayEventContext`. The underlying
## Gateway runtime continues to own bounded queues, ordering, backpressure,
## failure observation, and shutdown.
##
## Applications that need uncommon events can use `router.on(codec, handler)`
## with one of the exported `XEvent()` codecs. Future Discord event names reach
## `onUnknown` as `UnknownGatewayEvent`; its raw data remains an explicit,
## sensitive escape hatch.

import std/tables

import chronos

import cordnim/app
import cordnim/gateway/[dispatch_runtime, session]
import cordnim/gateway/events as gateway_events
import cordnim/models/[channel, guild, member, message, monetization, role,
  user]

export gateway_events
export guild.Guild
export member.GuildMember
export message.Message
export monetization.Entitlement, monetization.Subscription
export role.Role
export user.User

type
  GatewayEventContext*[S] = object ## Services and safe ingress metadata.
    serviceValue: ref S
    kindValue: GatewayEventKind
    eventNameValue: string
    shardIdValue: ShardId
    sequenceValue: GatewaySequence
    partitionKeyValue: uint64
    receivedAtMsValue: int64

  GatewayEventHandler*[S, T] = proc(
    context: GatewayEventContext[S]; event: T
  ): Future[void] {.closure, gcsafe, raises: [].}
    ## Asynchronous application handler for one semantic event payload.

  GatewayEventProjector[T] = proc(event: GatewayEvent): T {.
    nimcall, gcsafe, raises: [].}

  GatewayEventCodec*[T] = object ## Event identity and payload projection.
    kindValue: GatewayEventKind
    projectorValue: GatewayEventProjector[T]

  ErasedGatewayEventHandler[S] = proc(
    context: GatewayEventContext[S]; event: GatewayEvent
  ): Future[void] {.closure, gcsafe, raises: [].}

  GatewayEventRouter*[S] = ref object ## Typed handlers sharing app services.
    serviceValue: ref S
    handlers: Table[GatewayEventKind, ErasedGatewayEventHandler[S]]
    unhandled: GatewayEventHandler[S, GatewayEvent]

  ResumedEvent* = object ## Marker payload for a successful Gateway resume.

  DiscordChannel* = channel.Channel ## Channel payload without `system.Channel`
                                    ## name ambiguity.

func services*[S](context: GatewayEventContext[S]): lent S =
  ## Borrows the dependency container owned by the application.
  context.serviceValue[]

func kind*[S](context: GatewayEventContext[S]): GatewayEventKind =
  ## Returns the semantic event kind.
  context.kindValue

func eventName*[S](context: GatewayEventContext[S]): string =
  ## Returns Discord's exact dispatch event name.
  context.eventNameValue

func shardId*[S](context: GatewayEventContext[S]): ShardId =
  ## Returns the shard that received the event.
  context.shardIdValue

func sequence*[S](context: GatewayEventContext[S]): GatewaySequence =
  ## Returns the sequence used for Gateway resume accounting.
  context.sequenceValue

func partitionKey*[S](context: GatewayEventContext[S]): uint64 =
  ## Returns the ordering partition chosen by the dispatch runtime.
  context.partitionKeyValue

func receivedAtMs*[S](context: GatewayEventContext[S]): int64 =
  ## Returns the monotonic receive time captured before queue admission.
  context.receivedAtMsValue

func kind*[T](codec: GatewayEventCodec[T]): GatewayEventKind =
  ## Returns the event kind selected by a codec.
  codec.kindValue

proc newGatewayEventRouter*[S](app: DiscordApp[S]): GatewayEventRouter[S] =
  ## Creates an empty event registry sharing the application's services.
  if app.isNil:
    raise newException(ValueError,
      "Gateway event router requires an application")
  GatewayEventRouter[S](
    serviceValue: app.serviceRef(),
    handlers: initTable[GatewayEventKind, ErasedGatewayEventHandler[S]](),
  )

proc on*[S, T](router: GatewayEventRouter[S]; codec: GatewayEventCodec[T];
               handler: GatewayEventHandler[S, T]) =
  ## Registers one typed handler for a semantic event kind.
  ##
  ## Duplicate registration is rejected so application composition cannot
  ## silently replace a handler. Use one handler to call multiple application
  ## functions when fan-out is required.
  if router.isNil:
    raise newException(ValueError,
      "Gateway event router is not initialized")
  if codec.projectorValue.isNil:
    raise newException(ValueError, "Gateway event codec is not initialized")
  if handler.isNil:
    raise newException(ValueError, "Gateway event handler must not be nil")
  if router.handlers.hasKey(codec.kindValue):
    raise newException(ValueError,
      "Gateway event handler already registered for " & $codec.kindValue)

  let projector = codec.projectorValue
  router.handlers[codec.kindValue] = proc(
      context: GatewayEventContext[S]; event: GatewayEvent
  ): Future[void] {.closure, gcsafe, raises: [].} =
    proc run(): Future[void] {.async.} =
      await handler(context, projector(event))
    {.cast(gcsafe).}:
      return run()

proc onUnhandled*[S](router: GatewayEventRouter[S];
                     handler: GatewayEventHandler[S, GatewayEvent]) =
  ## Registers a fallback for decoded event kinds without a specific handler.
  if router.isNil:
    raise newException(ValueError,
      "Gateway event router is not initialized")
  if handler.isNil:
    raise newException(ValueError,
      "unhandled Gateway event handler must not be nil")
  if not router.unhandled.isNil:
    raise newException(ValueError,
      "unhandled Gateway event handler is already registered")
  router.unhandled = handler

proc asGatewayHandler*[S](router: GatewayEventRouter[S];
                          next: GatewayDispatchHandler = nil):
                          GatewayDispatchHandler =
  ## Adapts the registry to the bounded raw Gateway dispatch runtime.
  ##
  ## The selected event is decoded once in its dispatch lane. An unregistered
  ## event goes to `onUnhandled`, then to the optional raw `next` handler when
  ## no typed fallback exists. Decode and application failures remain failed
  ## futures for the runtime's redacted failure observer.
  if router.isNil:
    raise newException(ValueError,
      "Gateway event router is not initialized")
  result = proc(rawEvent: DispatchEvent): Future[void] {.
      closure, gcsafe, raises: [].} =
    proc run(): Future[void] {.async.} =
      let event = decodeGatewayEvent(rawEvent)
      let context = GatewayEventContext[S](
        serviceValue: router.serviceValue,
        kindValue: event.kind,
        eventNameValue: rawEvent.name,
        shardIdValue: event.shardId,
        sequenceValue: event.sequence,
        partitionKeyValue: event.partitionKey,
        receivedAtMsValue: event.receivedAtMs,
      )
      let handler = router.handlers.getOrDefault(event.kind)
      if not handler.isNil:
        await handler(context, event)
      elif not router.unhandled.isNil:
        await router.unhandled(context, event)
      elif not next.isNil:
        await next(rawEvent)
    {.cast(gcsafe).}:
      return run()

template defineEventRoute(
    codecName, registrationName, eventKind, Payload, payloadField: untyped
) {.dirty.} =
  proc codecName*(): GatewayEventCodec[Payload] =
    ## Returns the typed codec for this Gateway event.
    GatewayEventCodec[Payload](
      kindValue: eventKind,
      projectorValue: proc(event: GatewayEvent): Payload {.
          nimcall, gcsafe, raises: [].} =
        event.payloadField,
    )

  proc registrationName*[S](router: GatewayEventRouter[S];
                            handler: GatewayEventHandler[S, Payload]) =
    ## Registers the typed handler for this Gateway event.
    router.on(codecName(), handler)

proc resumedEvent*(): GatewayEventCodec[ResumedEvent] =
  ## Returns the typed codec for `RESUMED`.
  GatewayEventCodec[ResumedEvent](
    kindValue: gekResumed,
    projectorValue: proc(event: GatewayEvent): ResumedEvent {.
        nimcall, gcsafe, raises: [].} =
      discard event
      ResumedEvent(),
  )

proc onResumed*[S](router: GatewayEventRouter[S];
                   handler: GatewayEventHandler[S, ResumedEvent]) =
  ## Registers a handler for successful session resume.
  router.on(resumedEvent(), handler)

defineEventRoute(readyEvent, onReady, gekReady, ReadyEvent, ready)
defineEventRoute(guildCreateEvent, onGuildCreate, gekGuildCreate,
  GuildCreateEvent, guildCreate)
defineEventRoute(guildUpdateEvent, onGuildUpdate, gekGuildUpdate,
  Guild, guildUpdate)
defineEventRoute(guildDeleteEvent, onGuildDelete, gekGuildDelete,
  GuildDeleteEvent, guildDelete)
defineEventRoute(channelCreateEvent, onChannelCreate, gekChannelCreate,
  DiscordChannel, channel)
defineEventRoute(channelUpdateEvent, onChannelUpdate, gekChannelUpdate,
  DiscordChannel, channel)
defineEventRoute(channelDeleteEvent, onChannelDelete, gekChannelDelete,
  DiscordChannel, channel)
defineEventRoute(threadCreateEvent, onThreadCreate, gekThreadCreate,
  DiscordChannel, channel)
defineEventRoute(threadUpdateEvent, onThreadUpdate, gekThreadUpdate,
  DiscordChannel, channel)
defineEventRoute(threadDeleteEvent, onThreadDelete, gekThreadDelete,
  ThreadDeleteEvent, threadDelete)
defineEventRoute(guildMemberAddEvent, onGuildMemberAdd, gekGuildMemberAdd,
  GuildMemberAddEvent, memberAdded)
defineEventRoute(guildMemberUpdateEvent, onGuildMemberUpdate,
  gekGuildMemberUpdate, GuildMemberUpdateEvent, memberUpdated)
defineEventRoute(guildMemberRemoveEvent, onGuildMemberRemove,
  gekGuildMemberRemove, GuildMemberRemoveEvent, memberRemoved)
defineEventRoute(guildRoleCreateEvent, onGuildRoleCreate, gekGuildRoleCreate,
  GuildRoleEvent, guildRole)
defineEventRoute(guildRoleUpdateEvent, onGuildRoleUpdate, gekGuildRoleUpdate,
  GuildRoleEvent, guildRole)
defineEventRoute(guildRoleDeleteEvent, onGuildRoleDelete, gekGuildRoleDelete,
  GuildRoleDeleteEvent, guildRoleDelete)
defineEventRoute(messageCreateEvent, onMessageCreate, gekMessageCreate,
  Message, messageCreated)
defineEventRoute(messageUpdateEvent, onMessageUpdate, gekMessageUpdate,
  MessageUpdateEvent, messageUpdated)
defineEventRoute(messageDeleteEvent, onMessageDelete, gekMessageDelete,
  MessageDeleteEvent, messageDeleted)
defineEventRoute(messageDeleteBulkEvent, onMessageDeleteBulk,
  gekMessageDeleteBulk, MessageDeleteBulkEvent, messagesDeleted)
defineEventRoute(messageReactionAddEvent, onMessageReactionAdd,
  gekMessageReactionAdd, MessageReactionEvent, reaction)
defineEventRoute(messageReactionRemoveEvent, onMessageReactionRemove,
  gekMessageReactionRemove, MessageReactionEvent, reaction)
defineEventRoute(messageReactionRemoveAllEvent, onMessageReactionRemoveAll,
  gekMessageReactionRemoveAll, MessageReactionRemoveAllEvent,
  reactionsRemoved)
defineEventRoute(messageReactionRemoveEmojiEvent,
  onMessageReactionRemoveEmoji, gekMessageReactionRemoveEmoji,
  MessageReactionRemoveEmojiEvent, reactionEmojiRemoved)
defineEventRoute(messagePollVoteAddEvent, onMessagePollVoteAdd,
  gekMessagePollVoteAdd, MessagePollVoteEvent, pollVote)
defineEventRoute(messagePollVoteRemoveEvent, onMessagePollVoteRemove,
  gekMessagePollVoteRemove, MessagePollVoteEvent, pollVote)
defineEventRoute(webhooksUpdateEvent, onWebhooksUpdate, gekWebhooksUpdate,
  WebhooksUpdateEvent, webhooksUpdated)
defineEventRoute(entitlementCreateEvent, onEntitlementCreate,
  gekEntitlementCreate, Entitlement, entitlement)
defineEventRoute(entitlementUpdateEvent, onEntitlementUpdate,
  gekEntitlementUpdate, Entitlement, entitlement)
defineEventRoute(entitlementDeleteEvent, onEntitlementDelete,
  gekEntitlementDelete, Entitlement, entitlement)
defineEventRoute(subscriptionCreateEvent, onSubscriptionCreate,
  gekSubscriptionCreate, Subscription, subscription)
defineEventRoute(subscriptionUpdateEvent, onSubscriptionUpdate,
  gekSubscriptionUpdate, Subscription, subscription)
defineEventRoute(subscriptionDeleteEvent, onSubscriptionDelete,
  gekSubscriptionDelete, Subscription, subscription)
defineEventRoute(unknownEvent, onUnknown, gekUnknown,
  UnknownGatewayEvent, unknown)
