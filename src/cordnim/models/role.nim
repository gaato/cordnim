## Semantic model for the Discord guild role resource.

import std/[json, options]

import ./common

export common

type
  RoleColors* = object ## The color set painted onto a role.
    ##
    ## `primaryColor` always mirrors the role's deprecated `color`. The gradient
    ## and holographic colors are only ever non-null in guilds with the
    ## `ENHANCED_ROLE_COLORS` feature, so both are required by the object yet
    ## nullable.
    primaryColor*: int64 ## Primary color; equals the deprecated `color`.
    secondaryColor*: Option[int64] ## Gradient secondary color, when set.
    tertiaryColor*: Option[int64] ## Holographic tertiary color, when set.

  RoleTags* = object ## Metadata describing what a role is bound to.
    ##
    ## Discord encodes several of these tags as a present-`null` flag; the
    ## boolean fields report whether that flag was present.
    botId*: Option[UserId] ## Bot the role belongs to, when any.
    integrationId*: Option[IntegrationId] ## Integration the role belongs to.
    subscriptionListingId*: Option[SkuId] ## SKU the role subscription unlocks.
    premiumSubscriber*: bool ## Whether this is the guild's booster role.
    availableForPurchase*: bool ## Whether the subscription is purchasable.
    guildConnections*: bool ## Whether the role is a guild connection role.

  Role* = object ## A decoded Discord guild role.
    id*: RoleId ## Unique snowflake identity of the role.
    name*: string ## Display name of the role.
    color*: int64 ## Deprecated integer RGB color, `0` for no color.
    colors*: RoleColors ## Structured color set; `colors.primaryColor` supersedes
                        ## the deprecated `color`.
    hoist*: bool ## Whether the role is shown separately in the sidebar.
    icon*: Option[string] ## Role icon image hash, when set.
    unicodeEmoji*: Option[string] ## Role unicode emoji, when set.
    position*: int64 ## Position in the role hierarchy.
    permissions*: Permissions ## Permission bit field granted by the role.
    managed*: bool ## Whether an integration manages the role.
    mentionable*: bool ## Whether anyone may mention the role.
    tags*: Option[RoleTags] ## Binding metadata, when Discord sent any.
    flags*: int64 ## Role flag bits.
    snapshot: DiscordSnapshot ## Retained decode evidence for the role.

proc decodeRoleColors(node: JsonNode): RoleColors =
  let obj = ensureObject(node, "role.colors")
  result.primaryColor = asInt(
    requireField(obj, "primary_color", "role.colors"),
    "role.colors.primary_color")
  # `secondary_color` and `tertiary_color` are required but nullable: they are
  # only non-null in guilds with the `ENHANCED_ROLE_COLORS` feature.
  result.secondaryColor = reqNullableInt(obj, "secondary_color", "role.colors")
  result.tertiaryColor = reqNullableInt(obj, "tertiary_color", "role.colors")

proc presentNullFlag(obj: JsonNode; name, owner: string): bool =
  ## Reads a present-`null` boolean tag: absent means false, a present `null`
  ## means true, and any non-null value is a malformed payload.
  if not obj.hasKey(name):
    return false
  if obj[name].kind != JNull:
    raiseDecode(owner & " field '" & name & "' must be null when present")
  true

proc decodeRoleTags(node: JsonNode): RoleTags =
  let obj = ensureObject(node, "role.tags")
  # The id tags are optional but never nullable when present.
  result.botId = optNonNullId(UserId, obj, "bot_id", "role.tags")
  result.integrationId = optNonNullId(IntegrationId, obj, "integration_id",
    "role.tags")
  result.subscriptionListingId = optNonNullId(SkuId, obj,
    "subscription_listing_id", "role.tags")
  # These tags are `null` when present and true, and omitted when false; any
  # other value is rejected.
  result.premiumSubscriber = presentNullFlag(
    obj, "premium_subscriber", "role.tags")
  result.availableForPurchase = presentNullFlag(
    obj, "available_for_purchase", "role.tags")
  result.guildConnections = presentNullFlag(
    obj, "guild_connections", "role.tags")

proc decodeRole*(node: JsonNode): Role =
  ## Decodes a role using the context-neutral official Role object contract.
  ##
  ## `id`, `name`, `color`, `colors`, `hoist`, `position`, `permissions`,
  ## `managed`, `mentionable`, and `flags` are required; `icon` and
  ## `unicode_emoji` are optional and nullable, and `tags` is optional and
  ## non-null. Use `decodeRoleResponse` for the pinned `GuildRoleResponse` shape
  ## that additionally requires `icon` and `unicode_emoji` to be present.
  let obj = ensureObject(node, "role")
  result.id = decodeId(RoleId, requireField(obj, "id", "role"), "role.id")
  result.name = asString(requireField(obj, "name", "role"), "role.name")
  result.color = asInt(requireField(obj, "color", "role"), "role.color")
  result.colors = decodeRoleColors(requireField(obj, "colors", "role"))
  result.hoist = asBool(requireField(obj, "hoist", "role"), "role.hoist")
  # `icon` and `unicode_emoji` are optional and nullable in the base object.
  result.icon = optString(obj, "icon", "role")
  result.unicodeEmoji = optString(obj, "unicode_emoji", "role")
  result.position = asInt(
    requireField(obj, "position", "role"), "role.position")
  result.permissions = decodePermissions(
    requireField(obj, "permissions", "role"), "role.permissions")
  result.managed = asBool(requireField(obj, "managed", "role"), "role.managed")
  result.mentionable = asBool(
    requireField(obj, "mentionable", "role"), "role.mentionable")
  let tags = optionalNonNullField(obj, "tags", "role")
  if tags.isSome:
    result.tags = some(decodeRoleTags(tags.get))
  result.flags = asInt(requireField(obj, "flags", "role"), "role.flags")
  result.snapshot = initSnapshot(obj, [
    "id", "name", "color", "colors", "hoist", "icon", "unicode_emoji",
    "position", "permissions", "managed", "mentionable", "tags", "flags"])

proc decodeRoleResponse*(node: JsonNode): Role =
  ## Decodes a role under the strict pinned `GuildRoleResponse` contract.
  ##
  ## Beyond the base object this REST shape additionally requires that the
  ## nullable `icon` and `unicode_emoji` fields be present; a Gateway role that
  ## omits them decodes under `decodeRole` but is rejected here.
  let obj = ensureObject(node, "role")
  requireNullablePresent(obj, "icon", "role", {JString})
  requireNullablePresent(obj, "unicode_emoji", "role", {JString})
  decodeRole(node)

proc parseRole*(text: string): Role =
  ## Decodes a Discord role (base contract) from a JSON document string.
  decodeRole(parseJsonObject(text, "role"))

proc parseRoleResponse*(text: string): Role =
  ## Decodes a strict `GuildRoleResponse` from a JSON document string.
  decodeRoleResponse(parseJsonObject(text, "role"))

proc rawJson*(role: Role): JsonNode =
  ## Returns an independent deep copy of the role's original JSON.
  rawJson(role.snapshot)

proc unknownFields*(role: Role): seq[UnknownField] =
  ## Returns deep copies of role fields not consumed by the decoder.
  unknownFields(role.snapshot)
