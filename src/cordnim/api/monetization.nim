## Semantic entitlement and SKU-subscription REST operations.

import std/[options, sets]

import chronos

import cordnim/api/internal/execute
import cordnim/api/options
import cordnim/core/ids
import cordnim/models/monetization
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/[applications as application_routes,
  skus as sku_routes, users as user_routes]
import cordnim/rest/chronos_driver
import cordnim/rest/request

type
  EntitlementQuery* = object ## Filters and pagination for application grants.
    userIdValue: Option[UserId]
    skuIdsValue: seq[SkuId]
    guildIdValue: Option[GuildId]
    beforeValue: Option[EntitlementId]
    afterValue: Option[EntitlementId]
    limitValue: Option[int]
    excludeEndedValue: Option[bool]
    excludeDeletedValue: Option[bool]
    onlyActiveValue: Option[bool]

  CurrentUserEntitlementQuery* = object ## Current-user entitlement filters.
    skuIdsValue: seq[SkuId]
    excludeConsumedValue: Option[bool]

  SubscriptionQuery* = object ## Pagination and user filter for subscriptions.
    beforeValue: Option[SubscriptionId]
    afterValue: Option[SubscriptionId]
    limitValue: Option[int]
    userIdValue: Option[UserId]

proc uniqueSkuIds(values: openArray[SkuId]): seq[SkuId] =
  if values.len > 100:
    raise newException(ValueError, "SKU filter must not exceed 100 IDs")
  var seen = initHashSet[SkuId]()
  for value in values:
    if value in seen:
      raise newException(ValueError, "SKU filter must not contain duplicates")
    seen.incl(value)
    result.add(value)

proc validatePage(beforePresent, afterPresent: bool; limit: Option[int]) =
  if beforePresent and afterPresent:
    raise newException(ValueError,
      "pagination cannot set both before and after")
  if limit.isSome and (limit.get < 1 or limit.get > 100):
    raise newException(ValueError, "pagination limit must be between 1 and 100")

proc initEntitlementQuery*(
    userId = none(UserId);
    skuIds: openArray[SkuId] = [];
    guildId = none(GuildId);
    before = none(EntitlementId);
    after = none(EntitlementId);
    limit = none(int);
    excludeEnded = none(bool);
    excludeDeleted = none(bool);
    onlyActive = none(bool)): EntitlementQuery =
  ## Builds a validated entitlement filter and pagination value.
  validatePage(before.isSome, after.isSome, limit)
  EntitlementQuery(
    userIdValue: userId,
    skuIdsValue: uniqueSkuIds(skuIds),
    guildIdValue: guildId,
    beforeValue: before,
    afterValue: after,
    limitValue: limit,
    excludeEndedValue: excludeEnded,
    excludeDeletedValue: excludeDeleted,
    onlyActiveValue: onlyActive,
  )

proc initCurrentUserEntitlementQuery*(
    skuIds: openArray[SkuId] = [];
    excludeConsumed = none(bool)): CurrentUserEntitlementQuery =
  ## Builds filters accepted by the current-user entitlement route.
  CurrentUserEntitlementQuery(
    skuIdsValue: uniqueSkuIds(skuIds),
    excludeConsumedValue: excludeConsumed,
  )

proc initSubscriptionQuery*(
    before = none(SubscriptionId);
    after = none(SubscriptionId);
    limit = none(int);
    userId = none(UserId)): SubscriptionQuery =
  ## Builds validated subscription pagination and user filtering.
  validatePage(before.isSome, after.isSome, limit)
  SubscriptionQuery(
    beforeValue: before,
    afterValue: after,
    limitValue: limit,
    userIdValue: userId,
  )

proc addOptional[T](raw: var raw_request.RawRequest; name: string;
                    value: Option[T]) =
  if value.isSome:
    raw.addQuery(name, $value.get)

proc apply(raw: var raw_request.RawRequest; query: EntitlementQuery) =
  raw.addOptional("user_id", query.userIdValue)
  for skuId in query.skuIdsValue:
    raw.addQuery("sku_ids", $skuId)
  raw.addOptional("guild_id", query.guildIdValue)
  raw.addOptional("before", query.beforeValue)
  raw.addOptional("after", query.afterValue)
  raw.addOptional("limit", query.limitValue)
  raw.addOptional("exclude_ended", query.excludeEndedValue)
  raw.addOptional("exclude_deleted", query.excludeDeletedValue)
  raw.addOptional("only_active", query.onlyActiveValue)

proc apply(raw: var raw_request.RawRequest;
           query: CurrentUserEntitlementQuery) =
  for skuId in query.skuIdsValue:
    raw.addQuery("sku_ids", $skuId)
  raw.addOptional("exclude_consumed", query.excludeConsumedValue)

