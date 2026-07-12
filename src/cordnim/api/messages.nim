## Semantic message REST operations over the supervised REST client.
##
## Every outbound payload is built from validated typed request values whose
## invariants are re-checked at serialization time, and each operation supplies
## its own idempotency evidence. Components V2 drafts never accept `content`,
## `embeds`, `poll`, or `sticker` fields; that separation is preserved from
## `cordnim/components`. Deprecated pin routes and multipart attachment uploads
## remain available only through the raw escape hatch.

import std/[json, options, sets, unicode]

import chronos

import cordnim/api/fields
import cordnim/api/internal/execute
import cordnim/api/options
import cordnim/core/ids
import cordnim/models/message
import cordnim/components/model
import cordnim/components/serialization
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/channels as channel_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

export message
export model
export serialization
export options
export fields

const
  MinBulkDeleteMessages* = 2 ## Fewest IDs Discord's bulk delete accepts.
  MaxBulkDeleteMessages* = 100 ## Most IDs Discord's bulk delete accepts.
  MinHistoryLimit* = 1 ## Fewest messages a history page may request.
  MaxHistoryLimit* = 100 ## Most messages a history page may request.
  MinReactionLimit* = 1 ## Fewest reaction voters a page may request.
  MaxReactionLimit* = 100 ## Most reaction voters a page may request.
  MinPinLimit* = 1 ## Fewest pins a page may request.
  MaxPinLimit* = 50 ## Most pins a page may request.
  MaxNonceLength* = 25 ## Longest string nonce Discord accepts.
  MaxMessageContentLength* = 2_000 ## Current message content character limit.
  MaxAllowedMentionIds* = 100 ## Maximum explicit users or roles per policy.

  suppressEmbedsFlag = 1'i64 shl 2
  suppressNotificationsFlag = 1'i64 shl 12
  componentsV2Flag = 1'i64 shl 15
  messageCreateFlagMask = suppressEmbedsFlag or suppressNotificationsFlag or
    componentsV2Flag
  messageEditFlagMask = suppressEmbedsFlag or componentsV2Flag

type
  MessageNonceKind = enum ## Wire representation chosen for a create nonce.
    mnkInteger, ## 64-bit integer nonce.
    mnkString ## Opaque string nonce of at most 25 characters.

  MessageNonce* = object ## A validated deduplication nonce for message create.
    ## Diagnostics never render the value; only `toWire` reveals it, and only at
    ## the serialization boundary.
    case kind: MessageNonceKind
    of mnkInteger:
      integerValue: int64
    of mnkString:
      stringValue: string

  MessageReferenceKind* = enum ## Outbound message-reference behavior.
    mrReply = 0, ## Reply to a message.
    mrForward = 1 ## Forward an immutable snapshot of a message.

  MessageReferenceRequest* = object ## An outbound reference to another message.
    messageIdValue: MessageId
    channelIdValue: Option[ChannelId]
    guildIdValue: Option[GuildId]
    failIfNotExistsValue: Option[bool]
    kindValue: MessageReferenceKind

  AllowedMentionParse* = enum ## Discord mention classes parsed from text.
    ampUsers, ## Parse user mentions from content or text displays.
    ampRoles, ## Parse role mentions from content or text displays.
    ampEveryone ## Parse `@everyone` and `@here`.

  AllowedMentions* = object ## A validated outbound mention policy.
    parseValue: set[AllowedMentionParse]
    userIdsValue: seq[UserId]
    roleIdsValue: seq[RoleId]
    repliedUserValue: Option[bool]

  ReactionType* = enum ## Reaction burst category recognized by Discord.
    rtNormal = 0, ## Standard reaction.
    rtBurst = 1 ## Super-reaction burst.

  PollAnswerId* = range[1..10] ## Poll answer identity accepted by voter routes.

  ReactionEmoji* = object ## A validated reaction emoji path identity.
    nameValue: string
    idValue: Option[EmojiId]

  MessageHistoryQuery* = object ## Bounded pagination for channel history.
    ## At most one of `before`, `after`, or `around` may be set, and `limit`
    ## stays within Discord's inclusive 1..100 window.
    beforeValue: Option[MessageId]
    afterValue: Option[MessageId]
    aroundValue: Option[MessageId]
    limitValue: Option[int]

  ReactionQuery* = object ## Bounded pagination for a reaction's voters.
    afterValue: Option[UserId]
    limitValue: Option[int]
    typeValue: Option[ReactionType]

  PollVoterQuery* = object ## Bounded pagination for one poll answer's voters.
    afterValue: Option[UserId]
    limitValue: Option[int]

  PinQuery* = object ## Bounded pagination for the current pins endpoint.
    beforeValue: Option[string]
    limitValue: Option[int]

  PinnedMessage* = object ## One entry in a channel's pinned-message list.
    pinnedAt*: Timestamp ## When the message was pinned.
    message*: Message ## The pinned message itself.

  PinnedMessages* = object ## A page of pinned messages with a continuation flag.
    items*: seq[PinnedMessage] ## Pinned messages, newest first.
    hasMore*: bool ## Whether an older page remains.

  MessageCreate*[Mode: Legacy | V2] = object ## A validated message-create body.
    ## Wraps a mode-specific `MessageDraft` plus fields legal in both modes;
    ## Components V2 drafts still forbid `content`, `embeds`, `poll`, and
    ## stickers structurally.
    draftValue: MessageDraft[Mode]
    ttsValue: bool
    nonceValue: Option[MessageNonce]
    enforceNonceValue: bool
    referenceValue: Option[MessageReferenceRequest]
    allowedMentionsValue: AllowedMentions
    flagsValue: Option[int64]
    when Mode is Legacy:
      pollValue: Option[PollCreate]

  MessageEdit*[Mode: Legacy | V2] = object ## A validated message-edit body.
    ## Every field honors omit/clear semantics; a default value edits nothing.
    componentsValue: FieldEdit[seq[ComponentNode]]
    allowedMentionsValue: AllowedMentions
    flagsValue: Option[int64]
    when Mode is Legacy:
      contentValue: FieldEdit[string]
      stickerIdsValue: FieldEdit[seq[StickerId]]

