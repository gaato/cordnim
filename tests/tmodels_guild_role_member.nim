## Focused tests for the guild, role, and member models.

import std/[json, options]

import cordnim/models/guild
import cordnim/models/member

# A complete GuildRoleResponse: id, name, permissions, position, color, colors,
# hoist, managed, mentionable, icon, unicode_emoji, flags (tags optional).
proc completeRole(): JsonNode =
  %*{
    "id": "41771983423143936",
    "name": "Moderators",
    "color": 3447003,
    "colors": {"primary_color": 3447003, "secondary_color": newJNull(),
               "tertiary_color": newJNull()},
    "hoist": true,
    "position": 5,
    "permissions": "11264",
    "managed": false,
    "mentionable": true,
    "icon": newJNull(),
    "unicode_emoji": newJNull(),
    "flags": 0,
    "tags": {"bot_id": "12345", "premium_subscriber": newJNull()}}
# 11264 = viewChannel(1024) | sendMessages(2048) | manageMessages(8192).

# A complete UserResponse for embedding.
proc completeUser(id, username: string): JsonNode =
  %*{"id": id, "username": username, "discriminator": "0",
     "global_name": newJNull(), "avatar": newJNull(),
     "public_flags": 0, "flags": 0, "primary_guild": newJNull()}

# A complete GuildResponse (all 40 required keys present).
proc completeGuild(): JsonNode =
  %*{
    "id": "197038439483310086",
    "name": "Test Guild",
    "icon": newJNull(),
    "description": newJNull(),
    "home_header": newJNull(),
    "splash": newJNull(),
    "discovery_splash": newJNull(),
    "features": ["COMMUNITY", "NEWS"],
    "banner": newJNull(),
    "owner_id": "197038439483310087",
    "application_id": newJNull(),
    "region": "us-east",
    "afk_channel_id": newJNull(),
    "afk_timeout": 300,
    "system_channel_id": newJNull(),
    "system_channel_flags": 0,
    "widget_enabled": false,
    "widget_channel_id": newJNull(),
    "verification_level": 3,
    "roles": [completeRole()],
    "default_message_notifications": 1,
    "mfa_level": 1,
    "explicit_content_filter": 2,
    "max_presences": newJNull(),
    "max_members": 250000,
    "max_stage_video_channel_users": 50,
    "max_video_channel_users": 25,
    "vanity_url_code": newJNull(),
    "premium_tier": 2,
    "premium_subscription_count": 12,
    "preferred_locale": "en-US",
    "rules_channel_id": newJNull(),
    "safety_alerts_channel_id": newJNull(),
    "public_updates_channel_id": newJNull(),
    "premium_progress_bar_enabled": false,
    "nsfw": false,
    "nsfw_level": 0,
    "emojis": [],
    "stickers": [],
    "incidents_data": newJNull()}

# A complete GuildMemberResponse.
proc completeMember(): JsonNode =
  %*{
    "user": completeUser("80351110224678912", "Nelly"),
    "nick": "Nel",
    "avatar": newJNull(),
    "banner": newJNull(),
    "roles": ["11", "22"],
    "joined_at": "2026-07-01T00:00:00+00:00",
    "premium_since": newJNull(),
    "deaf": false,
    "mute": false,
    "flags": 0,
    "pending": false,
    "communication_disabled_until": newJNull()}

block decodesRoleAndTags:
  let role = decodeRole(completeRole())
  doAssert role.id.toUint64 == 41771983423143936'u64
  doAssert role.name == "Moderators"
  doAssert role.hoist
  doAssert role.mentionable
  doAssert role.icon.isNone
  doAssert role.unicodeEmoji.isNone
  doAssert role.permissions.contains(Permission.manageMessages)
  # colors is structured: primary mirrors color, the gradient colors are null.
  doAssert role.colors.primaryColor == 3447003
  doAssert role.colors.secondaryColor.isNone
  doAssert role.colors.tertiaryColor.isNone
  doAssert role.tags.isSome
  doAssert role.tags.get.botId.isSome
  doAssert role.tags.get.premiumSubscriber # present-null flag is true
  doAssert not role.tags.get.availableForPurchase # absent flag is false

