## Semantic model for the Discord guild resource.

import std/[json, options]

import ./common
import ./role

export common
export role

type
  VerificationLevel* = enum ## Required verification before a member may chat.
    vlNone = 0 ## No verification requirement.
    vlLow = 1 ## Verified email required.
    vlMedium = 2 ## Registered for longer than five minutes.
    vlHigh = 3 ## Guild member for longer than ten minutes.
    vlVeryHigh = 4 ## Verified phone number required.

  Guild* = object ## A decoded Discord guild.
    id*: GuildId ## Unique snowflake identity of the guild.
    name*: string ## Display name of the guild.
    icon*: Option[string] ## Icon image hash, when set.
    splash*: Option[string] ## Invite splash image hash, when set.
    discoverySplash*: Option[string] ## Discovery splash hash, when set.
    ownerId*: UserId ## Snowflake of the guild owner.
    afkChannelId*: Option[ChannelId] ## Voice channel idle members move to.
    afkTimeout*: int64 ## Seconds before an idle member is moved to AFK.
    verificationLevel*: OpenEnum[VerificationLevel, int] ## Required
                                                         ## verification level.
    defaultMessageNotifications*: int64 ## Default notification level wire value.
    explicitContentFilter*: int64 ## Explicit content filter wire value.
    roles*: seq[Role] ## Roles defined in the guild.
    features*: seq[string] ## Enabled guild feature flags.
    mfaLevel*: int64 ## Required MFA level wire value.
    systemChannelId*: Option[ChannelId] ## Channel for system messages.
    systemChannelFlags*: int64 ## System channel flag bits.
    rulesChannelId*: Option[ChannelId] ## Rules or guidelines channel.
    premiumTier*: int64 ## Server boost tier wire value.
    premiumSubscriptionCount*: Option[int64] ## Number of boosts; optional in the
                                             ## official object, so `none` when a
                                             ## context omits it.
    preferredLocale*: string ## Primary language of a community guild.
    nsfwLevel*: int64 ## Guild NSFW rating wire value.
    vanityUrlCode*: Option[string] ## Vanity invite code, when set.
    description*: Option[string] ## Community guild description, when set.
    banner*: Option[string] ## Banner image hash, when set.
    snapshot: DiscordSnapshot ## Retained decode evidence for the guild.

proc decodeGuild*(node: JsonNode): Guild =
  ## Decodes a guild using the context-neutral official object contract.
  ##
  ## Suitable for Gateway `GUILD_CREATE`/`GUILD_UPDATE` payloads, which omit the
  ## REST-only fields (`region`, `widget_enabled`, the `max_*` counts,
  ## `premium_subscription_count`, and similar). Only the fields the official
  ## Guild object always carries are required here; use `decodeGuildResponse`
  ## for the stricter pinned REST contract.
  let obj = ensureObject(node, "guild")
  result.id = decodeId(GuildId, requireField(obj, "id", "guild"), "guild.id")
  result.name = asString(requireField(obj, "name", "guild"), "guild.name")
  # These image-hash and channel fields are required by GuildResponse but
  # nullable, so their presence is enforced while `null` maps to `none`.
  result.icon = reqNullableString(obj, "icon", "guild")
  result.splash = reqNullableString(obj, "splash", "guild")
  result.discoverySplash = reqNullableString(obj, "discovery_splash", "guild")
  result.ownerId = decodeId(UserId,
    requireField(obj, "owner_id", "guild"), "guild.owner_id")
  result.afkChannelId = reqNullableId(ChannelId, obj, "afk_channel_id", "guild")
  result.afkTimeout = asInt(
    requireField(obj, "afk_timeout", "guild"), "guild.afk_timeout")
  result.verificationLevel = decodeIntEnum(VerificationLevel,
    requireField(obj, "verification_level", "guild"),
    "guild.verification_level")
  result.defaultMessageNotifications = asInt(
    requireField(obj, "default_message_notifications", "guild"),
    "guild.default_message_notifications")
  result.explicitContentFilter = asInt(
    requireField(obj, "explicit_content_filter", "guild"),
    "guild.explicit_content_filter")
  for roleNode in asArray(
      requireField(obj, "roles", "guild"), "guild.roles"):
    result.roles.add(decodeRole(roleNode))
  for index, feature in asArray(
      requireField(obj, "features", "guild"), "guild.features"):
    result.features.add(asString(feature, "guild.features[" & $index & "]"))
  result.mfaLevel = asInt(
    requireField(obj, "mfa_level", "guild"), "guild.mfa_level")
  result.systemChannelId = reqNullableId(
    ChannelId, obj, "system_channel_id", "guild")
  result.systemChannelFlags = asInt(
    requireField(obj, "system_channel_flags", "guild"),
    "guild.system_channel_flags")
  result.rulesChannelId = reqNullableId(
    ChannelId, obj, "rules_channel_id", "guild")
  result.premiumTier = asInt(
    requireField(obj, "premium_tier", "guild"), "guild.premium_tier")
  # `premium_subscription_count` is optional in the official object.
  result.premiumSubscriptionCount = optInt(
    obj, "premium_subscription_count", "guild")
  result.preferredLocale = asString(
    requireField(obj, "preferred_locale", "guild"), "guild.preferred_locale")
  result.nsfwLevel = asInt(
    requireField(obj, "nsfw_level", "guild"), "guild.nsfw_level")
  result.vanityUrlCode = reqNullableString(obj, "vanity_url_code", "guild")
  result.description = reqNullableString(obj, "description", "guild")
  result.banner = reqNullableString(obj, "banner", "guild")
  result.snapshot = initSnapshot(obj, [
    "id", "name", "icon", "splash", "discovery_splash", "owner_id",
    "afk_channel_id", "afk_timeout", "verification_level",
    "default_message_notifications", "explicit_content_filter", "roles",
    "features", "mfa_level", "system_channel_id", "system_channel_flags",
    "rules_channel_id", "premium_tier", "premium_subscription_count",
    "preferred_locale", "nsfw_level", "vanity_url_code", "description",
    "banner", "home_header", "application_id", "region", "widget_enabled",
    "widget_channel_id", "max_presences", "max_members",
    "max_stage_video_channel_users", "max_video_channel_users",
    "safety_alerts_channel_id", "public_updates_channel_id",
    "premium_progress_bar_enabled", "nsfw", "emojis", "stickers",
    "incidents_data"])

