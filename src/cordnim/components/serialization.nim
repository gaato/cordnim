## Wire serialization for validated Legacy and Components V2 messages.

import std/[json, options, sets, strutils]

import cordnim/core/ids
import ./[model, validation]

const ComponentsV2MessageFlag* = 1 shl 15 ## `IS_COMPONENTS_V2`, set
                                          ## permanently when a V2 message is
                                          ## first sent.

func wireType(kind: MessageComponentKind): int =
  case kind
  of mckActionRow: 1
  of mckButton: 2
  of mckStringSelect: 3
  of mckUserSelect: 5
  of mckRoleSelect: 6
  of mckMentionableSelect: 7
  of mckChannelSelect: 8
  of mckSection: 9
  of mckTextDisplay: 10
  of mckThumbnail: 11
  of mckMediaGallery: 12
  of mckFile: 13
  of mckSeparator: 14
  of mckContainer: 17
  of mckMediaItem:
    # Gallery items are media objects, not standalone component objects.
    0

func mediaJson(url: string): JsonNode =
  %*{"url": url}

func emojiJson(emoji: ComponentEmoji): JsonNode =
  result = %*{"name": emoji.name}
  if emoji.id.isSome:
    result["id"] = %($emoji.id.get())
  if emoji.animated:
    result["animated"] = %true

func defaultValueJson(value: SelectDefaultValue): JsonNode =
  case value.kind
  of sdkUser:
    %*{"id": $value.userId, "type": "user"}
  of sdkRole:
    %*{"id": $value.roleId, "type": "role"}
  of sdkChannel:
    %*{"id": $value.channelId, "type": "channel"}

func selectOptionJson(option: SelectOption): JsonNode =
  result = %*{"label": option.label, "value": option.value}
  if option.description.len != 0:
    result["description"] = %option.description
  if option.default:
    result["default"] = %true
  if option.emoji.isSome:
    result["emoji"] = option.emoji.get().emojiJson()

proc componentJson(node: ComponentNode,
                   visiting: var HashSet[pointer]): JsonNode =
  if node.isNil:
    raise newException(ValueError, "cannot serialize a nil component")
  let identity = cast[pointer](node)
  if identity in visiting:
    raise newException(ValueError, "component tree contains a cycle")
  visiting.incl identity
  defer:
    visiting.excl identity
  result = newJObject()
  if node.kind != mckMediaItem:
    result["type"] = %node.kind.wireType()
  case node.kind
  of mckActionRow, mckContainer:
    result["components"] = newJArray()
    for child in node.children:
      result["components"].add(child.componentJson(visiting))
  of mckButton:
    result["style"] = %ord(node.buttonStyle)
    if node.text.len != 0:
      result["label"] = %node.text
    if node.customId.len != 0:
      result["custom_id"] = %node.customId
    if node.url.len != 0:
      result["url"] = %node.url
    if node.skuId.isSome:
      result["sku_id"] = %($node.skuId.get())
    if node.emoji.isSome:
      result["emoji"] = node.emoji.get().emojiJson()
    if node.disabled:
      result["disabled"] = %true
  of mckStringSelect, mckUserSelect, mckRoleSelect,
      mckMentionableSelect, mckChannelSelect:
    result["custom_id"] = %node.customId
    result["min_values"] = %node.minValues
    result["max_values"] = %node.maxValues
    if node.placeholder.len != 0:
      result["placeholder"] = %node.placeholder
    if node.disabled:
      result["disabled"] = %true
    if node.required.isSome:
      result["required"] = %node.required.get()
    if node.kind == mckStringSelect:
      result["options"] = newJArray()
      for option in node.options:
        result["options"].add(option.selectOptionJson())
    elif node.defaultValues.len != 0:
      result["default_values"] = newJArray()
      for value in node.defaultValues:
        result["default_values"].add(value.defaultValueJson())
    if node.kind == mckChannelSelect and node.channelTypes.len != 0:
      result["channel_types"] = newJArray()
      for channelType in node.channelTypes:
        result["channel_types"].add(%ord(channelType))
  of mckSection:
    result["components"] = newJArray()
    for child in node.children:
      if child.kind == mckTextDisplay:
        result["components"].add(child.componentJson(visiting))
      else:
        result["accessory"] = child.componentJson(visiting)
  of mckTextDisplay:
    result["content"] = %node.text
  of mckThumbnail:
    result["media"] = node.url.mediaJson()
    if node.description.len != 0:
      result["description"] = %node.description
    if node.spoiler:
      result["spoiler"] = %true
  of mckMediaGallery:
    result["items"] = newJArray()
    for child in node.children:
      result["items"].add(child.componentJson(visiting))
  of mckMediaItem:
    result["media"] = node.url.mediaJson()
    if node.description.len != 0:
      result["description"] = %node.description
    if node.spoiler:
      result["spoiler"] = %true
  of mckFile:
    let reference = if node.text.startsWith("attachment://"):
      node.text
    else:
      "attachment://" & node.text
    result["file"] = reference.mediaJson()
    if node.spoiler:
      result["spoiler"] = %true

  of mckSeparator:
    if node.spacing.isSome:
      result["spacing"] = %ord(node.spacing.get())
    if node.divider.isSome:
      result["divider"] = %node.divider.get()
  if node.kind == mckContainer:
    if node.accentColor.isSome:
      result["accent_color"] = %node.accentColor.get()
    if node.spoiler:
      result["spoiler"] = %true

proc componentJson*(node: ComponentNode): JsonNode =
  ## Serializes one component subtree.
  ##
  ## Raises `ValueError` for nil nodes or cyclic public node graphs. Complete
  ## message drafts should be validated before serialization.
  var visiting: HashSet[pointer]
  node.componentJson(visiting)

proc toJson*(draft: MessageDraft[V2]): JsonNode =
  ## Validates and serializes a V2 payload with the irreversible message flag.
  draft.requireValid()
  result = newJObject()
  result["flags"] = %ComponentsV2MessageFlag
  result["components"] = newJArray()
  for child in draft.v2.children:
    result["components"].add(child.componentJson())

proc toJson*(draft: MessageDraft[Legacy]): JsonNode =
  ## Serializes only fields legal on a legacy message.
  result = newJObject()
  if draft.legacy.content.isSome:
    result["content"] = %draft.legacy.content.get()
  if draft.legacy.embedsJson.len != 0:
    result["embeds"] = newJArray()
    for value in draft.legacy.embedsJson:
      result["embeds"].add(parseJson(value))
  if draft.legacy.pollJson.isSome:
    result["poll"] = parseJson(draft.legacy.pollJson.get())
  if draft.legacy.stickers.len != 0:
    result["sticker_ids"] = %draft.legacy.stickers
