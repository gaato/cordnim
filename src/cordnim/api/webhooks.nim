## Semantic webhook REST operations over the supervised REST client.
##
## A `WebhookEndpoint` binds a `WebhookId` to a `Secret[WebhookToken]`. Its
## display, `repr`, and JSON forms are redacted and there is no plaintext token
## accessor; the token is revealed only while rendering a raw request path. The
## GitHub- and Slack-compatible ingestion routes stay raw-only, and multipart
## attachment uploads remain available through the raw escape hatch.

import std/[json, options, sets, strutils, unicode, uri]

import chronos

import cordnim/api/internal/execute
import cordnim/api/messages
import cordnim/api/options
import cordnim/core/ids
import cordnim/core/secrets
import cordnim/models/webhook
import cordnim/components/model
import cordnim/components/serialization
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/webhooks as webhook_routes
import cordnim/raw/routes/channels as channel_routes
import cordnim/raw/routes/guilds as guild_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

export webhook
export messages

const
  MinWebhookNameLength* = 1 ## Fewest characters a webhook name may have.
  MaxWebhookNameLength* = 80 ## Most characters a webhook name may have.
  MaxWebhookAvatarUrlLength* = 2_048 ## Longest avatar URL Discord accepts.
  MaxWebhookThreadNameLength* = 100 ## Longest created thread name.
  MaxWebhookAppliedTags* = 5 ## Most forum tags applied to a new thread.

  webhookSuppressEmbedsFlag = 1'i64 shl 2
  webhookSuppressNotificationsFlag = 1'i64 shl 12
  webhookComponentsV2Flag = 1'i64 shl 15
  webhookExecuteFlagMask = webhookSuppressEmbedsFlag or
    webhookSuppressNotificationsFlag or webhookComponentsV2Flag
  webhookEditFlagMask = webhookSuppressEmbedsFlag or webhookComponentsV2Flag

type
  WebhookEndpoint* = object ## A webhook identity paired with its secret token.
    ## The token never appears in `$`, `repr`, or JSON, and no accessor reveals
    ## it. It is rendered only into a raw request path at the transport boundary.
    webhookIdValue: WebhookId
    tokenValue: Secret[WebhookToken]

  WebhookMessageHandle*[Mode: Legacy | V2] = object ## A webhook message whose
    ## mode is known statically.
    endpointValue: WebhookEndpoint
    messageIdValue: MessageId

  WebhookExecute*[Mode: Legacy | V2] = object ## A validated webhook-execute
    ## body. Components V2 drafts still forbid legacy content fields.
    draftValue: MessageDraft[Mode]
    ttsValue: bool
    usernameValue: Option[string]
    avatarUrlValue: Option[string]
    threadNameValue: Option[string]
    appliedTagsValue: seq[ForumTagId]
    allowedMentionsValue: AllowedMentions
    flagsValue: Option[int64]
    when Mode is Legacy:
      pollValue: Option[PollCreate]

  WebhookMessageEdit*[Mode: Legacy | V2] = object ## A validated webhook message
    ## edit honoring omit versus clear per field.
    componentsValue: FieldEdit[seq[ComponentNode]]
    allowedMentionsValue: AllowedMentions
    flagsValue: Option[int64]
    when Mode is Legacy:
      contentValue: FieldEdit[string]
      pollValue: FieldEdit[PollCreate]

# ---------------------------------------------------------------------------
# WebhookEndpoint
# ---------------------------------------------------------------------------

func webhookEndpoint*(webhookId: WebhookId;
                      token: Secret[WebhookToken]): WebhookEndpoint =
  ## Builds an endpoint from an ID and an already-wrapped secret token.
  if webhookId.toUint64() == 0:
    raise newException(ValueError, "webhook ID must be greater than zero")
  if token.isEmpty:
    raise newException(ValueError, "webhook token must not be empty")
  WebhookEndpoint(webhookIdValue: webhookId, tokenValue: token)

func webhookEndpoint*(webhookId: WebhookId;
                      token: sink string): WebhookEndpoint =
  ## Builds an endpoint, wrapping a plaintext token at the input boundary.
  if webhookId.toUint64() == 0:
    raise newException(ValueError, "webhook ID must be greater than zero")
  if token.len == 0:
    raise newException(ValueError, "webhook token must not be empty")
  WebhookEndpoint(
    webhookIdValue: webhookId,
    tokenValue: initSecret[WebhookToken](token),
  )