# ---------------------------------------------------------------------------
# Shared outbound validation
# ---------------------------------------------------------------------------

proc validateText(value, label: string; maxRunes: int; allowEmpty = true) =
  if value.validateUtf8 != -1:
    raise newException(ValueError, label & " must be valid UTF-8")
  if not allowEmpty and value.len == 0:
    raise newException(ValueError, label & " must not be empty")
  if value.runeLen > maxRunes:
    raise newException(ValueError,
      label & " must not exceed " & $maxRunes & " characters")

proc validateFlags(flags: Option[int64]; allowedMask: int64; label: string;
                   rejectV2 = false) =
  if flags.isNone:
    return
  let value = flags.get
  if value < 0 or (value and not allowedMask) != 0:
    raise newException(ValueError, label & " contains unsupported flag bits")
  if rejectV2 and (value and componentsV2Flag) != 0:
    raise newException(ValueError,
      label & " cannot enable Components V2 on a legacy body")

proc requireNonzero[Kind](id: Id[Kind]; label: string) =
  if id.toUint64() == 0:
    raise newException(ValueError, label & " must be greater than zero")

# ---------------------------------------------------------------------------
# AllowedMentions
# ---------------------------------------------------------------------------

proc validateAllowedMentions(policy: AllowedMentions) =
  if policy.userIdsValue.len > MaxAllowedMentionIds:
    raise newException(ValueError,
      "allowed mentions cannot list more than " & $MaxAllowedMentionIds &
        " users")
  if policy.roleIdsValue.len > MaxAllowedMentionIds:
    raise newException(ValueError,
      "allowed mentions cannot list more than " & $MaxAllowedMentionIds &
        " roles")
  if ampUsers in policy.parseValue and policy.userIdsValue.len != 0:
    raise newException(ValueError,
      "allowed mentions cannot parse users and list explicit users")
  if ampRoles in policy.parseValue and policy.roleIdsValue.len != 0:
    raise newException(ValueError,
      "allowed mentions cannot parse roles and list explicit roles")

  var users = initHashSet[UserId]()
  for userId in policy.userIdsValue:
    userId.requireNonzero("allowed mention user ID")
    if userId in users:
      raise newException(ValueError,
        "allowed mention user IDs must be unique")
    users.incl(userId)

  var roles = initHashSet[RoleId]()
  for roleId in policy.roleIdsValue:
    roleId.requireNonzero("allowed mention role ID")
    if roleId in roles:
      raise newException(ValueError,
        "allowed mention role IDs must be unique")
    roles.incl(roleId)

proc initAllowedMentions*(parse: set[AllowedMentionParse] = {};
                          userIds: seq[UserId] = @[];
                          roleIds: seq[RoleId] = @[];
                          repliedUser = none(bool)): AllowedMentions =
  ## Builds a safe mention policy. The zero/default policy parses no mentions.
  result = AllowedMentions(
    parseValue: parse,
    userIdsValue: userIds,
    roleIdsValue: roleIds,
    repliedUserValue: repliedUser,
  )
  result.validateAllowedMentions()

proc toWire(policy: AllowedMentions): JsonNode =
  policy.validateAllowedMentions()
  result = newJObject()
  result["parse"] = newJArray()
  for value in AllowedMentionParse:
    if value in policy.parseValue:
      result["parse"].add(newJString(case value
        of ampUsers: "users"
        of ampRoles: "roles"
        of ampEveryone: "everyone"))
  if policy.userIdsValue.len != 0:
    result["users"] = newJArray()
    for userId in policy.userIdsValue:
      result["users"].add(newJString($userId))
  if policy.roleIdsValue.len != 0:
    result["roles"] = newJArray()
    for roleId in policy.roleIdsValue:
      result["roles"].add(newJString($roleId))
  if policy.repliedUserValue.isSome:
    result["replied_user"] = newJBool(policy.repliedUserValue.get)

