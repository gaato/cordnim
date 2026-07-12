import std/[assertions, json, options]

import cordnim/models/common
import cordnim/models/oauth

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
    "flags_new": "18446744073709551616",
    "primary_sku_id": "3",
    "install_params": {
      "scopes": ["bot", "applications.commands", "future.scope"],
      "permissions": "8",
    },
    "future_field": {"kept": true},
  }

block application_preserves_flags_scopes_and_unknown_fields:
  let application = decodeApplication(publicApplication())
  doAssert $application.id == "1"
  doAssert application.icon.isNone
  doAssert application.kind.isNone
  doAssert application.flags.containsBit(64)
  doAssert application.primarySkuId.get == SkuId.parseId("3")
  doAssert application.installParams.get.scopes[0].knownValue(
    oauthScopeMapping) == some(osBot)
  doAssert application.installParams.get.scopes[2].knownValue(
    oauthScopeMapping).isNone
  doAssert application.unknownFields.len == 1
  var raw = application.rawJson
  raw["name"] = %"mutated"
  doAssert application.rawJson["name"].getStr == "Cordnim test app"

block application_rejects_missing_required_nullable_fields:
  var missingIcon = publicApplication()
  missingIcon.delete("icon")
  doAssertRaises DecodeError:
    discard decodeApplication(missingIcon)
  var nullFlags = publicApplication()
  nullFlags["flags_new"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeApplication(nullFlags)

block private_application_checks_private_required_shape:
  var document = publicApplication()
  document["redirect_uris"] = %*["https://example.test/callback"]
  document["interactions_endpoint_url"] = newJNull()
  document["role_connections_verification_url"] = newJNull()
  document["owner"] = completeUser()
  document["approximate_guild_count"] = %4
  document["approximate_user_install_count"] = %5
  document["approximate_user_authorization_count"] = %6
  document["explicit_content_filter"] = %1
  document["team"] = %*{
    "id": "7",
    "icon": nil,
    "name": "Cordnim team",
    "owner_user_id": "2",
    "members": [{
      "user": completeUser(),
      "team_id": "7",
      "membership_state": 2,
      "role": "developer",
      "permissions": ["*"],
    }],
  }
  let application = decodePrivateApplication(document)
  doAssert application.redirectUris == @["https://example.test/callback"]
  doAssert application.owner.username == "owner"
  doAssert application.explicitContentFilter.knownValue == some(aecfAlways)
  doAssert application.team.get.name == "Cordnim team"
  doAssert application.team.get.members[0].role.knownValue(
    teamMemberRoleMapping) == some(tmrDeveloper)
  let publicRaw = application.application.rawJson
  for privateField in ["redirect_uris", "owner", "team",
      "interactions_endpoint_url"]:
    doAssert not publicRaw.hasKey(privateField)
  # A private response cannot classify future fields as public or private, so
  # the embedded public projection keeps only pinned public properties.
  doAssert application.application.unknownFields.len == 0

  document.delete("team")
  doAssertRaises DecodeError:
    discard decodePrivateApplication(document)

block private_application_rejects_malformed_team_shape:
  var document = publicApplication()
  document["redirect_uris"] = newJArray()
  document["interactions_endpoint_url"] = newJNull()
  document["role_connections_verification_url"] = newJNull()
  document["owner"] = completeUser()
  document["approximate_guild_count"] = %0
  document["approximate_user_install_count"] = %0
  document["approximate_user_authorization_count"] = %0
  document["explicit_content_filter"] = %0
  document["team"] = newJObject()
  doAssertRaises DecodeError:
    discard decodePrivateApplication(document)

block authorization_and_oidc_keep_forward_compatible_values:
  let authorization = decodeOAuthAuthorization(%*{
    "application": publicApplication(),
    "expires": "2026-07-12T12:30:45.123Z",
    "scopes": ["identify", "future.scope"],
    "user": completeUser(),
  })
  doAssert authorization.scopes[0].knownValue(oauthScopeMapping) ==
    some(osIdentify)
  doAssert authorization.scopes[1].knownValue(oauthScopeMapping).isNone
  doAssert authorization.user.get.username == "owner"

  let identity = decodeOpenIdIdentity(%*{
    "sub": "2",
    "email": nil,
    "email_verified": true,
    "preferred_username": "owner",
  })
  doAssert identity.subject == "2"
  doAssert identity.email.isNone
  doAssert identity.emailVerified == some(true)

block authorization_rejects_invalid_expiry_timestamp:
  doAssertRaises DecodeError:
    discard decodeOAuthAuthorization(%*{
      "application": publicApplication(),
      "expires": "not-a-date",
      "scopes": ["identify"],
    })

block duplicate_scopes_and_invalid_optional_null_are_rejected:
  var document = publicApplication()
  document["install_params"]["scopes"] = %*["bot", "bot"]
  doAssertRaises DecodeError:
    discard decodeApplication(document)
  doAssertRaises DecodeError:
    discard decodeOpenIdIdentity(%*{"sub": "2", "email_verified": nil})

block public_keys_require_complete_jwk_members:
  let keys = decodeOAuthPublicKeys(%*{
    "keys": [{
      "kty": "RSA", "use": "sig", "kid": "key-1",
      "n": "modulus", "e": "AQAB", "alg": "RS256",
    }],
  })
  doAssert keys.keys.len == 1
  doAssert keys.keys[0].keyId == "key-1"
  doAssertRaises DecodeError:
    discard decodeOAuthPublicKeys(%*{
      "keys": [{"kty": "RSA", "use": "sig"}],
    })