func webhookId*(endpoint: WebhookEndpoint): WebhookId =
  ## Returns the endpoint's webhook ID; the token has no public accessor.
  endpoint.webhookIdValue

func `$`*(endpoint: WebhookEndpoint): string =
  ## Renders the ID and a redacted token marker.
  "WebhookEndpoint(id: " & $endpoint.webhookIdValue & ", token: " &
    redactedSecret & ")"

func repr*(endpoint: WebhookEndpoint): string =
  ## Returns the same redacted description as `$`.
  $endpoint

proc `%`*(endpoint: WebhookEndpoint): JsonNode =
  ## Serializes the ID and a redacted token placeholder.
  %*{"id": $endpoint.webhookIdValue, "token": redactedSecret}

proc toJsonHook*(endpoint: WebhookEndpoint): JsonNode =
  ## Redacts endpoints serialized through `std/jsonutils`.
  %endpoint

func idParameter(endpoint: WebhookEndpoint): RawParameter =
  initRawParameter("webhook_id", $endpoint.webhookIdValue)

func tokenParameter(endpoint: WebhookEndpoint): RawParameter =
  ## The only place a webhook token is revealed, for the raw path boundary.
  if endpoint.webhookIdValue.toUint64() == 0:
    raise newException(ValueError, "webhook ID must be greater than zero")
  if endpoint.tokenValue.isEmpty:
    raise newException(ValueError, "webhook token must not be empty")
  initRawParameter("webhook_token", endpoint.tokenValue.reveal())

func webhookMessageHandle*[Mode](endpoint: WebhookEndpoint;
                                 messageId: MessageId):
                                 WebhookMessageHandle[Mode] =
  ## Binds an existing webhook message to its statically known wire mode.
  if messageId.toUint64() == 0:
    raise newException(ValueError,
      "webhook message ID must be greater than zero")
  if endpoint.webhookIdValue.toUint64() == 0 or endpoint.tokenValue.isEmpty:
    raise newException(ValueError, "webhook endpoint is not initialized")
  WebhookMessageHandle[Mode](
    endpointValue: endpoint,
    messageIdValue: messageId,
  )

func messageId*[Mode](handle: WebhookMessageHandle[Mode]): MessageId =
  ## Returns the webhook message ID without exposing its endpoint token.
  handle.messageIdValue

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

proc addOptional[T](raw: var raw_request.RawRequest; name: string;
                    value: Option[T]) =
  if value.isSome:
    raw.addQuery(name, $value.get)

proc applyWithComponents[Mode](raw: var raw_request.RawRequest;
                               requested: Option[bool]) =
  when Mode is V2:
    if requested.isSome and not requested.get:
      raise newException(ValueError,
        "Components V2 webhook calls require withComponents=true")
    raw.addQuery("with_components", "true")
  else:
    raw.addOptional("with_components", requested)

proc validateThreadId(threadId: Option[ChannelId]) =
  if threadId.isSome and threadId.get.toUint64() == 0:
    raise newException(ValueError,
      "webhook thread ID must be greater than zero")

proc validateThreadTarget[Mode](execute: WebhookExecute[Mode];
                                threadId: Option[ChannelId]) =
  threadId.validateThreadId()
  if threadId.isSome and execute.threadNameValue.isSome:
    raise newException(ValueError,
      "webhook threadId and threadName are mutually exclusive")

proc validateWebhookText(value, label: string; maxRunes: int;
                         allowEmpty = false) =
  if value.validateUtf8 != -1:
    raise newException(ValueError, label & " must be valid UTF-8")
  if not allowEmpty and value.len == 0:
    raise newException(ValueError, label & " must not be empty")
  if value.runeLen > maxRunes:
    raise newException(ValueError,
      label & " must not exceed " & $maxRunes & " characters")

proc validateWebhookName(name: string) =
  name.validateWebhookText("webhook name", MaxWebhookNameLength)
  if name.strip.len == 0:
    raise newException(ValueError, "webhook name must not be blank")
  let normalized = name.toLowerAscii()
  if "clyde" in normalized or "discord" in normalized:
    raise newException(ValueError,
      "webhook name cannot contain clyde or discord")

proc validateWebhookUsername(username: string) =
  username.validateWebhookText("webhook username", MaxWebhookNameLength)
  if username.strip.len == 0:
    raise newException(ValueError, "webhook username must not be blank")

