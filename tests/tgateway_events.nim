import std/[json, jsonutils, options, strutils]

import chronos

import cordnim/core/[errors, fields, ids, open_enums]
import cordnim/gateway/[dispatch_runtime, events, session]
import cordnim/models/[channel, message]
import cordnim/models/scheduled_event
import cordnim/testing/fixtures

proc dispatch(name: string; data: JsonNode; sequence = 7): DispatchEvent =
  initDispatchEvent(name, ShardId(2), GatewaySequence(sequence),
    partitionKey = 42'u64, payload = $data, receivedAtMs = 123'i64)

proc dispatch(envelope: JsonNode): DispatchEvent =
  dispatch(envelope["t"].getStr(), envelope["d"],
    int(envelope["s"].getBiggestInt()))

proc roleFixture(): JsonNode =
  %*{
    "id": "41771983423143936",
    "name": "Moderators",
    "color": 3447003,
    "colors": {
      "primary_color": 3447003,
      "secondary_color": nil,
      "tertiary_color": nil,
    },
    "hoist": true,
    "position": 5,
    "permissions": "11264",
    "managed": false,
    "mentionable": true,
    "icon": nil,
    "unicode_emoji": nil,
    "flags": 0,
  }

proc memberFixture(): JsonNode =
  %*{
    "user": userFixture(),
    "nick": nil,
    "avatar": nil,
    "banner": nil,
    "roles": ["41771983423143936"],
    "joined_at": "2026-07-01T00:00:00Z",
    "premium_since": nil,
    "deaf": false,
    "mute": false,
    "flags": 0,
    "pending": false,
    "communication_disabled_until": nil,
  }

proc entitlementFixture(): JsonNode =
  %*{
    "id": "10",
    "sku_id": "11",
    "application_id": "234325234325234325",
    "user_id": "80351110224678912",
    "deleted": false,
    "starts_at": "2026-07-01T00:00:00Z",
    "ends_at": nil,
    "type": 8,
  }

proc subscriptionFixture(): JsonNode =
  %*{
    "id": "20",
    "user_id": "80351110224678912",
    "sku_ids": ["11"],
    "renewal_sku_ids": nil,
    "entitlement_ids": ["10"],
    "current_period_start": "2026-07-01T00:00:00Z",
    "current_period_end": "2026-08-01T00:00:00Z",
    "status": 0,
    "canceled_at": nil,
  }

block ready_and_available_guild_events_are_semantic:
  let ready = decodeGatewayEvent(dispatch(readyDispatch()))
  doAssert ready.kind == gekReady
  doAssert ready.shardId == ShardId(2)
  doAssert ready.sequence.toInt64 == 1
  doAssert ready.partitionKey == 42'u64
  doAssert ready.receivedAtMs == 123
  doAssert ready.ready.version == 10
  doAssert ready.ready.user.username == "cordnim_tester"
  doAssert ready.ready.guilds.len == 1
  doAssert ready.ready.guilds[0].unavailable
  doAssert ready.ready.application.id ==
    ApplicationId.parseId("234325234325234325")

  let created = decodeGatewayEvent(dispatch(guildCreateDispatch()))
  doAssert created.kind == gekGuildCreate
  doAssert not created.guildCreate.unavailable
  doAssert created.guildCreate.guild.name == "Cordnim Test Guild"
  doAssert created.guildCreate.memberCount == 2

  let unavailable = decodeGatewayEvent(dispatch("GUILD_CREATE", %*{
    "id": "290926798626357999", "unavailable": true,
  }))
  doAssert unavailable.guildCreate.unavailable
  doAssert unavailable.guildCreate.guildId ==
    GuildId.parseId("290926798626357999")