proc toJson*(policy: AllowedMentions): JsonNode =
  ## Serializes a validated mention policy for a Discord message body.
  policy.toWire()

# ---------------------------------------------------------------------------
# MessageNonce
# ---------------------------------------------------------------------------

func integerNonce*(value: int64): MessageNonce =
  ## Wraps a 64-bit integer nonce.
  MessageNonce(kind: mnkInteger, integerValue: value)

func stringNonce*(value: string): MessageNonce =
  ## Wraps an opaque string nonce, rejecting an empty or overlong value.
  if value.validateUtf8 != -1:
    raise newException(ValueError, "message nonce must be valid UTF-8")
  if value.len == 0:
    raise newException(ValueError, "message nonce must not be empty")
  if value.runeLen > MaxNonceLength:
    raise newException(ValueError,
      "message nonce must not exceed " & $MaxNonceLength & " characters")
  MessageNonce(kind: mnkString, stringValue: value)

func toWire(nonce: MessageNonce): JsonNode =
  case nonce.kind
  of mnkInteger: newJInt(nonce.integerValue)
  of mnkString:
    if nonce.stringValue.validateUtf8 != -1 or nonce.stringValue.len == 0 or
        nonce.stringValue.runeLen > MaxNonceLength:
      raise newException(ValueError, "message nonce is no longer valid")
    newJString(nonce.stringValue)

func `$`*(nonce: MessageNonce): string =
  ## Never renders the underlying nonce value.
  discard nonce
  "MessageNonce(<hidden>)"

func repr*(nonce: MessageNonce): string =
  ## Returns the same value-free description as `$`.
  $nonce

# ---------------------------------------------------------------------------
# MessageReferenceRequest
# ---------------------------------------------------------------------------

func messageReferenceRequest*(messageId: MessageId;
                              channelId = none(ChannelId);
                              guildId = none(GuildId);
                              failIfNotExists = none(bool);
                              kind = mrReply): MessageReferenceRequest =
  ## Builds a reference to an existing message for replies and forwards.
  messageId.requireNonzero("referenced message ID")
  if channelId.isSome:
    channelId.get.requireNonzero("referenced channel ID")
  if guildId.isSome:
    guildId.get.requireNonzero("referenced guild ID")
  if kind == mrForward and channelId.isNone:
    raise newException(ValueError,
      "forward references require the source channel ID")
  MessageReferenceRequest(
    messageIdValue: messageId,
    channelIdValue: channelId,
    guildIdValue: guildId,
    failIfNotExistsValue: failIfNotExists,
    kindValue: kind,
  )

func toWire(reference: MessageReferenceRequest): JsonNode =
  reference.messageIdValue.requireNonzero("referenced message ID")
  if reference.channelIdValue.isSome:
    reference.channelIdValue.get.requireNonzero("referenced channel ID")
  if reference.guildIdValue.isSome:
    reference.guildIdValue.get.requireNonzero("referenced guild ID")
  if reference.kindValue == mrForward and reference.channelIdValue.isNone:
    raise newException(ValueError,
      "forward references require the source channel ID")
  result = newJObject()
  result["message_id"] = newJString($reference.messageIdValue)
  if reference.channelIdValue.isSome:
    result["channel_id"] = newJString($reference.channelIdValue.get)
  if reference.guildIdValue.isSome:
    result["guild_id"] = newJString($reference.guildIdValue.get)
  if reference.failIfNotExistsValue.isSome:
    result["fail_if_not_exists"] = newJBool(reference.failIfNotExistsValue.get)
  result["type"] = newJInt(ord(reference.kindValue))

# ---------------------------------------------------------------------------
# ReactionEmoji
# ---------------------------------------------------------------------------

func unicodeEmoji*(name: string): ReactionEmoji =
  ## Builds a Unicode reaction emoji from its glyph.
  if name.len == 0:
    raise newException(ValueError, "reaction emoji name must not be empty")
  ReactionEmoji(nameValue: name, idValue: none(EmojiId))

func customEmoji*(name: string; id: EmojiId): ReactionEmoji =
  ## Builds a custom reaction emoji from its name and snowflake.
  if name.len == 0:
    raise newException(ValueError, "custom reaction emoji name must not be empty")
  ReactionEmoji(nameValue: name, idValue: some(id))

func pathValue(emoji: ReactionEmoji): string =
  ## Returns the unencoded `name` or `name:id` path segment; the route renderer
  ## percent-encodes it.
  if emoji.nameValue.len == 0:
    raise newException(ValueError, "reaction emoji name must not be empty")
  if emoji.idValue.isSome:
    emoji.nameValue & ":" & $emoji.idValue.get
  else:
    emoji.nameValue

# ---------------------------------------------------------------------------
# Query values
# ---------------------------------------------------------------------------

