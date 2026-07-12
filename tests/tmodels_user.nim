## Focused tests for the semantic user model.

import std/[json, options]

import cordnim/models/user

const sampleUser = """
{
  "id": "80351110224678912",
  "username": "Nelly",
  "discriminator": "0",
  "global_name": "Nelly",
  "avatar": "8342729096ea3675442027381ff50dfe",
  "bot": false,
  "premium_type": 2,
  "public_flags": 131072,
  "flags": 131072,
  "primary_guild": null,
  "extra_unknown": {"nested": [1, 2, 3]}
}
"""

# A complete UserResponse carries id, username, discriminator, avatar,
# global_name, public_flags, flags, and primary_guild.
proc completeUser(id, username: string): JsonNode =
  %*{"id": id, "username": username, "discriminator": "0",
     "global_name": newJNull(), "avatar": newJNull(),
     "public_flags": 0, "flags": 0, "primary_guild": newJNull()}

block decodesRequiredAndOptionalFields:
  let user = parseUser(sampleUser)
  doAssert user.id.toUint64 == 80351110224678912'u64
  doAssert user.username == "Nelly"
  doAssert user.discriminator == "0"
  doAssert user.globalName == some("Nelly")
  doAssert user.avatar == some("8342729096ea3675442027381ff50dfe")
  doAssert not user.bot
  doAssert not user.system # absent boolean defaults to false
  doAssert user.publicFlags == some(131072'i64)

block premiumTypePreservesUnknownValue:
  let user = parseUser(sampleUser)
  doAssert user.premiumType.isSome
  doAssert user.premiumType.get.knownValue == some(ptNitro)
  # A tier newer than this library must round-trip via toRaw.
  var future = completeUser("1", "x")
  future["premium_type"] = %99
  let futureUser = decodeUser(future)
  doAssert futureUser.premiumType.get.knownValue.isNone
  doAssert futureUser.premiumType.get.toRaw == 99

block missingBaseRequiredFieldsRaise:
  # The base object requires id, username, discriminator, and the nullable
  # global_name and avatar; omission of any is rejected, as is a bad snowflake.
  for missing in ["id", "username", "discriminator", "global_name", "avatar"]:
    var partial = completeUser("1", "x"); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeUser(partial)
  var badId = completeUser("1", "x"); badId["id"] = %"notasnowflake"
  doAssertRaises DecodeError:
    discard decodeUser(badId)

block baseUserAcceptsGatewayProjection:
  # A READY/member/message user projection omits flags, public_flags, and
  # primary_guild. The base decoder accepts it; the strict response rejects it.
  var projection = completeUser("1", "x")
  for k in ["flags", "public_flags", "primary_guild"]:
    projection.delete(k)
  let user = decodeUser(projection)
  doAssert user.publicFlags.isNone # absence is not zero
  for missing in ["public_flags", "flags", "primary_guild"]:
    var partial = completeUser("1", "x"); partial.delete(missing)
    doAssertRaises DecodeError:
      discard decodeUserResponse(partial)

block responseUserRejectsNullRequiredFlags:
  # Under the strict response contract, public_flags and flags must be non-null.
  var nullPublic = completeUser("1", "x"); nullPublic["public_flags"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeUserResponse(nullPublic)
  var nullFlags = completeUser("1", "x"); nullFlags["flags"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeUserResponse(nullFlags)
  # A complete UserResponse still decodes, and public_flags is populated.
  doAssert decodeUserResponse(completeUser("1", "x")).publicFlags == some(0'i64)

block optionalNonNullBotRejectsExplicitNull:
  # `bot` is optional but non-null: absence defaults to false, but an explicit
  # null is a malformed payload and must not collapse to absence.
  var nullBot = completeUser("1", "x"); nullBot["bot"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeUser(nullBot)
  var nullSystem = completeUser("1", "x"); nullSystem["system"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeUser(nullSystem)

block optionalNonNullFieldsRejectExplicitNull:
  # mfa_enabled, locale, verified, premium_type, and public_flags are optional
  # but non-null: absence is fine, but an explicit null is a malformed payload.
  for field in ["mfa_enabled", "locale", "verified", "premium_type",
      "public_flags"]:
    var nulled = completeUser("1", "x"); nulled[field] = newJNull()
    doAssertRaises DecodeError:
      discard decodeUser(nulled)
  # ...while a payload that simply omits those optional fields decodes cleanly
  # (completeUser carries none of mfa_enabled/locale/verified/premium_type).
  discard decodeUser(completeUser("1", "x"))
  # The unmodelled flags field is type-checked too: an explicit null is rejected
  # even though the base decoder does not surface flags as a value.
  var nullFlags = completeUser("1", "x"); nullFlags["flags"] = newJNull()
  doAssertRaises DecodeError:
    discard decodeUser(nullFlags)
  var badFlags = completeUser("1", "x"); badFlags["flags"] = %"64"
  doAssertRaises DecodeError:
    discard decodeUser(badFlags)
  # primary_guild is optional nullable: a null is accepted, a wrong type is not.
  var badPrimaryGuild = completeUser("1", "x")
  badPrimaryGuild["primary_guild"] = %"not-an-object"
  doAssertRaises DecodeError:
    discard decodeUser(badPrimaryGuild)

block nullNullableFieldsBecomeNone:
  let user = decodeUser(completeUser("1", "x"))
  doAssert user.globalName.isNone
  doAssert user.avatar.isNone
  doAssert user.publicFlags == some(0'i64)

block rawJsonReturnsIndependentDeepCopy:
  let user = parseUser(sampleUser)
  var first = user.rawJson
  doAssert first["username"].getStr == "Nelly"
  # Mutating the returned tree must not affect the retained snapshot.
  first["username"] = %"tampered"
  first["extra_unknown"]["nested"].add(%99)
  let second = user.rawJson
  doAssert second["username"].getStr == "Nelly"
  doAssert second["extra_unknown"]["nested"].len == 3

block unknownFieldsAreDeepCopied:
  let user = parseUser(sampleUser)
  var unknown = user.unknownFields
  doAssert unknown.len == 1
  doAssert unknown[0].name == "extra_unknown"
  doAssert unknown[0].value["nested"].len == 3
  # Consumed fields, including required-but-unmodelled ones, are not unknown.
  for field in unknown:
    doAssert field.name != "id"
    doAssert field.name != "premium_type"
    doAssert field.name != "flags"
    doAssert field.name != "primary_guild"
  # Mutating a returned unknown value must not corrupt the stored snapshot.
  unknown[0].value["nested"].add(%42)
  let again = user.unknownFields
  doAssert again[0].value["nested"].len == 3