proc validateWebhookThreadName(threadName: string) =
  threadName.validateWebhookText("webhook thread name",
    MaxWebhookThreadNameLength)
  if threadName.strip.len == 0:
    raise newException(ValueError, "webhook thread name must not be blank")

proc validateWebhookFlags(flags: Option[int64]; allowedMask: int64;
                          label: string; rejectV2 = false) =
  if flags.isNone:
    return
  let value = flags.get
  if value < 0 or (value and not allowedMask) != 0:
    raise newException(ValueError, label & " contains unsupported flag bits")
  if rejectV2 and (value and webhookComponentsV2Flag) != 0:
    raise newException(ValueError,
      label & " cannot enable Components V2 on a legacy body")

proc validateAvatarUrl(value: string) =
  value.validateWebhookText("webhook avatar URL", MaxWebhookAvatarUrlLength)
  let parsed = parseUri(value)
  if parsed.scheme.toLowerAscii() notin ["http", "https"] or
      parsed.hostname.len == 0:
    raise newException(ValueError,
      "webhook avatar URL must be an absolute HTTP or HTTPS URL")

proc validateAppliedTags(tags: openArray[ForumTagId]) =
  if tags.len > MaxWebhookAppliedTags:
    raise newException(ValueError,
      "webhook thread cannot apply more than " & $MaxWebhookAppliedTags &
        " tags")
  var seen = initHashSet[ForumTagId]()
  for tagId in tags:
    if tagId.toUint64() == 0:
      raise newException(ValueError,
        "webhook applied tag ID must be greater than zero")
    if tagId in seen:
      raise newException(ValueError,
        "webhook applied tag IDs must be unique")
    seen.incl(tagId)

proc appliedTagsJson(tags: openArray[ForumTagId]): JsonNode =
  validateAppliedTags(tags)
  result = newJArray()
  for tagId in tags:
    result.add(newJString($tagId))

# ---------------------------------------------------------------------------
# Execute bodies
# ---------------------------------------------------------------------------

func legacyExecute*(draft: MessageDraft[Legacy];
                    tts = false;
                    username = none(string);
                    avatarUrl = none(string);
                    threadName = none(string);
                    flags = none(int64);
                    poll = none(PollCreate);
                    appliedTags: seq[ForumTagId] = @[];
                    allowedMentions = initAllowedMentions()):
                    WebhookExecute[Legacy] =
  ## Builds a legacy webhook-execute body; `poll` takes a validated `PollCreate`.
  flags.validateWebhookFlags(webhookExecuteFlagMask, "webhook execute flags",
    rejectV2 = true)
  if username.isSome:
    username.get.validateWebhookUsername()
  if avatarUrl.isSome:
    avatarUrl.get.validateAvatarUrl()
  if threadName.isSome:
    threadName.get.validateWebhookThreadName()
  validateAppliedTags(appliedTags)
  discard allowedMentions.toJson()
  if appliedTags.len != 0 and threadName.isNone:
    raise newException(ValueError,
      "applied webhook tags require a new thread name")
  WebhookExecute[Legacy](
    draftValue: draft,
    ttsValue: tts,
    usernameValue: username,
    avatarUrlValue: avatarUrl,
    threadNameValue: threadName,
    appliedTagsValue: appliedTags,
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
    pollValue: poll,
  )

func v2Execute*(draft: MessageDraft[V2];
                username = none(string);
                avatarUrl = none(string);
                threadName = none(string);
                flags = none(int64);
                appliedTags: seq[ForumTagId] = @[];
                allowedMentions = initAllowedMentions()): WebhookExecute[V2] =
  ## Builds a Components V2 webhook-execute body with no legacy content fields.
  flags.validateWebhookFlags(webhookExecuteFlagMask, "webhook execute flags")
  if username.isSome:
    username.get.validateWebhookUsername()
  if avatarUrl.isSome:
    avatarUrl.get.validateAvatarUrl()
  if threadName.isSome:
    threadName.get.validateWebhookThreadName()
  validateAppliedTags(appliedTags)
  discard allowedMentions.toJson()
  if appliedTags.len != 0 and threadName.isNone:
    raise newException(ValueError,
      "applied webhook tags require a new thread name")
  WebhookExecute[V2](
    draftValue: draft,
    usernameValue: username,
    avatarUrlValue: avatarUrl,
    threadNameValue: threadName,
    appliedTagsValue: appliedTags,
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
  )

