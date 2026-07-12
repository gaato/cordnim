## Semantic models for Discord entitlements and SKU subscriptions.

import std/[json, options, sets]

import ./common

type
  EntitlementType* = enum ## Entitlement classifications known by Discord.
    etPurchase = 1
    etPremiumSubscription = 2
    etDeveloperGift = 3
    etTestModePurchase = 4
    etFreePurchase = 5
    etUserGift = 6
    etPremiumPurchase = 7
    etApplicationSubscription = 8
    etQuestReward = 10

  EntitlementOwnerType* = enum ## Owner accepted by test entitlement creation.
    eotGuild = 1
    eotUser = 2

  EntitlementFulfillmentStatus* = enum ## Tenant fulfillment state.
    efsUnknown = 0
    efsNotNeeded = 1
    efsNeeded = 2
    efsFulfilled = 3
    efsFailed = 4
    efsUnfulfillmentNeeded = 5
    efsUnfulfilled = 6
    efsUnfulfillmentFailed = 7

  SubscriptionStatus* = enum ## Subscription states known by the schema.
    ssActive = 0
    ssEnding = 1
    ssInactive = 2

  Entitlement* = object ## One application entitlement returned by Discord.
    id*: EntitlementId ## Entitlement snowflake.
    skuId*: SkuId ## SKU to which access was granted.
    applicationId*: ApplicationId ## Application that owns the SKU.
    userId*: Option[UserId] ## User receiving access, when user-scoped.
    guildId*: Option[GuildId] ## Guild receiving access, when guild-scoped.
    deleted*: bool ## Whether Discord deleted the entitlement.
    startsAt*: Option[Timestamp] ## Beginning of its validity window, if any.
    endsAt*: Option[Timestamp] ## End of its validity window, if any.
    kind*: OpenEnum[EntitlementType, int] ## Exact entitlement type value.
    fulfilledAt*: Option[Timestamp] ## Time fulfillment completed, if known.
    fulfillmentStatus*: Option[OpenEnum[EntitlementFulfillmentStatus, int]]
      ## Tenant fulfillment state, when this entitlement uses fulfillment.
    consumed*: Option[bool] ## Whether a consumable entitlement was consumed.
    gifterUserId*: Option[UserId] ## User that gifted this entitlement, if any.
    parentId*: Option[EntitlementId] ## Parent entitlement, when derived.
    snapshot: DiscordSnapshot

  Subscription* = object ## One SKU subscription returned by Discord.
    id*: SubscriptionId ## Subscription snowflake.
    userId*: UserId ## User that owns the subscription.
    skuIds*: seq[SkuId] ## SKUs included in the current period.
    renewalSkuIds*: Option[seq[SkuId]] ## SKUs selected for renewal, if known.
    entitlementIds*: seq[EntitlementId] ## Entitlements granted by this record.
    currentPeriodStart*: Timestamp ## Inclusive start of the current period.
    currentPeriodEnd*: Timestamp ## Exclusive end of the current period.
    status*: OpenEnum[SubscriptionStatus, int] ## Exact lifecycle status.
    canceledAt*: Option[Timestamp] ## Cancellation time, if canceled.
    country*: Option[string] ## ISO country code associated with the payment.
    snapshot: DiscordSnapshot

  EntitlementGrant* = object ## Valid test-entitlement creation payload.
    skuIdValue: SkuId
    ownerIdValue: string
    ownerTypeValue: EntitlementOwnerType

proc validateGrant(grant: EntitlementGrant) =
  if grant.skuIdValue.toUint64 == 0:
    raise newDiscordError(ValidationError,
      "test entitlement SKU ID must not be zero")
  if grant.ownerIdValue.len == 0:
    raise newDiscordError(ValidationError,
      "test entitlement owner ID must not be empty")
  let ownerKind = ord(grant.ownerTypeValue)
  if ownerKind notin [ord(eotGuild), ord(eotUser)]:
    raise newDiscordError(ValidationError,
      "test entitlement owner type is invalid")
  try:
    let ownerId = parseId[UserKind](grant.ownerIdValue)
    if ownerId.toUint64 == 0:
      raise newException(ValueError, "owner ID must not be zero")
  except ValueError as error:
    raise newDiscordError(ValidationError,
      "test entitlement owner ID is invalid: " & error.msg)

proc decodeUniqueIds[Kind](idType: typedesc[Id[Kind]]; node: JsonNode;
                           context: string): seq[Id[Kind]] =
  var seen = initHashSet[Id[Kind]]()
  for item in asArray(node, context):
    let value = decodeId(idType, item, context & "[]")
    if value in seen:
      raiseDecode(context & " must not contain duplicate IDs")
    seen.incl(value)
    result.add(value)

