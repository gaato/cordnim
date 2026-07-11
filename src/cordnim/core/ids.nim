## Type-safe Discord snowflake identifiers.

import std/hashes

type
  Id*[Kind] = distinct uint64 ## A Discord snowflake whose resource kind is checked at compile time.

  ApplicationKind* = object ## Type marker for Discord applications.
  AttachmentKind* = object ## Type marker for message attachments.
  AuditLogEntryKind* = object ## Type marker for audit-log entries.
  ChannelKind* = object ## Type marker for channels and threads.
  ApplicationCommandKind* = object ## Type marker for application commands.
  EmojiKind* = object ## Type marker for custom emoji.
  EntitlementKind* = object ## Type marker for application entitlements.
  GuildKind* = object ## Type marker for guilds.
  IntegrationKind* = object ## Type marker for guild integrations.
  InteractionKind* = object ## Type marker for interactions.
  MessageKind* = object ## Type marker for messages.
  RoleKind* = object ## Type marker for guild roles.
  ScheduledEventKind* = object ## Type marker for guild scheduled events.
  SkuKind* = object ## Type marker for application SKUs.
  SoundboardSoundKind* = object ## Type marker for soundboard sounds.
  StageInstanceKind* = object ## Type marker for stage instances.
  StickerKind* = object ## Type marker for stickers.
  SubscriptionKind* = object ## Type marker for SKU subscriptions.
  UserKind* = object ## Type marker for Discord users.
  WebhookKind* = object ## Type marker for webhooks.

  ApplicationId* = Id[ApplicationKind] ## Snowflake identifying an application.
  AttachmentId* = Id[AttachmentKind] ## Snowflake identifying an attachment.
  AuditLogEntryId* = Id[AuditLogEntryKind] ## Snowflake identifying an audit-log entry.
  ChannelId* = Id[ChannelKind] ## Snowflake identifying a channel or thread.
  CommandId* = Id[ApplicationCommandKind] ## Snowflake identifying an application command.
  EmojiId* = Id[EmojiKind] ## Snowflake identifying a custom emoji.
  EntitlementId* = Id[EntitlementKind] ## Snowflake identifying an entitlement.
  GuildId* = Id[GuildKind] ## Snowflake identifying a guild.
  IntegrationId* = Id[IntegrationKind] ## Snowflake identifying an integration.
  InteractionId* = Id[InteractionKind] ## Snowflake identifying an interaction.
  MessageId* = Id[MessageKind] ## Snowflake identifying a message.
  RoleId* = Id[RoleKind] ## Snowflake identifying a role.
  ScheduledEventId* = Id[ScheduledEventKind] ## Snowflake identifying a scheduled event.
  SkuId* = Id[SkuKind] ## Snowflake identifying an application SKU.
  SoundboardSoundId* = Id[SoundboardSoundKind] ## Snowflake identifying a soundboard sound.
  StageInstanceId* = Id[StageInstanceKind] ## Snowflake identifying a stage instance.
  StickerId* = Id[StickerKind] ## Snowflake identifying a sticker.
  SubscriptionId* = Id[SubscriptionKind] ## Snowflake identifying a SKU subscription.
  UserId* = Id[UserKind] ## Snowflake identifying a Discord user.
  WebhookId* = Id[WebhookKind] ## Snowflake identifying a webhook.

func toId*[Kind](value: uint64): Id[Kind] {.inline.} =
  ## Explicitly wraps an integer at a protocol boundary.
  Id[Kind](value)

func toId*[Kind](idType: typedesc[Id[Kind]];
    value: uint64): Id[Kind] {.inline.} =
  ## Explicitly wraps an integer using a semantic ID alias.
  Id[Kind](value)

func toUint64*[Kind](id: Id[Kind]): uint64 {.inline.} =
  ## Returns the wire representation of `id`.
  uint64(id)

proc parseId*[Kind](text: string): Id[Kind] =
  ## Parses an unsigned decimal Discord snowflake.
  ##
  ## Empty input, signs, whitespace, non-digits, and overflow are rejected.
  if text.len == 0:
    raise newException(ValueError, "Discord ID must not be empty")

  var value = 0'u64
  for character in text:
    if character notin {'0'..'9'}:
      raise newException(ValueError,
        "Discord ID must contain only decimal digits")

    let digit = uint64(ord(character) - ord('0'))
    if value > (high(uint64) - digit) div 10'u64:
      raise newException(ValueError, "Discord ID exceeds uint64")
    value = value * 10'u64 + digit

  result = Id[Kind](value)

proc parseId*[Kind](idType: typedesc[Id[Kind]];
    text: string): Id[Kind] =
  ## Parses an ID using a semantic ID alias, for example `UserId`.
  parseId[Kind](text)

func `==`*[Kind](left, right: Id[Kind]): bool {.inline.} =
  ## Compares IDs only when their resource kind is the same.
  uint64(left) == uint64(right)

func `<`*[Kind](left, right: Id[Kind]): bool {.inline.} =
  ## Orders IDs of the same resource kind by their wire value.
  uint64(left) < uint64(right)

func `<=`*[Kind](left, right: Id[Kind]): bool {.inline.} =
  ## Orders IDs of the same resource kind by their wire value.
  uint64(left) <= uint64(right)

func cmp*[Kind](left, right: Id[Kind]): int {.inline.} =
  ## Three-way compares IDs of the same resource kind.
  cmp(uint64(left), uint64(right))

func hash*[Kind](id: Id[Kind]): Hash {.inline.} =
  ## Hashes the snowflake's wire value for typed table keys.
  hash(uint64(id))

func `$`*[Kind](id: Id[Kind]): string =
  ## Formats the snowflake in Discord's unsigned decimal wire form.
  $uint64(id)