proc applyCommonExecute(body: JsonNode; execute: WebhookExecute) =
  if execute.ttsValue:
    body["tts"] = newJBool(true)
  if execute.usernameValue.isSome:
    execute.usernameValue.get.validateWebhookUsername()
    body["username"] = newJString(execute.usernameValue.get)
  if execute.avatarUrlValue.isSome:
    execute.avatarUrlValue.get.validateAvatarUrl()
    body["avatar_url"] = newJString(execute.avatarUrlValue.get)
  if execute.threadNameValue.isSome:
    execute.threadNameValue.get.validateWebhookThreadName()
    body["thread_name"] = newJString(execute.threadNameValue.get)
  if execute.appliedTagsValue.len != 0:
    if execute.threadNameValue.isNone:
      raise newException(ValueError,
        "applied webhook tags require a new thread name")
    body["applied_tags"] = appliedTagsJson(execute.appliedTagsValue)
  body["allowed_mentions"] = execute.allowedMentionsValue.toJson()

proc validateExecutePayload(body: JsonNode) =
  if body.hasKey("sticker_ids"):
    raise newException(ValueError,
      "webhook execution does not support message stickers")
  if body.hasKey("content"):
    if body["content"].kind != JString:
      raise newException(ValueError, "webhook content must be a string")
    body["content"].getStr.validateWebhookText("webhook content",
      MaxMessageContentLength, allowEmpty = true)
  for name in ["embeds", "components"]:
    if body.hasKey(name) and body[name].kind != JArray:
      raise newException(ValueError, "webhook " & name & " must be an array")
  if body.hasKey("embeds") and body["embeds"].len > 10:
    raise newException(ValueError, "webhook cannot contain more than 10 embeds")

  let hasContent = body.hasKey("content") and
    body["content"].kind == JString and body["content"].getStr.len != 0
  let hasEmbeds = body.hasKey("embeds") and body["embeds"].len != 0
  let hasComponents = body.hasKey("components") and
    body["components"].len != 0
  let hasPoll = body.hasKey("poll") and body["poll"].kind == JObject
  if not (hasContent or hasEmbeds or hasComponents or hasPoll):
    raise newException(ValueError,
      "webhook execution requires message content")

proc toWire(execute: WebhookExecute[Legacy]): JsonNode =
  execute.flagsValue.validateWebhookFlags(webhookExecuteFlagMask,
    "webhook execute flags", rejectV2 = true)
  result = execute.draftValue.toJson()
  result.applyCommonExecute(execute)
  if execute.pollValue.isSome:
    result["poll"] = execute.pollValue.get.toJson()
  if execute.flagsValue.isSome:
    result["flags"] = newJInt(execute.flagsValue.get)
  result.validateExecutePayload()

proc toWire(execute: WebhookExecute[V2]): JsonNode =
  execute.flagsValue.validateWebhookFlags(webhookExecuteFlagMask,
    "webhook execute flags")
  result = execute.draftValue.toJson()
  result.applyCommonExecute(execute)
  if execute.flagsValue.isSome:
    result["flags"] = newJInt(
      execute.flagsValue.get or webhookComponentsV2Flag)
  else:
    result["flags"] = newJInt(webhookComponentsV2Flag)
  result.validateExecutePayload()

# ---------------------------------------------------------------------------
# Webhook message edit bodies
# ---------------------------------------------------------------------------

proc legacyWebhookEdit*(content = editOmit(string);
                        components = editOmit(seq[ComponentNode]);
                        poll = editOmit(PollCreate);
                        flags = none(int64);
                        allowedMentions = initAllowedMentions()):
                        WebhookMessageEdit[Legacy] =
  ## Builds a legacy webhook-message edit honoring omit versus clear per field.
  flags.validateWebhookFlags(webhookEditFlagMask, "webhook message edit flags",
    rejectV2 = true)
  if content.isSet:
    editValue(content).validateWebhookText("webhook message content",
      MaxMessageContentLength, allowEmpty = true)
  if components.isSet:
    discard legacyMessage(components = editValue(components)).toJson()
  discard allowedMentions.toJson()
  WebhookMessageEdit[Legacy](
    contentValue: content,
    componentsValue: components,
    pollValue: poll,
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
  )