block decodesRoleColorGradient:
  # A guild with ENHANCED_ROLE_COLORS sets the gradient colors to non-null.
  var gradient = completeRole()
  gradient["colors"] = %*{"primary_color": 11127295,
    "secondary_color": 16759788, "tertiary_color": 16761760}
  let role = decodeRole(gradient)
  doAssert role.colors.secondaryColor == some(16759788'i64)
  doAssert role.colors.tertiaryColor == some(16761760'i64)

block roleMissingRequiredFieldsRaise:
  # id, color, colors, hoist, position, permissions, managed, mentionable, and
  # flags are required by the base object.
  for missing in ["id", "color", "colors", "hoist", "position", "permissions",
      "managed", "mentionable", "flags"]:
    var partial = completeRole(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeRole(partial)
  # colors is required and non-null; an explicit null is rejected too, as is a
  # colors object missing its required primary/secondary/tertiary fields.
  var nullColors = completeRole(); nullColors["colors"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeRole(nullColors)
  for missing in ["primary_color", "secondary_color", "tertiary_color"]:
    var partial = completeRole(); partial["colors"].delete(missing)
    doAssertRaises DecodeError:
      discard decodeRole(partial)

block roleIconFieldsOptionalInBaseRequiredInResponse:
  # icon and unicode_emoji are optional and nullable in the base object, so a
  # Gateway role that omits them decodes; the strict response requires them.
  var noIcons = completeRole()
  noIcons.delete("icon"); noIcons.delete("unicode_emoji")
  let role = decodeRole(noIcons)
  doAssert role.icon.isNone
  doAssert role.unicodeEmoji.isNone
  for missing in ["icon", "unicode_emoji"]:
    var partial = completeRole(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeRoleResponse(partial)
  # A complete role still decodes under the strict response contract.
  doAssert decodeRoleResponse(completeRole()).name == "Moderators"

block roleTagAndFieldNullSemantics:
  # A present-null flag rejects any non-null value; the id tags reject null.
  var badFlag = completeRole()
  badFlag["tags"]["premium_subscriber"] = %true
  doAssertRaises DecodeError:
    discard decodeRole(badFlag)
  var nullBotId = completeRole()
  nullBotId["tags"]["bot_id"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeRole(nullBotId)
  # tags is optional but non-null: an explicit null is rejected.
  var nullTags = completeRole(); nullTags["tags"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeRole(nullTags)
  # A role with no tags at all still decodes.
  var noTags = completeRole(); noTags.delete("tags")
  doAssert decodeRole(noTags).tags.isNone

block decodesGuildWithRoles:
  let guild = decodeGuild(completeGuild())
  doAssert guild.id.toUint64 == 197038439483310086'u64
  doAssert guild.name == "Test Guild"
  doAssert guild.icon.isNone
  doAssert guild.ownerId.toUint64 == 197038439483310087'u64
  doAssert guild.afkTimeout == 300
  doAssert guild.verificationLevel.knownValue == some(vlHigh)
  doAssert guild.roles.len == 1
  doAssert guild.roles[0].name == "Moderators"
  doAssert guild.features == @["COMMUNITY", "NEWS"]
  doAssert guild.preferredLocale == "en-US"
  doAssert guild.premiumSubscriptionCount == some(12'i64)

block unknownVerificationLevelPreserved:
  var payload = completeGuild()
  payload["verification_level"] = %99
  let guild = decodeGuild(payload)
  doAssert guild.verificationLevel.knownValue.isNone
  doAssert guild.verificationLevel.toRaw == 99

block guildBaseAcceptsGatewayResponseRejects:
  # The base decoder accepts a Gateway guild missing the REST-only fields; the
  # strict response decoder rejects each such omission.
  var gateway = completeGuild()
  for k in ["region", "widget_enabled", "max_members", "max_presences",
      "max_stage_video_channel_users", "max_video_channel_users",
      "premium_subscription_count"]:
    gateway.delete(k)
  let guild = decodeGuild(gateway)
  doAssert guild.name == "Test Guild"
  doAssert guild.premiumSubscriptionCount.isNone # absence, not zero
  for missing in ["region", "widget_enabled", "max_members", "emojis",
      "stickers", "incidents_data", "premium_subscription_count"]:
    var partial = completeGuild(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeGuildResponse(partial)
  # A complete GuildResponse still decodes under the strict contract.
  doAssert decodeGuildResponse(completeGuild()).premiumSubscriptionCount ==
    some(12'i64)

block guildMissingBaseRequiredFieldsRaise:
  # Fields the official object always carries are required by both decoders.
  for missing in ["owner_id", "icon", "name", "roles", "afk_timeout"]:
    var partial = completeGuild(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeGuild(partial)

block decodesMemberResponseWithUser:
  let member = decodeGuildMemberResponse(completeMember())
  doAssert member.user.isSome
  doAssert member.user.get.username == "Nelly"
  doAssert member.nick == some("Nel")
  doAssert member.avatar.isNone
  doAssert member.roles.len == 2
  doAssert member.joinedAt.get.iso8601 == "2026-07-01T00:00:00+00:00"
  doAssert member.premiumSince.isNone
  doAssert member.communicationDisabledUntil.isNone
  doAssert member.pending == some(false)
  doAssert not member.deaf

block baseMemberAcceptsGatewayProjection:
  # A MESSAGE_CREATE member omits user and pending; a guest's joined_at is null.
  let member = decodeGuildMember(%*{
    "roles": ["11"], "joined_at": newJNull(),
    "deaf": false, "mute": false, "flags": 0})
  doAssert member.user.isNone
  doAssert member.pending.isNone
  doAssert member.joinedAt.isNone # null joined_at (guest) maps to none
  doAssert member.roles.len == 1
  # The base decoder still requires the always-present fields.
  doAssertRaises DecodeError:
    discard decodeGuildMember(%*{"deaf": false, "mute": false, "flags": 0})

block memberResponseMissingRequiredFieldsRaise:
  # The strict response requires a non-null user and the presence of banner,
  # pending, joined_at, premium_since, and communication_disabled_until.
  for missing in ["user", "banner", "pending", "communication_disabled_until",
      "joined_at", "premium_since"]:
    var partial = completeMember(); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeGuildMemberResponse(partial)
  var nullUser = completeMember(); nullUser["user"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeGuildMemberResponse(nullUser)
  # The base decoder accepts the same payload once user/pending are dropped.
  var lenient = completeMember()
  for k in ["user", "pending", "banner", "communication_disabled_until"]:
    lenient.delete(k)
  doAssert decodeGuildMember(lenient).user.isNone

block memberBannerProjectionAndNullableFields:
  # banner is an optional nullable guild banner hash; a present hash projects.
  var withBanner = completeMember()
  withBanner["banner"] = %"abc123"
  doAssert decodeGuildMemberResponse(withBanner).banner == some("abc123")
  # A null banner (the completeMember default) maps to none.
  doAssert decodeGuildMemberResponse(completeMember()).banner.isNone

block memberOptionalNonNullFieldsRejectExplicitNull:
  # user, permissions, and pending are optional but non-null: an explicit null
  # is a malformed payload rather than an omitted field.
  var nullUser = completeMember(); nullUser["user"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeGuildMember(nullUser)
  var nullPending = completeMember(); nullPending["pending"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeGuildMember(nullPending)
  var nullPerms = completeMember(); nullPerms["permissions"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeGuildMember(nullPerms)
  # permissions, when a non-null string, decodes into the member.
  var withPerms = completeMember(); withPerms["permissions"] = %"2048"
  doAssert decodeGuildMember(withPerms).permissions.isSome