block complete_and_partial_message_events_are_distinct:
  let created = decodeGatewayEvent(dispatch(messageCreateDispatch("hello")))
  doAssert created.kind == gekMessageCreate
  doAssert created.messageCreated.content == "hello"

  var webhookEnvelope = messageCreateDispatch("from webhook")
  webhookEnvelope["d"]["webhook_id"] = %"900000000000000001"
  webhookEnvelope["d"]["author"] = %*{
    "id": "900000000000000001",
    "username": "release hook",
    "avatar": nil,
  }
  let webhookCreated = decodeGatewayEvent(dispatch(webhookEnvelope))
  doAssert webhookCreated.messageCreated.author.kind == makWebhook
  doAssert webhookCreated.messageCreated.author.webhookId ==
    WebhookId.parseId("900000000000000001")
  doAssert webhookCreated.messageCreated.author.username == "release hook"

  let updated = decodeGatewayEvent(dispatch("MESSAGE_UPDATE", %*{
    "id": "917251507530338334",
    "channel_id": "645027906669510667",
    "guild_id": "290926798626357999",
    "content": "edited",
    "edited_timestamp": nil,
    "pinned": true,
    "future_field": {"retained": true},
  }))
  doAssert updated.kind == gekMessageUpdate
  doAssert updated.messageUpdated.content.get == "edited"
  doAssert updated.messageUpdated.editedTimestamp.isNull
  doAssert updated.messageUpdated.pinned.get
  doAssert updated.messageUpdated.flags.isAbsent
  doAssert updated.messageUpdated.unknownFields()[0].name == "future_field"
  var raw = updated.messageUpdated.rawJson()
  raw["content"] = %"mutated"
  doAssert updated.messageUpdated.rawJson()["content"].getStr() == "edited"

  let webhookUpdated = decodeGatewayEvent(dispatch("MESSAGE_UPDATE", %*{
    "id": "917251507530338334",
    "channel_id": "645027906669510667",
    "webhook_id": "900000000000000001",
    "author": {
      "id": "900000000000000001",
      "username": "updated hook",
      "avatar": nil,
    },
  }))
  doAssert webhookUpdated.messageUpdated.webhookId.get ==
    WebhookId.parseId("900000000000000001")
  doAssert webhookUpdated.messageUpdated.author.get.kind == makWebhook
  doAssert webhookUpdated.messageUpdated.author.get.username == "updated hook"

block delete_reaction_and_poll_events_validate_documented_ids:
  let deleted = decodeGatewayEvent(dispatch("MESSAGE_DELETE", %*{
    "id": "917251507530338334",
    "channel_id": "645027906669510667",
  }))
  doAssert deleted.kind == gekMessageDelete
  doAssert deleted.messageDeleted.guildId.isNone

  let bulk = decodeGatewayEvent(dispatch("MESSAGE_DELETE_BULK", %*{
    "ids": ["917251507530338334", "917251507530338335"],
    "channel_id": "645027906669510667",
    "guild_id": "290926798626357999",
  }))
  doAssert bulk.messagesDeleted.ids.len == 2

  let reaction = decodeGatewayEvent(dispatch("MESSAGE_REACTION_ADD", %*{
    "user_id": "80351110224678912",
    "channel_id": "645027906669510667",
    "message_id": "917251507530338334",
    "guild_id": "290926798626357999",
    "emoji": {"id": nil, "name": "🔥", "animated": false},
    "burst": false,
    "type": 0,
  }))
  doAssert reaction.kind == gekMessageReactionAdd
  doAssert reaction.reaction.emoji.name == some("🔥")

  let vote = decodeGatewayEvent(dispatch("MESSAGE_POLL_VOTE_ADD", %*{
    "user_id": "80351110224678912",
    "channel_id": "645027906669510667",
    "message_id": "917251507530338334",
    "guild_id": "290926798626357999",
    "answer_id": 2,
  }))
  doAssert vote.kind == gekMessagePollVoteAdd
  doAssert vote.pollVote.answerId == 2

block channel_member_and_role_events_use_resource_specific_shapes:
  let channelCreated = decodeGatewayEvent(dispatch("CHANNEL_CREATE", %*{
    "id": "645027906669510667",
    "type": 0,
    "flags": 0,
    "guild_id": "290926798626357999",
    "name": "general",
    "position": 0,
  }))
  doAssert channelCreated.kind == gekChannelCreate
  doAssert channelCreated.channel.name == some("general")

  let sparseChannel = decodeGatewayEvent(dispatch("CHANNEL_UPDATE", %*{
    "id": "645027906669510667",
    "type": 0,
  }))
  doAssert sparseChannel.kind == gekChannelUpdate
  doAssert sparseChannel.channel.name.isNone

  var member = memberFixture()
  member["guild_id"] = %"290926798626357999"
  let memberAdded = decodeGatewayEvent(dispatch("GUILD_MEMBER_ADD", member))
  doAssert memberAdded.kind == gekGuildMemberAdd
  doAssert memberAdded.memberAdded.member.user.get.username == "cordnim_tester"

  let roleCreated = decodeGatewayEvent(dispatch("GUILD_ROLE_CREATE", %*{
    "guild_id": "290926798626357999",
    "role": roleFixture(),
  }))
  doAssert roleCreated.kind == gekGuildRoleCreate
  doAssert roleCreated.guildRole.role.name == "Moderators"

  let threadDeleted = decodeGatewayEvent(dispatch("THREAD_DELETE", %*{
    "id": "645027906669510668",
    "guild_id": "290926798626357999",
    "parent_id": "645027906669510667",
    "type": 11,
  }))
  doAssert threadDeleted.kind == gekThreadDelete
  doAssert threadDeleted.threadDelete.kind.knownValue == some(ctPublicThread)