proc validateHistoryCursor(before, after, around: bool) =
  var set = 0
  if before: inc set
  if after: inc set
  if around: inc set
  if set > 1:
    raise newException(ValueError,
      "message history accepts at most one of before, after, or around")

proc validateLimit(limit: Option[int]; lo, hi: int; label: string) =
  if limit.isSome and (limit.get < lo or limit.get > hi):
    raise newException(ValueError,
      label & " limit must be between " & $lo & " and " & $hi)

proc initMessageHistoryQuery*(before = none(MessageId);
                              after = none(MessageId);
                              around = none(MessageId);
                              limit = none(int)): MessageHistoryQuery =
  ## Builds a validated channel-history pagination value.
  validateHistoryCursor(before.isSome, after.isSome, around.isSome)
  validateLimit(limit, MinHistoryLimit, MaxHistoryLimit, "message history")
  MessageHistoryQuery(
    beforeValue: before,
    afterValue: after,
    aroundValue: around,
    limitValue: limit,
  )

proc initReactionQuery*(after = none(UserId);
                        limit = none(int);
                        kind = none(ReactionType)): ReactionQuery =
  ## Builds a validated reaction-voter pagination value.
  validateLimit(limit, MinReactionLimit, MaxReactionLimit, "reaction")
  ReactionQuery(afterValue: after, limitValue: limit, typeValue: kind)

proc initPollVoterQuery*(after = none(UserId);
                         limit = none(int)): PollVoterQuery =
  ## Builds a validated poll-voter pagination value.
  validateLimit(limit, MinReactionLimit, MaxReactionLimit, "poll voter")
  PollVoterQuery(afterValue: after, limitValue: limit)

proc initPinQuery*(before = none(string);
                   limit = none(int)): PinQuery =
  ## Builds a validated pins pagination value; `before` is an ISO-8601 instant.
  if before.isSome and not isRfc3339(before.get):
    raise newException(ValueError, "pin cursor must be an RFC 3339 timestamp")
  validateLimit(limit, MinPinLimit, MaxPinLimit, "pin")
  PinQuery(beforeValue: before, limitValue: limit)

proc addOptional[T](raw: var raw_request.RawRequest; name: string;
                    value: Option[T]) =
  if value.isSome:
    raw.addQuery(name, $value.get)

proc apply(raw: var raw_request.RawRequest; query: MessageHistoryQuery) =
  validateHistoryCursor(query.beforeValue.isSome, query.afterValue.isSome,
    query.aroundValue.isSome)
  validateLimit(query.limitValue, MinHistoryLimit, MaxHistoryLimit,
    "message history")
  raw.addOptional("before", query.beforeValue)
  raw.addOptional("after", query.afterValue)
  raw.addOptional("around", query.aroundValue)
  raw.addOptional("limit", query.limitValue)

proc apply(raw: var raw_request.RawRequest; query: ReactionQuery) =
  validateLimit(query.limitValue, MinReactionLimit, MaxReactionLimit,
    "reaction")
  raw.addOptional("after", query.afterValue)
  raw.addOptional("limit", query.limitValue)
  if query.typeValue.isSome:
    raw.addQuery("type", $ord(query.typeValue.get))

proc apply(raw: var raw_request.RawRequest; query: PollVoterQuery) =
  validateLimit(query.limitValue, MinReactionLimit, MaxReactionLimit,
    "poll voter")
  raw.addOptional("after", query.afterValue)
  raw.addOptional("limit", query.limitValue)

proc apply(raw: var raw_request.RawRequest; query: PinQuery) =
  if query.beforeValue.isSome and not isRfc3339(query.beforeValue.get):
    raise newException(ValueError, "pin cursor must be an RFC 3339 timestamp")
  validateLimit(query.limitValue, MinPinLimit, MaxPinLimit, "pin")
  raw.addOptional("before", query.beforeValue)
  raw.addOptional("limit", query.limitValue)

# ---------------------------------------------------------------------------
# Create bodies
# ---------------------------------------------------------------------------

func legacyCreate*(draft: MessageDraft[Legacy];
                   tts = false;
                   nonce = none(MessageNonce);
                   enforceNonce = false;
                   reference = none(MessageReferenceRequest);
                   flags = none(int64);
                   poll = none(PollCreate);
                   allowedMentions = initAllowedMentions()):
                   MessageCreate[Legacy] =
  ## Builds a legacy message-create body. `poll` accepts a validated
  ## `PollCreate` directly, never a raw JSON document.
  flags.validateFlags(messageCreateFlagMask, "message create flags",
    rejectV2 = true)
  if enforceNonce and nonce.isNone:
    raise newException(ValueError,
      "enforceNonce requires a message nonce")
  allowedMentions.validateAllowedMentions()
  MessageCreate[Legacy](
    draftValue: draft,
    ttsValue: tts,
    nonceValue: nonce,
    enforceNonceValue: enforceNonce,
    referenceValue: reference,
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
    pollValue: poll,
  )

