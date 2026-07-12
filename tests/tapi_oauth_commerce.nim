import std/[assertions, json, options, strutils]

import chronos

import cordnim/api/[applications, monetization, oauth2]
import cordnim/models/[common, monetization as monetization_models]
import cordnim/rest
import cordnim/testing

func bytesText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc completeUser(id = "2"): JsonNode =
  %*{
    "id": id,
    "username": "owner",
    "avatar": nil,
    "discriminator": "0",
    "public_flags": 0,
    "flags": 0,
    "global_name": nil,
    "primary_guild": nil,
  }

proc publicApplication(): JsonNode =
  %*{
    "id": "1",
    "name": "Cordnim test app",
    "icon": nil,
    "description": "test application",
    "type": nil,
    "verify_key": "public-key",
    "flags": 0,
    "flags_new": "0",
  }

proc privateApplication(): JsonNode =
  result = publicApplication()
  result["redirect_uris"] = newJArray()
  result["interactions_endpoint_url"] = newJNull()
  result["role_connections_verification_url"] = newJNull()
  result["owner"] = completeUser()
  result["approximate_guild_count"] = %0
  result["approximate_user_install_count"] = %0
  result["approximate_user_authorization_count"] = %0
  result["explicit_content_filter"] = %0
  result["team"] = newJNull()

proc entitlement(): JsonNode =
  %*{
    "id": "10",
    "sku_id": "11",
    "application_id": "1",
    "user_id": "2",
    "deleted": false,
    "starts_at": "2026-07-01T00:00:00Z",
    "ends_at": nil,
    "type": 8,
  }

proc subscription(): JsonNode =
  %*{
    "id": "20",
    "user_id": "2",
    "sku_ids": ["11"],
    "renewal_sku_ids": nil,
    "entitlement_ids": ["10"],
    "current_period_start": "2026-07-01T00:00:00Z",
    "current_period_end": "2026-08-01T00:00:00Z",
    "status": 0,
    "canceled_at": nil,
  }

proc startedClient(scripted: ScriptedRestTransport): ChronosRestClient =
  result = newChronosRestClient(scripted.asRestTransport())
  result.start()

block oauth_resources_use_safe_retryable_routes:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(jsonResponse(200, %*{
    "application": publicApplication(),
    "expires": "2026-07-12T00:00:00Z",
    "scopes": ["identify"],
    "user": completeUser(),
  }), matchRoute("GET /oauth2/@me"))
  scripted.expectRequest(jsonResponse(200, privateApplication()),
    matchRoute("GET /oauth2/applications/@me"))
  scripted.expectRequest(jsonResponse(200, %*{
    "keys": [{
      "kty": "RSA", "use": "sig", "kid": "key-1",
      "n": "modulus", "e": "AQAB", "alg": "RS256",
    }],
  }), matchRoute("GET /oauth2/keys"))
  scripted.expectRequest(jsonResponse(200, %*{
    "sub": "2", "preferred_username": "owner",
  }), matchRoute("GET /oauth2/userinfo"))
  let client = startedClient(scripted)
  doAssert (waitFor client.fetchCurrentAuthorization()).user.get.username ==
    "owner"
  doAssert (waitFor client.fetchCurrentOAuthApplication()).application.name ==
    "Cordnim test app"
  doAssert (waitFor client.fetchOAuthPublicKeys()).keys[0].keyId == "key-1"
  doAssert (waitFor client.fetchOpenIdIdentity()).subject == "2"
  waitFor client.stop()
  let observed = scripted.observedRequests()
  for request in observed:
    doAssert request.httpMethod == hmGet
  doAssert observed[0].authRequirement == darOAuthBearer
  doAssert observed[1].authRequirement == darBot
  doAssert observed[2].authRequirement == darNone
  doAssert observed[3].authRequirement == darOAuthBearer
  scripted.assertSatisfied()

block application_resources_render_typed_ids:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(jsonResponse(200, privateApplication()),
    matchRoute("GET /applications/{application_id}"))
  let client = startedClient(scripted)
  let application = waitFor client.fetchApplication(ApplicationId.parseId("1"))
  doAssert application.application.name == "Cordnim test app"
  waitFor client.stop()
  let observed = scripted.observedRequests()[0]
  doAssert observed.redactedPath == "/applications/1"
  doAssert observed.authRequirement == darBot
  scripted.assertSatisfied()

