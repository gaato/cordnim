import std/[assertions, json, options]

import cordnim/models/common
import cordnim/models/monetization

proc entitlementDocument(): JsonNode =
  %*{
    "id": "10",
    "sku_id": "11",
    "application_id": "12",
    "user_id": "13",
    "deleted": false,
    "starts_at": "2026-07-01T00:00:00Z",
    "ends_at": nil,
    "type": 8,
    "fulfilled_at": nil,
    "fulfillment_status": 2,
    "consumed": false,
    "future_field": "kept",
  }

block entitlement_decodes_required_nullable_and_open_values:
  let entitlement = decodeEntitlement(entitlementDocument())
  doAssert $entitlement.id == "10"
  doAssert entitlement.userId == some(UserId.parseId("13"))
  doAssert entitlement.guildId.isNone
  doAssert entitlement.startsAt.get.iso8601 == "2026-07-01T00:00:00Z"
  doAssert entitlement.endsAt.isNone
  doAssert entitlement.kind.knownValue == some(etApplicationSubscription)
  doAssert entitlement.fulfillmentStatus.get.knownValue == some(efsNeeded)
  doAssert entitlement.unknownFields[0].name == "future_field"

block entitlement_accepts_current_optional_owners_and_validity_window:
  var document = entitlementDocument()
  document.delete("user_id")
  document.delete("starts_at")
  document.delete("ends_at")
  document["guild_id"] = %"14"
  let guildEntitlement = decodeEntitlement(document)
  doAssert guildEntitlement.userId.isNone
  doAssert guildEntitlement.guildId == some(GuildId.parseId("14"))
  doAssert guildEntitlement.startsAt.isNone
  doAssert guildEntitlement.endsAt.isNone

  document["user_id"] = %"13"
  let sharedEntitlement = decodeEntitlement(document)
  doAssert sharedEntitlement.userId == some(UserId.parseId("13"))
  doAssert sharedEntitlement.guildId == some(GuildId.parseId("14"))

block entitlement_strict_response_retains_pinned_requirements:
  var document = entitlementDocument()
  document.delete("ends_at")
  doAssertRaises DecodeError:
    discard decodeEntitlementResponse(document)
  document = entitlementDocument()
  document.delete("user_id")
  doAssertRaises DecodeError:
    discard decodeEntitlementResponse(document)

block entitlement_rejects_malformed_optional_values:
  var document = entitlementDocument()
  document["starts_at"] = %"2026-13-01T00:00:00Z"
  doAssertRaises DecodeError:
    discard decodeEntitlement(document)
  document = entitlementDocument()
  document["user_id"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeEntitlement(document)
  document = entitlementDocument()
  document["guild_id"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeEntitlement(document)

block entitlement_types_retain_current_and_future_values:
  var document = entitlementDocument()
  document["type"] = %1
  doAssert decodeEntitlement(document).kind.knownValue == some(etPurchase)
  document["type"] = %7
  doAssert decodeEntitlement(document).kind.knownValue ==
    some(etPremiumPurchase)
  document["type"] = %10
  doAssert decodeEntitlement(document).kind.knownValue == some(etQuestReward)
  document["type"] = %99
  doAssert decodeEntitlement(document).kind.knownValue.isNone

block subscription_decodes_nullable_lists_and_unknown_status:
  let subscription = decodeSubscription(%*{
    "id": "20",
    "user_id": "13",
    "sku_ids": ["11"],
    "renewal_sku_ids": nil,
    "entitlement_ids": ["10"],
    "current_period_start": "2026-07-01T00:00:00+00:00",
    "current_period_end": "2026-08-01T00:00:00+00:00",
    "status": 99,
    "canceled_at": nil,
    "country": "JP",
  })
  doAssert subscription.renewalSkuIds.isNone
  doAssert subscription.status.knownValue.isNone
  doAssert subscription.country == some("JP")

block subscription_status_numbers_match_discord:
  var document = %*{
    "id": "20",
    "user_id": "13",
    "sku_ids": ["11"],
    "renewal_sku_ids": nil,
    "entitlement_ids": ["10"],
    "current_period_start": "2026-07-01T00:00:00Z",
    "current_period_end": "2026-08-01T00:00:00Z",
    "status": 1,
    "canceled_at": nil,
  }
  doAssert decodeSubscription(document).status.knownValue == some(ssEnding)
  document["status"] = %2
  doAssert decodeSubscription(document).status.knownValue == some(ssInactive)

block subscription_country_is_optional_non_null:
  var document = %*{
    "id": "20",
    "user_id": "13",
    "sku_ids": ["11"],
    "renewal_sku_ids": nil,
    "entitlement_ids": ["10"],
    "current_period_start": "2026-07-01T00:00:00Z",
    "current_period_end": "2026-08-01T00:00:00Z",
    "status": 0,
    "canceled_at": nil,
    "country": nil,
  }
  doAssertRaises DecodeError:
    discard decodeSubscription(document)
  document.delete("country")
  doAssert decodeSubscription(document).country.isNone

block subscription_rejects_duplicates_and_missing_nullable_members:
  doAssertRaises DecodeError:
    discard decodeSubscription(%*{
      "id": "20",
      "user_id": "13",
      "sku_ids": ["11", "11"],
      "renewal_sku_ids": [],
      "entitlement_ids": ["10"],
      "current_period_start": "2026-07-01T00:00:00Z",
      "current_period_end": "2026-08-01T00:00:00Z",
      "status": 0,
      "canceled_at": nil,
    })
  doAssertRaises DecodeError:
    discard decodeSubscription(%*{
      "id": "20",
      "user_id": "13",
      "sku_ids": ["11"],
      "renewal_sku_ids": [],
      "entitlement_ids": ["10"],
      "current_period_start": "2026-07-01T00:00:00Z",
      "current_period_end": "2026-08-01T00:00:00Z",
      "status": 0,
    })
  doAssertRaises DecodeError:
    discard decodeSubscription(%*{
      "id": "20",
      "user_id": "13",
      "sku_ids": ["11"],
      "renewal_sku_ids": [],
      "entitlement_ids": ["10"],
      "current_period_start": "not-a-date",
      "current_period_end": "2026-08-01T00:00:00Z",
      "status": 0,
      "canceled_at": nil,
    })

block entitlement_grants_cannot_mix_owner_id_kinds:
  let sku = SkuId.parseId("11")
  let userGrant = entitlementForUser(sku, UserId.parseId("13"))
  let guildGrant = entitlementForGuild(sku, GuildId.parseId("14"))
  doAssert userGrant.ownerType == eotUser
  doAssert userGrant.toJson == %*{
    "sku_id": "11", "owner_id": "13", "owner_type": 2}
  doAssert guildGrant.ownerType == eotGuild
  doAssert guildGrant.toJson["owner_id"].getStr == "14"
  doAssertRaises ValidationError:
    discard EntitlementGrant().toJson
  doAssertRaises ValidationError:
    discard entitlementForUser(SkuId.toId(0), UserId.parseId("13"))