func v2Create*(draft: MessageDraft[V2];
               tts = false;
               nonce = none(MessageNonce);
               enforceNonce = false;
               reference = none(MessageReferenceRequest);
               flags = none(int64);
               allowedMentions = initAllowedMentions()): MessageCreate[V2] =
  ## Builds a Components V2 message-create body with no legacy content fields.
  flags.validateFlags(messageCreateFlagMask, "message create flags")
  if enforceNonce and nonce.isNone:
    raise newException(ValueError,
      "enforceNonce requires a message nonce")
  allowedMentions.validateAllowedMentions()
  MessageCreate[V2](
    draftValue: draft,
    ttsValue: tts,
    nonceValue: nonce,
    enforceNonceValue: enforceNonce,
    referenceValue: reference,
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
  )

proc applyCommonCreate(body: JsonNode; create: MessageCreate) =
  if create.enforceNonceValue and create.nonceValue.isNone:
    raise newException(ValueError,
      "enforceNonce requires a message nonce")
  if create.ttsValue:
    body["tts"] = newJBool(true)
  if create.nonceValue.isSome:
    body["nonce"] = create.nonceValue.get.toWire()
    if create.enforceNonceValue:
      body["enforce_nonce"] = newJBool(true)
  if create.referenceValue.isSome:
    body["message_reference"] = create.referenceValue.get.toWire()
  body["allowed_mentions"] = create.allowedMentionsValue.toWire()

proc validateLegacyPayload(body: JsonNode; label: string;
                           allowForwardOnly = false) =
  if body.hasKey("content"):
    if body["content"].kind != JString:
      raise newException(ValueError, label & " content must be a string")
    body["content"].getStr.validateText(label & " content",
      MaxMessageContentLength)
  for name in ["embeds", "sticker_ids", "components"]:
    if body.hasKey(name) and body[name].kind != JArray:
      raise newException(ValueError, label & " " & name & " must be an array")
  if body.hasKey("embeds"):
    if body["embeds"].len > 10:
      raise newException(ValueError, label & " cannot contain more than 10 embeds")
    for embed in body["embeds"]:
      if embed.kind != JObject:
        raise newException(ValueError, label & " embeds must be JSON objects")
  if body.hasKey("sticker_ids") and body["sticker_ids"].len > 3:
    raise newException(ValueError,
      label & " cannot contain more than 3 sticker IDs")

  let hasContent = body.hasKey("content") and
    body["content"].kind == JString and body["content"].getStr.len != 0
  let hasEmbeds = body.hasKey("embeds") and body["embeds"].len != 0
  let hasStickers = body.hasKey("sticker_ids") and
    body["sticker_ids"].len != 0
  let hasComponents = body.hasKey("components") and
    body["components"].len != 0
  let hasPoll = body.hasKey("poll") and body["poll"].kind == JObject
  let hasForward = allowForwardOnly and body.hasKey("message_reference") and
    body["message_reference"].kind == JObject and
    body["message_reference"].hasKey("type") and
    body["message_reference"]["type"].getInt() == ord(mrForward)
  if not (hasContent or hasEmbeds or hasStickers or hasComponents or hasPoll or
      hasForward):
    raise newException(ValueError, label & " requires message content")

proc toWire(create: MessageCreate[Legacy]): JsonNode =
  create.flagsValue.validateFlags(messageCreateFlagMask,
    "message create flags", rejectV2 = true)
  for stickerId in create.draftValue.legacy.stickers:
    stickerId.requireNonzero("message create sticker ID")
  result = create.draftValue.toJson()
  result.applyCommonCreate(create)
  if create.pollValue.isSome:
    result["poll"] = create.pollValue.get.toJson()
  if create.flagsValue.isSome:
    result["flags"] = newJInt(create.flagsValue.get)
  result.validateLegacyPayload("message create", allowForwardOnly = true)

proc toWire(create: MessageCreate[V2]): JsonNode =
  create.flagsValue.validateFlags(messageCreateFlagMask,
    "message create flags")
  result = create.draftValue.toJson()
  result.applyCommonCreate(create)
  # The Components V2 flag is permanent; a caller-supplied flag set never clears
  # it, so the two are combined.
  if create.flagsValue.isSome:
    result["flags"] = newJInt(create.flagsValue.get or componentsV2Flag)
  else:
    result["flags"] = newJInt(componentsV2Flag)

func createIdempotency(create: MessageCreate): Idempotency =
  ## A message create is retryable only when a valid nonce is enforced.
  if create.nonceValue.isSome and create.enforceNonceValue:
    idWithNonce
  else:
    idNever

# ---------------------------------------------------------------------------
# Edit bodies
# ---------------------------------------------------------------------------

