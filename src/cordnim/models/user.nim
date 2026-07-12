## Semantic model for the Discord user resource.

import std/[json, options]

import ./common

export common

type
  PremiumType* = enum ## Discord Nitro subscription tier of a user.
    ptNone = 0, ## No active Nitro subscription.
    ptNitroClassic = 1, ## Nitro Classic subscription.
    ptNitro = 2, ## Full Nitro subscription.
    ptNitroBasic = 3 ## Nitro Basic subscription.

  User* = object ## A decoded Discord user account.
    id*: UserId ## Unique snowflake identity of the user.
    username*: string ## Non-unique display handle.
    discriminator*: string ## Legacy four-digit tag, `"0"` once migrated.
    globalName*: Option[string] ## Chosen display name, if the user set one.
    avatar*: Option[string] ## Avatar image hash, if the user set one.
    bot*: bool ## Whether the account is an OAuth2 bot application.
    system*: bool ## Whether the account is an official Discord system user.
    mfaEnabled*: Option[bool] ## Whether two-factor auth is enabled, when known.
    banner*: Option[string] ## Profile banner image hash, when present.
    accentColor*: Option[int64] ## Profile accent color, when present.
    locale*: Option[string] ## Chosen language, when the user shares it.
    verified*: Option[bool] ## Whether the email is verified, for the current
                            ## user only.
    email*: Option[string] ## Email address, for the current user only.
    premiumType*: Option[OpenEnum[PremiumType, int]] ## Nitro tier, when known.
    publicFlags*: Option[int64] ## Public account flag bits; optional in the
                                ## official object, so `none` when a projection
                                ## omits it (absence is not zero).
    snapshot: DiscordSnapshot ## Retained decode evidence for the user.

proc decodeUser*(node: JsonNode): User =
  ## Decodes a user using the context-neutral official User object contract.
  ##
  ## The official object requires only `id`, `username`, `discriminator`, and
  ## the nullable `global_name` and `avatar`; `bot`, `system`, `flags`,
  ## `public_flags`, and `primary_guild` are optional. This shape is what
  ## `READY`, guild member, and message user projections carry, so this decoder
  ## must accept them. Use `decodeUserResponse` for the stricter pinned
  ## `UserResponse` REST contract.
  let obj = ensureObject(node, "user")
  result.id = decodeId(UserId, requireField(obj, "id", "user"), "user.id")
  result.username = asString(
    requireField(obj, "username", "user"), "user.username")
  result.discriminator = asString(
    requireField(obj, "discriminator", "user"), "user.discriminator")
  # `global_name` and `avatar` are required by the base object but nullable.
  result.globalName = reqNullableString(obj, "global_name", "user")
  result.avatar = reqNullableString(obj, "avatar", "user")
  result.bot = boolOr(obj, "bot", false, "user")
  result.system = boolOr(obj, "system", false, "user")
  # `mfa_enabled`, `locale`, `verified`, `premium_type`, and `public_flags` are
  # optional but non-null in the official object: absence is `none`, but an
  # explicit `null` is a malformed payload rather than an omitted value.
  result.mfaEnabled = optNonNullBool(obj, "mfa_enabled", "user")
  result.banner = optString(obj, "banner", "user")
  result.accentColor = optInt(obj, "accent_color", "user")
  result.locale = optNonNullString(obj, "locale", "user")
  result.verified = optNonNullBool(obj, "verified", "user")
  result.email = optString(obj, "email", "user")
  let premium = optionalNonNullField(obj, "premium_type", "user")
  if premium.isSome:
    result.premiumType = some(
      decodeIntEnum(PremiumType, premium.get, "user.premium_type"))
  result.publicFlags = optNonNullInt(obj, "public_flags", "user")
  # `flags` and `primary_guild` are unmodelled but validated when present so a
  # malformed null or wrong-typed value cannot slip through into the snapshot:
  # `flags` is optional non-null, `primary_guild` optional nullable.
  discard optNonNullInt(obj, "flags", "user")
  expectOptionalNullable(obj, "primary_guild", "user", {JObject})
  result.snapshot = initSnapshot(obj, [
    "id", "username", "discriminator", "global_name", "avatar", "bot",
    "system", "mfa_enabled", "banner", "accent_color", "locale", "verified",
    "email", "premium_type", "public_flags", "flags", "primary_guild"])

proc decodeUserResponse*(node: JsonNode): User =
  ## Decodes a user under the strict pinned `UserResponse` contract.
  ##
  ## Beyond the base object this REST shape additionally requires a non-null
  ## `public_flags`, a non-null `flags`, and a present (nullable) `primary_guild`
  ## — none of which a Gateway user projection is guaranteed to carry.
  let obj = ensureObject(node, "user")
  requireNonNull(obj, "public_flags", "user", {JInt})
  requireNonNull(obj, "flags", "user", {JInt})
  requireNullablePresent(obj, "primary_guild", "user", {JObject})
  decodeUser(node)

proc parseUser*(text: string): User =
  ## Decodes a Discord user (base contract) from a JSON document string.
  decodeUser(parseJsonObject(text, "user"))

proc parseUserResponse*(text: string): User =
  ## Decodes a strict `UserResponse` from a JSON document string.
  decodeUserResponse(parseJsonObject(text, "user"))

proc rawJson*(user: User): JsonNode =
  ## Returns an independent deep copy of the user's original JSON.
  rawJson(user.snapshot)

proc unknownFields*(user: User): seq[UnknownField] =
  ## Returns deep copies of user fields not consumed by the decoder.
  unknownFields(user.snapshot)