proc v2WebhookEdit*(components: seq[ComponentNode]; flags = none(int64);
                    allowedMentions = initAllowedMentions()):
                    WebhookMessageEdit[V2] =
  ## Builds a V2 edit or one-way upgrade with explicit legacy-field resets.
  flags.validateWebhookFlags(webhookEditFlagMask, "webhook message edit flags")
  discard v2Draft(components).toJson()
  discard allowedMentions.toJson()
  WebhookMessageEdit[V2](
    componentsValue: editSet(components),
    allowedMentionsValue: allowedMentions,
    flagsValue: flags,
  )

proc legacyComponentsJson(nodes: seq[ComponentNode]): JsonNode =
  let validated = legacyMessage(components = nodes).toJson()
  validated["components"]

proc toWire(edit: WebhookMessageEdit[Legacy]): JsonNode =
  edit.flagsValue.validateWebhookFlags(webhookEditFlagMask,
    "webhook message edit flags", rejectV2 = true)
  result = newJObject()
  if edit.contentValue.isSet:
    let content = editValue(edit.contentValue)
    content.validateWebhookText("webhook message content",
      MaxMessageContentLength, allowEmpty = true)
    result["content"] = newJString(content)
  elif edit.contentValue.isClear:
    result["content"] = newJNull()
  if edit.componentsValue.isSet:
    result["components"] = legacyComponentsJson(
      editValue(edit.componentsValue))
  elif edit.componentsValue.isClear:
    result["components"] = newJArray()
  if edit.pollValue.isSet:
    result["poll"] = editValue(edit.pollValue).toJson()
  elif edit.pollValue.isClear:
    result["poll"] = newJNull()
  if edit.flagsValue.isSome:
    result["flags"] = newJInt(edit.flagsValue.get)
  result["allowed_mentions"] = edit.allowedMentionsValue.toJson()

proc toWire(edit: WebhookMessageEdit[V2]): JsonNode =
  result = newJObject()
  if not edit.componentsValue.isSet:
    raise newException(ValueError, "Components V2 edit requires components")
  let validated = v2Draft(editValue(edit.componentsValue)).toJson()
  result["components"] = validated["components"]
  result["content"] = newJNull()
  result["embeds"] = newJArray()
  result["poll"] = newJNull()
  result["allowed_mentions"] = edit.allowedMentionsValue.toJson()
  edit.flagsValue.validateWebhookFlags(webhookEditFlagMask,
    "webhook message edit flags")
  if edit.flagsValue.isSome:
    result["flags"] = newJInt(
      edit.flagsValue.get or webhookComponentsV2Flag)
  else:
    result["flags"] = newJInt(webhookComponentsV2Flag)

# ---------------------------------------------------------------------------
# Webhook management
# ---------------------------------------------------------------------------

proc listChannelWebhooks*(client: ChronosRestClient;
                          channelId: ChannelId;
                          options = initApiCallOptions()):
                          Future[seq[Webhook]] {.async.} =
  ## Lists every webhook attached to one channel.
  let raw = raw_request.initRawRequest(channel_routes.listChannelWebhooks, [
    initRawParameter("channel_id", $channelId),
  ])
  return await client.executeJsonArray(raw, decodeWebhook,
    auth = darBot, meta = options.requestMeta(idSafe), allowNull = true)

proc listGuildWebhooks*(client: ChronosRestClient;
                        guildId: GuildId;
                        options = initApiCallOptions()):
                        Future[seq[Webhook]] {.async.} =
  ## Lists every webhook in one guild.
  let raw = raw_request.initRawRequest(guild_routes.getGuildWebhooks, [
    initRawParameter("guild_id", $guildId),
  ])
  return await client.executeJsonArray(raw, decodeWebhook,
    auth = darBot, meta = options.requestMeta(idSafe), allowNull = true)

proc createWebhook*(client: ChronosRestClient;
                    channelId: ChannelId;
                    name: string;
                    avatar = none(string);
                    options = initApiCallOptions()): Future[Webhook] {.async.} =
  ## Creates an incoming webhook; creation is never retried automatically.
  validateWebhookName(name)
  var body = newJObject()
  body["name"] = newJString(name)
  if avatar.isSome:
    body["avatar"] = newJString(avatar.get)
  let raw = raw_request.initRawRequest(channel_routes.createWebhook, [
    initRawParameter("channel_id", $channelId),
  ], body)
  return await client.executeJson(raw, decodeWebhook,
    auth = darBot, meta = options.requestMeta(idNever))