proc legacyEdit*(content = editOmit(string);
                 components = editOmit(seq[ComponentNode]);
                 stickerIds = editOmit(seq[StickerId]);
                 flags = none(int64);
                 allowedMentions = initAllowedMentions()): MessageEdit[Legacy] =
  ## Builds a legacy message-edit body honoring omit versus clear per field.
  flags.validateFlags(messageEditFlagMask, "message edit flags",
    rejectV2 = true)
  if content.isSet:
    editValue(content).validateText("message edit content",
      MaxMessageContentLength)
  if components.isSet:
    discard legacyMessage(components = editValue(components)).toJson()
  if stickerIds.isSet:
    if editValue(stickerIds).len > 3:
      raise newException(ValueError,
        "message edit cannot contain more than 3 sticker IDs")
    for stickerId in editValue(stickerIds):
      stickerId.requireNonzero("message edit sticker ID")
  allowedMentions.validateAllowedMentions()
  MessageEdit[Legacy](
    contentValue: content,
    componentsValue: components,
    stickerIdsValue: stickerIds,
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
  )

proc v2Edit*(components: seq[ComponentNode]; flags = none(int64);
             allowedMentions = initAllowedMentions()): MessageEdit[V2] =
  ## Builds a V2 edit or one-way upgrade with explicit legacy-field resets.
  flags.validateFlags(messageEditFlagMask, "message edit flags")
  discard v2Draft(components).toJson()
  allowedMentions.validateAllowedMentions()
  MessageEdit[V2](
    componentsValue: editSet(components),
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
  )

proc legacyComponentsJson(nodes: seq[ComponentNode]): JsonNode =
  let validated = legacyMessage(components = nodes).toJson()
  validated["components"]

proc toWire(edit: MessageEdit[Legacy]): JsonNode =
  edit.flagsValue.validateFlags(messageEditFlagMask, "message edit flags",
    rejectV2 = true)
  result = newJObject()
  if edit.contentValue.isClear:
    result["content"] = newJNull()
  elif edit.contentValue.isSet:
    editValue(edit.contentValue).validateText("message edit content",
      MaxMessageContentLength)
    result["content"] = newJString(editValue(edit.contentValue))
  if edit.componentsValue.isClear:
    result["components"] = newJNull()
  elif edit.componentsValue.isSet:
    result["components"] = legacyComponentsJson(editValue(edit.componentsValue))
  if edit.stickerIdsValue.isClear:
    result["sticker_ids"] = newJNull()
  elif edit.stickerIdsValue.isSet:
    if editValue(edit.stickerIdsValue).len > 3:
      raise newException(ValueError,
        "message edit cannot contain more than 3 sticker IDs")
    var ids = newJArray()
    for stickerId in editValue(edit.stickerIdsValue):
      stickerId.requireNonzero("message edit sticker ID")
      ids.add(newJString($stickerId))
    result["sticker_ids"] = ids
  if edit.flagsValue.isSome:
    result["flags"] = newJInt(edit.flagsValue.get)
  result["allowed_mentions"] = edit.allowedMentionsValue.toWire()

proc toWire(edit: MessageEdit[V2]): JsonNode =
  result = newJObject()
  if not edit.componentsValue.isSet:
    raise newException(ValueError, "Components V2 edit requires components")
  let validated = v2Draft(editValue(edit.componentsValue)).toJson()
  result["components"] = validated["components"]
  result["content"] = newJNull()
  result["embeds"] = newJArray()
  result["sticker_ids"] = newJArray()
  result["poll"] = newJNull()
  result["allowed_mentions"] = edit.allowedMentionsValue.toWire()
  edit.flagsValue.validateFlags(messageEditFlagMask, "message edit flags")
  if edit.flagsValue.isSome:
    result["flags"] = newJInt(edit.flagsValue.get or componentsV2Flag)
  else:
    result["flags"] = newJInt(componentsV2Flag)

# ---------------------------------------------------------------------------
# Bulk delete
# ---------------------------------------------------------------------------

proc bulkDeleteBody(ids: openArray[MessageId]): JsonNode =
  if ids.len < MinBulkDeleteMessages or ids.len > MaxBulkDeleteMessages:
    raise newException(ValueError,
      "bulk delete requires between " & $MinBulkDeleteMessages & " and " &
        $MaxBulkDeleteMessages & " message IDs")
  var seen = initHashSet[MessageId]()
  var array = newJArray()
  for id in ids:
    if id in seen:
      raise newException(ValueError,
        "bulk delete message IDs must be unique")
    seen.incl(id)
    array.add(newJString($id))
  result = newJObject()
  result["messages"] = array

# ---------------------------------------------------------------------------
# Decoders
# ---------------------------------------------------------------------------

proc decodePinnedMessage(node: JsonNode): PinnedMessage =
  let obj = ensureObject(node, "pinned message")
  result.pinnedAt = decodeTimestamp(
    requireField(obj, "pinned_at", "pinned message"), "pinned message.pinned_at")
  result.message = decodeMessage(
    requireField(obj, "message", "pinned message"))