block entitlement_queries_are_typed_and_creation_is_not_retryable:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(jsonResponse(200, %*[entitlement()]))
  scripted.expectRequest(jsonResponse(200, entitlement()))
  let client = startedClient(scripted)
  let appId = ApplicationId.parseId("1")
  let skuId = SkuId.parseId("11")
  let values = waitFor client.listEntitlements(appId,
    initEntitlementQuery(
      userId = some(UserId.parseId("2")),
      skuIds = [skuId],
      limit = some(25),
      onlyActive = some(true)))
  doAssert values.len == 1
  let grant = entitlementForUser(skuId, UserId.parseId("2"))
  discard waitFor client.createTestEntitlement(appId, grant)
  waitFor client.stop()
  let observed = scripted.observedRequests()
  doAssert observed[0].redactedPath.contains("user_id=2")
  doAssert observed[0].redactedPath.contains("sku_ids=11")
  doAssert observed[0].redactedPath.contains("limit=25")
  doAssert observed[0].redactedPath.contains("only_active=true")
  doAssert observed[0].httpMethod == hmGet
  doAssert observed[0].authRequirement == darBotOrOAuthBearer
  doAssert observed[1].httpMethod == hmPost
  doAssert observed[1].authRequirement == darBot
  let body = parseJson(observed[1].bodyBytes.bytesText())
  doAssert body == grant.toJson
  scripted.assertSatisfied()

block subscription_queries_and_results_remain_typed:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(jsonResponse(200, %*[subscription()]))
  scripted.expectRequest(jsonResponse(200, subscription()))
  let client = startedClient(scripted)
  let skuId = SkuId.parseId("11")
  let listed = waitFor client.listSkuSubscriptions(skuId,
    initSubscriptionQuery(userId = some(UserId.parseId("2"))))
  doAssert listed[0].status.knownValue == some(ssActive)
  let fetched = waitFor client.fetchSkuSubscription(skuId,
    SubscriptionId.parseId("20"), userId = some(UserId.parseId("2")))
  doAssert fetched.id == SubscriptionId.parseId("20")
  waitFor client.stop()
  for observed in scripted.observedRequests():
    doAssert observed.redactedPath.contains("user_id=2")
    doAssert observed.authRequirement == darBotOrOAuthBearer
  scripted.assertSatisfied()

block current_user_entitlements_require_a_bearer_token:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(jsonResponse(200, %*[entitlement()]))
  let client = startedClient(scripted)
  discard waitFor client.listCurrentUserEntitlements(ApplicationId.parseId("1"))
  waitFor client.stop()
  doAssert scripted.observedRequests()[0].authRequirement == darOAuthBearer
  scripted.assertSatisfied()

block query_builders_reject_ambiguous_or_oversized_input:
  doAssertRaises ValueError:
    discard initEntitlementQuery(
      before = some(EntitlementId.parseId("1")),
      after = some(EntitlementId.parseId("2")))
  doAssertRaises ValueError:
    discard initSubscriptionQuery(limit = some(101))
  var tooMany: seq[SkuId]
  for value in 1'u64 .. 101'u64:
    tooMany.add(SkuId.toId(value))
  doAssertRaises ValueError:
    discard initCurrentUserEntitlementQuery(tooMany)

block mutating_entitlement_operations_choose_idempotency_explicitly:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(204))
  scripted.expectRequest(transportResponse(204))
  let client = startedClient(scripted)
  let appId = ApplicationId.parseId("1")
  let entitlementId = EntitlementId.parseId("10")
  waitFor client.deleteTestEntitlement(appId, entitlementId)
  waitFor client.consumeEntitlement(appId, entitlementId)
  waitFor client.stop()
  let observed = scripted.observedRequests()
  doAssert observed[0].httpMethod == hmDelete
  doAssert observed[0].authRequirement == darBotOrOAuthBearer
  doAssert observed[1].httpMethod == hmPost
  doAssert observed[1].authRequirement == darBotOrOAuthBearer
  scripted.assertSatisfied()