proc fetchWebhook*(client: ChronosRestClient;
                   webhookId: WebhookId;
                   options = initApiCallOptions()): Future[Webhook] {.async.} =
  ## Fetches a webhook by ID using the bot token.
  let raw = raw_request.initRawRequest(webhook_routes.getWebhook, [
    initRawParameter("webhook_id", $webhookId),
  ])
  return await client.executeJson(raw, decodeWebhook,
    auth = darBot, meta = options.requestMeta(idSafe))

proc fetchWebhook*(client: ChronosRestClient;
                   endpoint: WebhookEndpoint;
                   options = initApiCallOptions()): Future[Webhook] {.async.} =
  ## Fetches a webhook by its typed endpoint using the embedded token.
  let raw = raw_request.initRawRequest(webhook_routes.getWebhookByToken, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
  ])
  return await client.executeJson(raw, decodeWebhook,
    auth = darNone, meta = options.requestMeta(idSafe))

proc editWebhook*(client: ChronosRestClient;
                  webhookId: WebhookId;
                  name = none(string);
                  avatar = editOmit(string);
                  channelId = editOmit(ChannelId);
                  options = initApiCallOptions()): Future[Webhook] {.async.} =
  ## Edits a webhook by ID; replacement is idempotent, so retries are allowed.
  var body = newJObject()
  if name.isSome:
    validateWebhookName(name.get)
    body["name"] = newJString(name.get)
  if avatar.isSet:
    body["avatar"] = newJString(editValue(avatar))
  elif avatar.isClear:
    body["avatar"] = newJNull()
  if channelId.isSet:
    body["channel_id"] = newJString($editValue(channelId))
  elif channelId.isClear:
    body["channel_id"] = newJNull()
  let raw = raw_request.initRawRequest(webhook_routes.updateWebhook, [
    initRawParameter("webhook_id", $webhookId),
  ], body)
  return await client.executeJson(raw, decodeWebhook,
    auth = darBot, meta = options.requestMeta(idSafe))

proc editWebhook*(client: ChronosRestClient;
                  endpoint: WebhookEndpoint;
                  name = none(string);
                  avatar = editOmit(string);
                  options = initApiCallOptions()): Future[Webhook] {.async.} =
  ## Edits a webhook by endpoint; the token route cannot change the channel.
  var body = newJObject()
  if name.isSome:
    validateWebhookName(name.get)
    body["name"] = newJString(name.get)
  if avatar.isSet:
    body["avatar"] = newJString(editValue(avatar))
  elif avatar.isClear:
    body["avatar"] = newJNull()
  let raw = raw_request.initRawRequest(webhook_routes.updateWebhookByToken, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
  ], body)
  return await client.executeJson(raw, decodeWebhook,
    auth = darNone, meta = options.requestMeta(idSafe))

proc deleteWebhook*(client: ChronosRestClient;
                    webhookId: WebhookId;
                    options = initApiCallOptions()): Future[void] {.async.} =
  ## Deletes a webhook by ID; deletion is idempotent.
  let raw = raw_request.initRawRequest(webhook_routes.deleteWebhook, [
    initRawParameter("webhook_id", $webhookId),
  ])
  await client.executeNoContent(raw, auth = darBot,
    meta = options.requestMeta(idSafe))

proc deleteWebhook*(client: ChronosRestClient;
                    endpoint: WebhookEndpoint;
                    options = initApiCallOptions()): Future[void] {.async.} =
  ## Deletes a webhook by its typed endpoint; deletion is idempotent.
  let raw = raw_request.initRawRequest(webhook_routes.deleteWebhookByToken, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
  ])
  await client.executeNoContent(raw, auth = darNone,
    meta = options.requestMeta(idSafe))

# ---------------------------------------------------------------------------
# Webhook execution
# ---------------------------------------------------------------------------

proc executeWebhookAndWait*[Mode](client: ChronosRestClient;
                                  endpoint: WebhookEndpoint;
                                  execute: WebhookExecute[Mode];
                                  threadId = none(ChannelId);
                                  withComponents = none(bool);
                                  options = initApiCallOptions()):
                                  Future[Message] {.async.} =
  ## Executes a webhook with `wait=true` and decodes the created message.
  execute.validateThreadTarget(threadId)
  var raw = raw_request.initRawRequest(webhook_routes.executeWebhook, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
  ], execute.toWire())
  raw.addQuery("wait", "true")
  raw.addOptional("thread_id", threadId)
  applyWithComponents[Mode](raw, withComponents)
  return await client.executeJson(raw, decodeMessage,
    auth = darNone, meta = options.requestMeta(idNever))