proc decodePinnedMessages(node: JsonNode): PinnedMessages =
  let obj = ensureObject(node, "pinned messages")
  for item in asArray(requireField(obj, "items", "pinned messages"),
      "pinned messages.items"):
    result.items.add(decodePinnedMessage(item))
  result.hasMore = asBool(
    requireField(obj, "has_more", "pinned messages"), "pinned messages.has_more")

proc decodePollVoters(node: JsonNode): seq[User] =
  let obj = ensureObject(node, "poll answer voters")
  for user in asArray(requireField(obj, "users", "poll answer voters"),
      "poll answer voters.users"):
    result.add(decodeUser(user))

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

proc listMessages*(client: ChronosRestClient;
                   channelId: ChannelId;
                   query = initMessageHistoryQuery();
                   options = initApiCallOptions()):
                   Future[seq[Message]] {.async.} =
  ## Lists channel messages matching a bounded history query.
  var raw = raw_request.initRawRequest(channel_routes.listMessages, [
    initRawParameter("channel_id", $channelId),
  ])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeMessage,
    auth = darBot, meta = options.requestMeta(idSafe), allowNull = true)

proc fetchMessage*(client: ChronosRestClient;
                   channelId: ChannelId;
                   messageId: MessageId;
                   options = initApiCallOptions()): Future[Message] {.async.} =
  ## Fetches a single message.
  let raw = raw_request.initRawRequest(channel_routes.getMessage, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
  ])
  return await client.executeJson(raw, decodeMessage,
    auth = darBot, meta = options.requestMeta(idSafe))

proc createMessage*[Mode](client: ChronosRestClient;
                          channelId: ChannelId;
                          create: MessageCreate[Mode];
                          options = initApiCallOptions()):
                          Future[Message] {.async.} =
  ## Posts a message. The request is retryable only with an enforced nonce.
  let raw = raw_request.initRawRequest(channel_routes.createMessage, [
    initRawParameter("channel_id", $channelId),
  ], create.toWire())
  return await client.executeJson(raw, decodeMessage,
    auth = darBot, meta = options.requestMeta(create.createIdempotency()))

proc editMessageImpl[Mode](client: ChronosRestClient;
                           channelId: ChannelId;
                           messageId: MessageId;
                           edit: MessageEdit[Mode];
                           options: ApiCallOptions):
                           Future[Message] {.async.} =
  let raw = raw_request.initRawRequest(channel_routes.updateMessage, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
  ], edit.toWire())
  return await client.executeJson(raw, decodeMessage,
    auth = darBot, meta = options.requestMeta(idSafe))

proc editMessage*[Mode](client: ChronosRestClient;
                        handle: MessageHandle[Mode];
                        edit: MessageEdit[Mode];
                        options = initApiCallOptions()):
                        Future[Message] {.async.} =
  ## Edits a message whose statically known mode matches the edit body.
  return await client.editMessageImpl(handle.channelId, handle.messageId, edit,
    options)

proc upgradeMessageToV2*(client: ChronosRestClient;
                         handle: MessageHandle[Legacy];
                         edit: MessageEdit[V2];
                         options = initApiCallOptions()):
                         Future[Message] {.async.} =
  ## Irreversibly upgrades a legacy message after sending explicit resets.
  return await client.editMessageImpl(handle.channelId, handle.messageId, edit,
    options)

proc deleteMessage*(client: ChronosRestClient;
                    channelId: ChannelId;
                    messageId: MessageId;
                    options = initApiCallOptions()): Future[void] {.async.} =
  ## Deletes a message; deletion is idempotent.
  let raw = raw_request.initRawRequest(channel_routes.deleteMessage, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
  ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc crosspostMessage*(client: ChronosRestClient;
                       channelId: ChannelId;
                       messageId: MessageId;
                       options = initApiCallOptions()):
                       Future[Message] {.async.} =
  ## Publishes an announcement-channel message; publishing is not retryable.
  let raw = raw_request.initRawRequest(channel_routes.crosspostMessage, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
  ])
  return await client.executeJson(raw, decodeMessage,
    auth = darBot, meta = options.requestMeta(idNever))

proc bulkDeleteMessages*(client: ChronosRestClient;
                         channelId: ChannelId;
                         messageIds: seq[MessageId];
                         options = initApiCallOptions()):
                         Future[void] {.async.} =
  ## Deletes 2..100 unique messages in one request.
  let raw = raw_request.initRawRequest(channel_routes.bulkDeleteMessages, [
    initRawParameter("channel_id", $channelId),
  ], bulkDeleteBody(messageIds))
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idNever))

proc listPollAnswerVoters*(client: ChronosRestClient;
                           channelId: ChannelId;
                           messageId: MessageId;
                           answerId: PollAnswerId;
                           query = initPollVoterQuery();
                           options = initApiCallOptions()):
                           Future[seq[User]] {.async.} =
  ## Lists users who voted for one answer of a poll message.
  var raw = raw_request.initRawRequest(channel_routes.getAnswerVoters, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
    initRawParameter("answer_id", $answerId),
  ])
  raw.apply(query)
  return await client.executeJson(raw, decodePollVoters,
    auth = darBot, meta = options.requestMeta(idSafe))