proc apply(raw: var raw_request.RawRequest; query: SubscriptionQuery) =
  raw.addOptional("before", query.beforeValue)
  raw.addOptional("after", query.afterValue)
  raw.addOptional("limit", query.limitValue)
  raw.addOptional("user_id", query.userIdValue)

proc listEntitlements*(client: ChronosRestClient;
                       applicationId: ApplicationId;
                       query = initEntitlementQuery();
                       options = initApiCallOptions()):
                       Future[seq[Entitlement]] {.async.} =
  ## Lists application entitlements matching `query`.
  var raw = raw_request.initRawRequest(application_routes.getEntitlements, [
    initRawParameter("application_id", $applicationId),
  ])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeEntitlement,
    options.requestMeta(idSafe))

proc fetchEntitlement*(client: ChronosRestClient;
                        applicationId: ApplicationId;
                        entitlementId: EntitlementId;
                        options = initApiCallOptions()):
                        Future[Entitlement] {.async.} =
  ## Fetches one application entitlement.
  let raw = raw_request.initRawRequest(application_routes.getEntitlement, [
    initRawParameter("application_id", $applicationId),
    initRawParameter("entitlement_id", $entitlementId),
  ])
  return await client.executeJson(raw, decodeEntitlement,
    options.requestMeta(idSafe))

proc createTestEntitlement*(client: ChronosRestClient;
                            applicationId: ApplicationId;
                            grant: EntitlementGrant;
                            options = initApiCallOptions()):
                            Future[Entitlement] {.async.} =
  ## Creates a Discord test entitlement; production purchases use Discord flows.
  let raw = raw_request.initRawRequest(application_routes.createEntitlement, [
    initRawParameter("application_id", $applicationId),
  ], grant.toJson())
  return await client.executeJson(raw, decodeEntitlement,
    options.requestMeta(idNever))

proc deleteTestEntitlement*(client: ChronosRestClient;
                            applicationId: ApplicationId;
                            entitlementId: EntitlementId;
                            options = initApiCallOptions()):
                            Future[void] {.async.} =
  ## Deletes one Discord test entitlement.
  let raw = raw_request.initRawRequest(application_routes.deleteEntitlement, [
    initRawParameter("application_id", $applicationId),
    initRawParameter("entitlement_id", $entitlementId),
  ])
  await client.executeNoContent(raw, options.requestMeta(idSafe))

proc consumeEntitlement*(client: ChronosRestClient;
                         applicationId: ApplicationId;
                         entitlementId: EntitlementId;
                         options = initApiCallOptions()):
                         Future[void] {.async.} =
  ## Marks one consumable entitlement as consumed without automatic retries.
  let raw = raw_request.initRawRequest(application_routes.consumeEntitlement, [
    initRawParameter("application_id", $applicationId),
    initRawParameter("entitlement_id", $entitlementId),
  ])
  await client.executeNoContent(raw, options.requestMeta(idNever))

proc listCurrentUserEntitlements*(
    client: ChronosRestClient;
    applicationId: ApplicationId;
    query = initCurrentUserEntitlementQuery();
    options = initApiCallOptions()): Future[seq[Entitlement]] {.async.} =
  ## Lists entitlements owned by the current bearer-token user.
  var raw = raw_request.initRawRequest(
    user_routes.getCurrentUserApplicationEntitlements, [
      initRawParameter("application_id", $applicationId),
    ])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeEntitlement,
    options.requestMeta(idSafe))

proc listSkuSubscriptions*(client: ChronosRestClient;
                           skuId: SkuId;
                           query = initSubscriptionQuery();
                           options = initApiCallOptions()):
                           Future[seq[Subscription]] {.async.} =
  ## Lists subscriptions for one SKU.
  var raw = raw_request.initRawRequest(sku_routes.getSkuSubscriptions, [
    initRawParameter("sku_id", $skuId),
  ])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeSubscription,
    options.requestMeta(idSafe))

proc fetchSkuSubscription*(client: ChronosRestClient;
                           skuId: SkuId;
                           subscriptionId: SubscriptionId;
                           userId = none(UserId);
                           options = initApiCallOptions()):
                           Future[Subscription] {.async.} =
  ## Fetches one SKU subscription, optionally scoped to a user.
  var raw = raw_request.initRawRequest(sku_routes.getSkuSubscription, [
    initRawParameter("sku_id", $skuId),
    initRawParameter("subscription_id", $subscriptionId),
  ])
  raw.addOptional("user_id", userId)
  return await client.executeJson(raw, decodeSubscription,
    options.requestMeta(idSafe))