block commerce_dispatches_reuse_semantic_models:
  let entitlement = decodeGatewayEvent(
    dispatch("ENTITLEMENT_UPDATE", entitlementFixture()))
  doAssert entitlement.kind == gekEntitlementUpdate
  doAssert entitlement.entitlement.id == EntitlementId.parseId("10")

block scheduled_event_dispatches_are_typed:
  let event = decodeGatewayEvent(dispatch("GUILD_SCHEDULED_EVENT_UPDATE", %*{
    "id": "90", "guild_id": "290926798626357999",
    "channel_id": "645027906669510667", "creator_id": nil,
    "name": "Meeting", "description": nil,
    "scheduled_start_time": "2027-02-22T11:00:00Z",
    "scheduled_end_time": nil, "privacy_level": 2, "status": 2,
    "entity_type": 2, "entity_id": nil, "entity_metadata": nil,
    "image": nil,
  }))
  doAssert event.kind == gekGuildScheduledEventUpdate
  doAssert event.scheduledEvent.id == ScheduledEventId.parseId("90")
  doAssert event.scheduledEvent.status.knownValue == some(sesActive)

  var guildEntitlement = entitlementFixture()
  guildEntitlement.delete("user_id")
  guildEntitlement["guild_id"] = %"290926798626357999"
  let guildOwned = decodeGatewayEvent(
    dispatch("ENTITLEMENT_CREATE", guildEntitlement))
  doAssert guildOwned.kind == gekEntitlementCreate
  doAssert guildOwned.entitlement.userId.isNone
  doAssert guildOwned.entitlement.guildId ==
    some(GuildId.parseId("290926798626357999"))

  for (eventName, expectedKind) in [
      ("SUBSCRIPTION_CREATE", gekSubscriptionCreate),
      ("SUBSCRIPTION_UPDATE", gekSubscriptionUpdate),
      ("SUBSCRIPTION_DELETE", gekSubscriptionDelete),
  ]:
    let subscription = decodeGatewayEvent(
      dispatch(eventName, subscriptionFixture()))
    doAssert subscription.kind == expectedKind
    doAssert subscription.subscription.id == SubscriptionId.parseId("20")

block interactions_are_reserved_and_unknown_events_are_safe_to_render:
  let secret = "interaction-secret-sentinel"
  doAssert not compiles((block:
    var interaction: InteractionCreateEvent
    discard interaction))
  doAssert not compiles((block:
    discard gekInteractionCreate))
  try:
    discard decodeGatewayEvent(dispatch("INTERACTION_CREATE", %*{
      "id": "846462639632127520",
      "application_id": "234325234325234325",
      "type": 2,
      "token": secret,
      "version": 1,
    }))
    doAssert false
  except DecodeError as error:
    doAssert error.msg ==
      "INTERACTION_CREATE is reserved for dedicated interaction ingress"
    doAssert secret notin error.msg

  let unknown = decodeGatewayEvent(dispatch("CORDNIM_FUTURE_EVENT", %*{
    "token": secret,
    "nested": {"value": 42},
  }))
  doAssert unknown.kind == gekUnknown
  doAssert unknown.unknown.name == "CORDNIM_FUTURE_EVENT"
  for rendered in [
      $unknown,
      repr(unknown),
      $(%unknown),
      $jsonutils.toJson(unknown),
      $unknown.unknown,
      repr(unknown.unknown),
      $(%unknown.unknown),
      $jsonutils.toJson(unknown.unknown),
  ]:
    doAssert secret notin rendered
  var unknownData = unknown.unknown.rawData()
  doAssert unknownData["token"].getStr() == secret
  unknownData["nested"]["value"] = %0
  doAssert unknown.unknown.rawData()["nested"]["value"].getInt() == 42

block malformed_known_events_fail_without_payload_values:
  doAssertRaises DecodeError:
    discard decodeGatewayEvent(dispatch("MESSAGE_DELETE_BULK", %*{
      "ids": ["1", "1"], "channel_id": "2",
    }))
  doAssertRaises DecodeError:
    discard decodeGatewayEvent(dispatch("MESSAGE_UPDATE", %*{
      "id": "1", "channel_id": "2", "content": nil,
    }))

block typed_handler_adapter_decodes_inside_the_handler_lane:
  var observed = gekUnknown
  let handler: TypedGatewayEventHandler = proc(
      event: GatewayEvent): Future[void] {.async.} =
    observed = event.kind
  let adapted = typedGatewayHandler(handler)
  waitFor adapted(dispatch("WEBHOOKS_UPDATE", %*{
    "guild_id": "290926798626357999",
    "channel_id": "645027906669510667",
  }))
  doAssert observed == gekWebhooksUpdate

block nil_typed_handler_is_rejected:
  doAssertRaises ValueError:
    discard typedGatewayHandler(nil)