proc endPoll*(client: ChronosRestClient;
              channelId: ChannelId;
              messageId: MessageId;
              options = initApiCallOptions()): Future[Message] {.async.} =
  ## Ends a poll immediately. The action is not retried automatically.
  let raw = raw_request.initRawRequest(channel_routes.pollExpire, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
  ])
  return await client.executeJson(raw, decodeMessage,
    auth = darBot, meta = options.requestMeta(idNever))

proc listPins*(client: ChronosRestClient;
               channelId: ChannelId;
               query = initPinQuery();
               options = initApiCallOptions()):
               Future[PinnedMessages] {.async.} =
  ## Lists a channel's pins through the current pins endpoint.
  var raw = raw_request.initRawRequest(channel_routes.listPins, [
    initRawParameter("channel_id", $channelId),
  ])
  raw.apply(query)
  return await client.executeJson(raw, decodePinnedMessages,
    auth = darBot, meta = options.requestMeta(idSafe))

proc pinMessage*(client: ChronosRestClient;
                 channelId: ChannelId;
                 messageId: MessageId;
                 options = initApiCallOptions()): Future[void] {.async.} =
  ## Pins a message through the current pins endpoint.
  let raw = raw_request.initRawRequest(channel_routes.createPin, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
  ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc unpinMessage*(client: ChronosRestClient;
                   channelId: ChannelId;
                   messageId: MessageId;
                   options = initApiCallOptions()): Future[void] {.async.} =
  ## Unpins a message through the current pins endpoint.
  let raw = raw_request.initRawRequest(channel_routes.deletePin, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
  ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc addReaction*(client: ChronosRestClient;
                  channelId: ChannelId;
                  messageId: MessageId;
                  emoji: ReactionEmoji;
                  options = initApiCallOptions()): Future[void] {.async.} =
  ## Adds the current user's reaction; adding is idempotent.
  let raw = raw_request.initRawRequest(channel_routes.addMyMessageReaction, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
    initRawParameter("emoji_name", emoji.pathValue()),
  ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc removeOwnReaction*(client: ChronosRestClient;
                        channelId: ChannelId;
                        messageId: MessageId;
                        emoji: ReactionEmoji;
                        options = initApiCallOptions()):
                        Future[void] {.async.} =
  ## Removes the current user's reaction; removal is idempotent.
  let raw = raw_request.initRawRequest(channel_routes.deleteMyMessageReaction, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
    initRawParameter("emoji_name", emoji.pathValue()),
  ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc removeUserReaction*(client: ChronosRestClient;
                         channelId: ChannelId;
                         messageId: MessageId;
                         emoji: ReactionEmoji;
                         userId: UserId;
                         options = initApiCallOptions()):
                         Future[void] {.async.} =
  ## Removes another user's reaction; removal is idempotent.
  let raw = raw_request.initRawRequest(channel_routes.deleteUserMessageReaction, [
    initRawParameter("channel_id", $channelId),
    initRawParameter("message_id", $messageId),
    initRawParameter("emoji_name", emoji.pathValue()),
    initRawParameter("user_id", $userId),
  ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc listReactions*(client: ChronosRestClient;
                    channelId: ChannelId;
                    messageId: MessageId;
                    emoji: ReactionEmoji;
                    query = initReactionQuery();
                    options = initApiCallOptions()):
                    Future[seq[User]] {.async.} =
  ## Lists the users who reacted with one emoji.
  var raw = raw_request.initRawRequest(
    channel_routes.listMessageReactionsByEmoji, [
      initRawParameter("channel_id", $channelId),
      initRawParameter("message_id", $messageId),
      initRawParameter("emoji_name", emoji.pathValue()),
    ])
  raw.apply(query)
  return await client.executeJsonArray(raw, decodeUser,
    auth = darBot, meta = options.requestMeta(idSafe))

proc clearReactions*(client: ChronosRestClient;
                     channelId: ChannelId;
                     messageId: MessageId;
                     options = initApiCallOptions()): Future[void] {.async.} =
  ## Removes every reaction from a message; clearing is idempotent.
  let raw = raw_request.initRawRequest(
    channel_routes.deleteAllMessageReactions, [
      initRawParameter("channel_id", $channelId),
      initRawParameter("message_id", $messageId),
    ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc clearReactionsByEmoji*(client: ChronosRestClient;
                            channelId: ChannelId;
                            messageId: MessageId;
                            emoji: ReactionEmoji;
                            options = initApiCallOptions()):
                            Future[void] {.async.} =
  ## Removes every reaction of one emoji; clearing is idempotent.
  let raw = raw_request.initRawRequest(
    channel_routes.deleteAllMessageReactionsByEmoji, [
      initRawParameter("channel_id", $channelId),
      initRawParameter("message_id", $messageId),
      initRawParameter("emoji_name", emoji.pathValue()),
    ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))