proc decodeEntitlement*(node: JsonNode): Entitlement =
  ## Decodes the current Discord Entitlement Object.
  ##
  ## Discord may omit either owner and the validity window. Use
  ## `decodeEntitlementResponse` when validating the stricter pinned schema.
  let obj = ensureObject(node, "entitlement")
  result.id = decodeId(EntitlementId,
    requireField(obj, "id", "entitlement"), "entitlement.id")
  result.skuId = decodeId(SkuId,
    requireField(obj, "sku_id", "entitlement"), "entitlement.sku_id")
  result.applicationId = decodeId(ApplicationId,
    requireField(obj, "application_id", "entitlement"),
    "entitlement.application_id")
  result.userId = optNonNullId(UserId, obj, "user_id", "entitlement")
  result.guildId = optNonNullId(GuildId, obj, "guild_id", "entitlement")
  result.deleted = asBool(requireField(obj, "deleted", "entitlement"),
    "entitlement.deleted")
  # General entitlement objects carry nullable validity bounds; test
  # entitlements are partial objects that omit both fields entirely.
  result.startsAt = optTimestamp(obj, "starts_at", "entitlement")
  result.endsAt = optTimestamp(obj, "ends_at", "entitlement")
  result.kind = decodeIntEnum(EntitlementType,
    requireField(obj, "type", "entitlement"), "entitlement.type")
  result.fulfilledAt = optTimestamp(obj, "fulfilled_at", "entitlement")
  if obj.hasKey("fulfillment_status") and
      obj["fulfillment_status"].kind != JNull:
    result.fulfillmentStatus = some(decodeIntEnum(
      EntitlementFulfillmentStatus, obj["fulfillment_status"],
      "entitlement.fulfillment_status"))
  result.consumed = optNonNullBool(obj, "consumed", "entitlement")
  result.gifterUserId = optId(UserId, obj, "gifter_user_id", "entitlement")
  result.parentId = optId(EntitlementId, obj, "parent_id", "entitlement")
  result.snapshot = initSnapshot(obj, [
    "id", "sku_id", "application_id", "user_id", "guild_id", "deleted",
    "starts_at", "ends_at", "type", "fulfilled_at", "fulfillment_status",
    "consumed", "gifter_user_id", "parent_id",
  ])

proc decodeEntitlementResponse*(node: JsonNode): Entitlement =
  ## Decodes the stricter EntitlementResponse in the pinned OpenAPI snapshot.
  let obj = ensureObject(node, "entitlement response")
  discard decodeId(UserId,
    requireField(obj, "user_id", "entitlement response"),
    "entitlement response.user_id")
  requireNullablePresent(
    obj, "starts_at", "entitlement response", {JString})
  requireNullablePresent(
    obj, "ends_at", "entitlement response", {JString})
  decodeEntitlement(obj)

proc parseEntitlement*(text: string): Entitlement =
  ## Parses an encoded Discord Entitlement Object.
  decodeEntitlement(parseJsonObject(text, "entitlement"))

proc rawJson*(entitlement: Entitlement): JsonNode =
  ## Returns an owned copy of the entitlement response.
  rawJson(entitlement.snapshot)

proc unknownFields*(entitlement: Entitlement): seq[UnknownField] =
  ## Returns owned copies of properties this projection did not consume.
  unknownFields(entitlement.snapshot)

proc decodeSubscription*(node: JsonNode): Subscription =
  ## Decodes a pinned `SubscriptionResponse`.
  let obj = ensureObject(node, "subscription")
  result.id = decodeId(SubscriptionId,
    requireField(obj, "id", "subscription"), "subscription.id")
  result.userId = decodeId(UserId,
    requireField(obj, "user_id", "subscription"), "subscription.user_id")
  result.skuIds = decodeUniqueIds(SkuId,
    requireField(obj, "sku_ids", "subscription"), "subscription.sku_ids")
  let renewal = requireNullable(obj, "renewal_sku_ids", "subscription")
  if renewal.isSome:
    result.renewalSkuIds = some(decodeUniqueIds(SkuId, renewal.get,
      "subscription.renewal_sku_ids"))
  result.entitlementIds = decodeUniqueIds(EntitlementId,
    requireField(obj, "entitlement_ids", "subscription"),
    "subscription.entitlement_ids")
  result.currentPeriodStart = decodeTimestamp(requireField(obj,
    "current_period_start", "subscription"),
    "subscription.current_period_start")
  result.currentPeriodEnd = decodeTimestamp(requireField(obj,
    "current_period_end", "subscription"),
    "subscription.current_period_end")
  result.status = decodeIntEnum(SubscriptionStatus,
    requireField(obj, "status", "subscription"), "subscription.status")
  result.canceledAt = reqNullableTimestamp(
    obj, "canceled_at", "subscription")
  result.country = optNonNullString(obj, "country", "subscription")
  result.snapshot = initSnapshot(obj, [
    "id", "user_id", "sku_ids", "renewal_sku_ids", "entitlement_ids",
    "current_period_start", "current_period_end", "status", "canceled_at",
    "country",
  ])

proc parseSubscription*(text: string): Subscription =
  ## Parses an encoded `SubscriptionResponse`.
  decodeSubscription(parseJsonObject(text, "subscription"))

proc rawJson*(subscription: Subscription): JsonNode =
  ## Returns an owned copy of the subscription response.
  rawJson(subscription.snapshot)

proc unknownFields*(subscription: Subscription): seq[UnknownField] =
  ## Returns owned copies of properties this projection did not consume.
  unknownFields(subscription.snapshot)

proc entitlementForUser*(skuId: SkuId; userId: UserId): EntitlementGrant =
  ## Builds a test entitlement grant for a user.
  result = EntitlementGrant(
    skuIdValue: skuId,
    ownerIdValue: $userId,
    ownerTypeValue: eotUser,
  )
  result.validateGrant()

proc entitlementForGuild*(skuId: SkuId; guildId: GuildId): EntitlementGrant =
  ## Builds a test entitlement grant for a guild.
  result = EntitlementGrant(
    skuIdValue: skuId,
    ownerIdValue: $guildId,
    ownerTypeValue: eotGuild,
  )
  result.validateGrant()

func skuId*(grant: EntitlementGrant): SkuId =
  ## Returns the SKU receiving the test entitlement.
  grant.skuIdValue

func ownerType*(grant: EntitlementGrant): EntitlementOwnerType =
  ## Returns whether the grant targets a guild or a user.
  grant.ownerTypeValue

proc toJson*(grant: EntitlementGrant): JsonNode =
  ## Serializes a valid `CreateEntitlementRequestData` payload.
  grant.validateGrant()
  %*{
    "sku_id": $grant.skuIdValue,
    "owner_id": grant.ownerIdValue,
    "owner_type": ord(grant.ownerTypeValue),
  }