proc decodeGuildResponse*(node: JsonNode): Guild =
  ## Decodes a guild under the strict pinned `GuildResponse` contract.
  ##
  ## Layers the endpoint-specific required fields the base object treats as
  ## optional onto `decodeGuild`, enforcing presence, nullability, and JSON type
  ## so a REST payload missing `region`, `widget_enabled`, the `max_*` counts,
  ## `premium_subscription_count`, or the other required-but-unmodelled keys is
  ## rejected. Required non-null fields reject `null`; required nullable fields
  ## permit it.
  let obj = ensureObject(node, "guild")
  requireNonNull(obj, "region", "guild", {JString})
  requireNonNull(obj, "widget_enabled", "guild", {JBool})
  requireNonNull(obj, "max_members", "guild", {JInt})
  requireNonNull(obj, "max_stage_video_channel_users", "guild", {JInt})
  requireNonNull(obj, "max_video_channel_users", "guild", {JInt})
  requireNonNull(obj, "premium_subscription_count", "guild", {JInt})
  requireNonNull(obj, "premium_progress_bar_enabled", "guild", {JBool})
  requireNonNull(obj, "nsfw", "guild", {JBool})
  requireNonNull(obj, "emojis", "guild", {JArray})
  requireNonNull(obj, "stickers", "guild", {JArray})
  requireNullablePresent(obj, "home_header", "guild", {JString})
  requireNullablePresent(obj, "application_id", "guild", {JString})
  requireNullablePresent(obj, "widget_channel_id", "guild", {JString})
  requireNullablePresent(obj, "max_presences", "guild", {JInt})
  requireNullablePresent(obj, "safety_alerts_channel_id", "guild", {JString})
  requireNullablePresent(obj, "public_updates_channel_id", "guild", {JString})
  requireNullablePresent(obj, "incidents_data", "guild", {JObject})
  decodeGuild(node)

proc parseGuild*(text: string): Guild =
  ## Decodes a Discord guild (base contract) from a JSON document string.
  decodeGuild(parseJsonObject(text, "guild"))

proc parseGuildResponse*(text: string): Guild =
  ## Decodes a strict `GuildResponse` from a JSON document string.
  decodeGuildResponse(parseJsonObject(text, "guild"))

proc rawJson*(guild: Guild): JsonNode =
  ## Returns an independent deep copy of the guild's original JSON.
  rawJson(guild.snapshot)

proc unknownFields*(guild: Guild): seq[UnknownField] =
  ## Returns deep copies of guild fields not consumed by the decoder.
  unknownFields(guild.snapshot)
