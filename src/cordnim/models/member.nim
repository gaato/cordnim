## Semantic model for the Discord guild member resource.

import std/[json, options]

import ./common
import ./user

export common
export user

type
  GuildMember* = object ## A decoded Discord guild member.
    ##
    ## The field optionality follows the official Guild Member object, which is
    ## context-neutral: `user` is absent in `MESSAGE_CREATE`/`MESSAGE_UPDATE`
    ## members, `pending` only appears in `GUILD_` events, and `joined_at` is
    ## nullable (a guest invited through a voice channel has none). The base
    ## `decodeGuildMember` accepts every such shape; `decodeGuildMemberResponse`
    ## layers the stricter pinned REST `GuildMemberResponse` contract on top.
    user*: Option[User] ## Account behind the membership, when the context
                        ## includes it.
    nick*: Option[string] ## Guild-specific nickname, when set.
    avatar*: Option[string] ## Guild-specific avatar hash, when set.
    banner*: Option[string] ## Guild-specific banner hash, when set.
    roles*: seq[RoleId] ## Roles assigned to the member.
    joinedAt*: Option[Timestamp] ## When the member joined; `none` for a guest
                                 ## whose `joined_at` Discord sends as null.
    premiumSince*: Option[Timestamp] ## When the member began boosting, if ever.
    deaf*: bool ## Whether the member is voice-deafened server-wide.
    mute*: bool ## Whether the member is voice-muted server-wide.
    flags*: int64 ## Guild member flag bits.
    pending*: Option[bool] ## Whether the member is still in membership
                           ## screening, when the context reports it.
    permissions*: Option[Permissions] ## Computed permissions, in interaction
                                      ## payloads only.
    communicationDisabledUntil*: Option[Timestamp] ## Timeout expiry, when the
                                                    ## member is timed out.
    snapshot: DiscordSnapshot ## Retained decode evidence for the member.

proc decodeGuildMember*(node: JsonNode): GuildMember =
  ## Decodes a guild member using the context-neutral official object contract.
  ##
  ## Suitable for Gateway payloads: `user` and `pending` may be absent and
  ## `joined_at` may be null. Use `decodeGuildMemberResponse` for the stricter
  ## REST shape. Only the officially always-present fields (`roles`, `deaf`,
  ## `mute`, `flags`) are required.
  let obj = ensureObject(node, "member")
  # `user` is optional but non-null: absent in `MESSAGE_CREATE` members, yet an
  # explicit `null` is a malformed payload rather than an absent account.
  let user = optionalNonNullField(obj, "user", "member")
  if user.isSome:
    result.user = some(decodeUser(user.get))
  result.nick = optString(obj, "nick", "member")
  result.avatar = optString(obj, "avatar", "member")
  result.banner = optString(obj, "banner", "member")
  for index, roleNode in asArray(
      requireField(obj, "roles", "member"), "member.roles"):
    result.roles.add(decodeId(RoleId, roleNode,
      "member.roles[" & $index & "]"))
  # `joined_at` is present in the object but nullable, so `null` maps to `none`.
  result.joinedAt = reqNullableTimestamp(obj, "joined_at", "member")
  result.premiumSince = optTimestamp(obj, "premium_since", "member")
  result.deaf = asBool(requireField(obj, "deaf", "member"), "member.deaf")
  result.mute = asBool(requireField(obj, "mute", "member"), "member.mute")
  result.flags = asInt(requireField(obj, "flags", "member"), "member.flags")
  # `pending` and `permissions` are optional but non-null when present.
  result.pending = optNonNullBool(obj, "pending", "member")
  let permissions = optionalNonNullField(obj, "permissions", "member")
  if permissions.isSome:
    result.permissions = some(decodePermissions(
      permissions.get, "member.permissions"))
  result.communicationDisabledUntil = optTimestamp(
    obj, "communication_disabled_until", "member")
  result.snapshot = initSnapshot(obj, [
    "user", "nick", "avatar", "banner", "roles", "joined_at", "premium_since",
    "deaf", "mute", "flags", "pending", "permissions",
    "communication_disabled_until"])

proc decodeGuildMemberResponse*(node: JsonNode): GuildMember =
  ## Decodes a member under the strict pinned `GuildMemberResponse` contract.
  ##
  ## In addition to the base object, this REST shape requires a non-null `user`,
  ## a non-null `joined_at`, a non-null `pending`, and the presence of the
  ## nullable `nick`, `avatar`, `banner`, `premium_since`, and
  ## `communication_disabled_until` fields. Omission of any is rejected.
  let obj = ensureObject(node, "member")
  requireNonNull(obj, "user", "member", {JObject})
  requireNonNull(obj, "joined_at", "member", {JString})
  requireNonNull(obj, "pending", "member", {JBool})
  requireNullablePresent(obj, "nick", "member", {JString})
  requireNullablePresent(obj, "avatar", "member", {JString})
  requireNullablePresent(obj, "banner", "member", {JString})
  requireNullablePresent(obj, "premium_since", "member", {JString})
  requireNullablePresent(
    obj, "communication_disabled_until", "member", {JString})
  decodeGuildMember(node)

proc parseGuildMember*(text: string): GuildMember =
  ## Decodes a Discord guild member (base contract) from a JSON document string.
  decodeGuildMember(parseJsonObject(text, "member"))

proc parseGuildMemberResponse*(text: string): GuildMember =
  ## Decodes a strict `GuildMemberResponse` from a JSON document string.
  decodeGuildMemberResponse(parseJsonObject(text, "member"))

proc rawJson*(member: GuildMember): JsonNode =
  ## Returns an independent deep copy of the member's original JSON.
  rawJson(member.snapshot)

proc unknownFields*(member: GuildMember): seq[UnknownField] =
  ## Returns deep copies of member fields not consumed by the decoder.
  unknownFields(member.snapshot)