proc triggerWebhook*[Mode](client: ChronosRestClient;
                           endpoint: WebhookEndpoint;
                           execute: WebhookExecute[Mode];
                           threadId = none(ChannelId);
                           withComponents = none(bool);
                           options = initApiCallOptions()):
                           Future[void] {.async.} =
  ## Executes a webhook without waiting; the empty success body is expected.
  execute.validateThreadTarget(threadId)
  var raw = raw_request.initRawRequest(webhook_routes.executeWebhook, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
  ], execute.toWire())
  raw.addOptional("thread_id", threadId)
  applyWithComponents[Mode](raw, withComponents)
  await client.executeNoContent(raw, auth = darNone,
    meta = options.requestMeta(idNever))

# ---------------------------------------------------------------------------
# Webhook messages
# ---------------------------------------------------------------------------

proc fetchWebhookMessage*(client: ChronosRestClient;
                          endpoint: WebhookEndpoint;
                          messageId: MessageId;
                          threadId = none(ChannelId);
                          options = initApiCallOptions()):
                          Future[Message] {.async.} =
  ## Fetches one message previously sent through the webhook.
  threadId.validateThreadId()
  var raw = raw_request.initRawRequest(webhook_routes.getWebhookMessage, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
    initRawParameter("message_id", $messageId),
  ])
  raw.addOptional("thread_id", threadId)
  return await client.executeJson(raw, decodeMessage,
    auth = darNone, meta = options.requestMeta(idSafe))

proc editWebhookMessageImpl[Mode](client: ChronosRestClient;
                                  endpoint: WebhookEndpoint;
                                  messageId: MessageId;
                                  edit: WebhookMessageEdit[Mode];
                                  threadId: Option[ChannelId];
                                  withComponents: Option[bool];
                                  options: ApiCallOptions):
                                  Future[Message] {.async.} =
  threadId.validateThreadId()
  var raw = raw_request.initRawRequest(webhook_routes.updateWebhookMessage, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
    initRawParameter("message_id", $messageId),
  ], edit.toWire())
  raw.addOptional("thread_id", threadId)
  applyWithComponents[Mode](raw, withComponents)
  return await client.executeJson(raw, decodeMessage,
    auth = darNone, meta = options.requestMeta(idSafe))

proc editWebhookMessage*[Mode](client: ChronosRestClient;
                               handle: WebhookMessageHandle[Mode];
                               edit: WebhookMessageEdit[Mode];
                               threadId = none(ChannelId);
                               withComponents = none(bool);
                               options = initApiCallOptions()):
                               Future[Message] {.async.} =
  ## Edits a webhook message without permitting a mode-mismatched body.
  return await client.editWebhookMessageImpl(
    handle.endpointValue, handle.messageIdValue, edit, threadId,
    withComponents, options)

proc upgradeWebhookMessageToV2*(client: ChronosRestClient;
                                handle: WebhookMessageHandle[Legacy];
                                edit: WebhookMessageEdit[V2];
                                threadId = none(ChannelId);
                                withComponents = none(bool);
                                options = initApiCallOptions()):
                                Future[Message] {.async.} =
  ## Permanently upgrades a known legacy webhook message to Components V2.
  return await client.editWebhookMessageImpl(
    handle.endpointValue, handle.messageIdValue, edit, threadId,
    withComponents, options)

proc deleteWebhookMessage*(client: ChronosRestClient;
                           endpoint: WebhookEndpoint;
                           messageId: MessageId;
                           threadId = none(ChannelId);
                           options = initApiCallOptions()):
                           Future[void] {.async.} =
  ## Deletes one webhook message; deletion is idempotent.
  threadId.validateThreadId()
  var raw = raw_request.initRawRequest(webhook_routes.deleteWebhookMessage, [
    endpoint.idParameter(),
    endpoint.tokenParameter(),
    initRawParameter("message_id", $messageId),
  ])
  raw.addOptional("thread_id", threadId)
  await client.executeNoContent(raw, auth = darNone,
    meta = options.requestMeta(idSafe))
