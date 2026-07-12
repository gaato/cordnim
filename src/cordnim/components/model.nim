## Separate Legacy and Components V2 message models.
##
## `MessageDraft[V2]` intentionally has no `content`, `embeds`, `poll`, or
## `stickers` field. Moving a handle from Legacy to V2 is explicit and no
## reverse operation is provided.

import std/[hashes, options]

import cordnim/core/ids

type
  ComponentId* = distinct uint32 ## Message-local integer identity assigned to
                                 ## a component by the application or Discord.

  Legacy* = object ## Phantom type for a legacy Discord message.
  V2* = object ## Phantom type for a Components V2 Discord message.

  MessageComponentKind* = enum ## High-level Components V2 node kinds.
    mckActionRow, ## Row containing buttons or exactly one select.
    mckButton, ## Interactive or URL button.
    mckStringSelect, ## String-valued select menu.
    mckUserSelect, ## User select menu.
    mckRoleSelect, ## Role select menu.
    mckMentionableSelect, ## User-or-role select menu.
    mckChannelSelect, ## Channel select menu.
    mckSection, ## Text displays plus exactly one accessory.
    mckTextDisplay, ## Markdown text block.
    mckThumbnail, ## Section thumbnail accessory.
    mckMediaGallery, ## Gallery containing media items.
    mckMediaItem, ## One media item within a gallery.
    mckFile, ## Uploaded file reference.
    mckSeparator, ## Visual separator and optional spacing.
    mckContainer ## Styled group of Components V2 children.

  ButtonStyle* = enum ## Discord button presentation and behavior.
    bsPrimary = 1, ## Blurple interactive button.
    bsSecondary = 2, ## Grey interactive button.
    bsSuccess = 3, ## Green interactive button.
    bsDanger = 4, ## Red interactive button.
    bsLink = 5, ## URL button without `custom_id`.
    bsPremium = 6 ## SKU purchase button.

  SeparatorSpacing* = enum ## Vertical space around a V2 separator.
    ssSmall = 1, ## Compact separator spacing.
    ssLarge = 2 ## Expanded separator spacing.

  MessageChannelType* = enum ## Channel kinds accepted by a channel select.
    mctGuildText = 0, ## Guild text channel.
    mctDm = 1, ## Direct-message channel.
    mctGuildVoice = 2, ## Guild voice channel.
    mctGroupDm = 3, ## Group direct-message channel.
    mctGuildCategory = 4, ## Guild category.
    mctGuildAnnouncement = 5, ## Guild announcement channel.
    mctAnnouncementThread = 10, ## Announcement thread.
    mctPublicThread = 11, ## Public thread.
    mctPrivateThread = 12, ## Private thread.
    mctGuildStageVoice = 13, ## Guild stage channel.
    mctGuildDirectory = 14, ## Guild directory channel.
    mctGuildForum = 15, ## Guild forum channel.
    mctGuildMedia = 16 ## Guild media channel.

  ComponentEmoji* = object ## Emoji displayed on a button or string option.
    id*: Option[EmojiId] ## Custom emoji ID, absent for Unicode emoji.
    name*: string ## Custom emoji name or Unicode glyph.
    animated*: bool ## Whether a custom emoji is animated.

  SelectDefaultKind* = enum ## Entity kind encoded in a select default value.
    sdkUser, ## User-select default.
    sdkRole, ## Role-select default.
    sdkChannel ## Channel-select default.

  SelectDefaultValue* = object ## Typed initial value for an auto-populated
                               ## select.
    case kind*: SelectDefaultKind ## Discord entity category.
    of sdkUser:
      userId*: UserId ## Initially selected user.
    of sdkRole:
      roleId*: RoleId ## Initially selected role.
    of sdkChannel:
      channelId*: ChannelId ## Initially selected channel.

  SelectOption* = object ## One option in a string select menu.
    label*: string ## User-facing option label.
    value*: string ## Stable value delivered on selection.
    description*: string ## Optional supporting description.
    default*: bool ## Whether this option starts selected.
    emoji*: Option[ComponentEmoji] ## Optional emoji displayed with the option.

  ComponentNode* = ref object ## Mutable construction node validated before
                              ## send.
    id*: Option[ComponentId] ## Optional message-local component identity.
    kind*: MessageComponentKind ## Node kind.
    text*: string ## Text, label, URL, or upload reference by kind.
    customId*: string ## Application-owned interaction identifier.
    url*: string ## URL used only by link buttons and media.
    disabled*: bool ## Whether an interactive component is disabled.
    buttonStyle*: ButtonStyle ## Button style; ignored by non-buttons.
    emoji*: Option[ComponentEmoji] ## Button emoji, when present.
    skuId*: Option[SkuId] ## SKU used only by a premium button.
    placeholder*: string ## Select placeholder text.
    minValues*: int ## Minimum select values.
    maxValues*: int ## Maximum select values.
    required*: Option[bool] ## Explicit select requiredness when supported.
    options*: seq[SelectOption] ## String-select choices.
    defaultValues*: seq[SelectDefaultValue] ## Auto-populated select defaults.
    channelTypes*: seq[MessageChannelType] ## Channel-select type restriction.
    description*: string ## Alternative text for media components.
    spoiler*: bool ## Media, file, or container spoiler state.
    accentColor*: Option[int] ## Container RGB accent in `0x000000..0xffffff`.
    divider*: Option[bool] ## Separator divider visibility override.
    spacing*: Option[SeparatorSpacing] ## Separator spacing override.
    children*: seq[ComponentNode] ## Ordered child nodes.

  LegacyPayload* = object ## Fields legal on a legacy Discord message.
    content*: Option[string] ## Message text.
    embedsJson*: seq[string] ## Raw serialized embeds retained by the alpha API.
    pollJson*: Option[string] ## Raw serialized poll retained by the alpha API.
    stickers*: seq[string] ## Sticker snowflakes as decimal strings.

  V2Payload* = object ## Root component tree for a Components V2 message.
    children*: seq[ComponentNode] ## Valid root-level nodes.

  MessageDraft*[Mode: Legacy | V2] = object ## Message under construction for
                                            ## one wire mode.
    when Mode is Legacy:
      legacy*: LegacyPayload ## Legacy-only payload.
    else:
      v2*: V2Payload ## Components V2-only payload.

  MessageHandle*[Mode: Legacy | V2] = object ## Existing message whose mode is
                                             ## known statically.
    channelId*: ChannelId ## Channel containing the message.
    messageId*: MessageId ## Existing message snowflake.

func toComponentId*(value: uint32): ComponentId {.inline.} =
  ## Explicitly wraps a 32-bit component ID at a protocol boundary.
  ComponentId(value)

func toUint32*(id: ComponentId): uint32 {.inline.} =
  ## Returns the integer wire representation of a component ID.
  uint32(id)

func `==`*(left, right: ComponentId): bool {.inline.} =
  ## Compares two component IDs by their wire value.
  uint32(left) == uint32(right)

func hash*(id: ComponentId): Hash {.inline.} =
  ## Hashes a component ID for use in sets and tables.
  hash(uint32(id))

func `$`*(id: ComponentId): string =
  ## Formats a component ID as an unsigned decimal integer.
  $uint32(id)

func legacyMessage*(content = ""): MessageDraft[Legacy] =
  ## Creates a legacy draft. Empty content remains omitted.
  if content.len == 0:
    MessageDraft[Legacy](legacy: LegacyPayload(content: none(string)))
  else:
    MessageDraft[Legacy](legacy: LegacyPayload(content: some(content)))

func component*(kind: MessageComponentKind, text = "", customId = "",
                url = "", disabled = false,
                buttonStyle = bsPrimary, placeholder = "",
                minValues = 1, maxValues = 1,
                options: seq[SelectOption] = @[],
                emoji = none(ComponentEmoji), skuId = none(SkuId),
                required = none(bool),
                defaultValues: seq[SelectDefaultValue] = @[],
                channelTypes: seq[MessageChannelType] = @[],
                description = "", spoiler = false,
                accentColor = none(int), divider = none(bool),
                spacing = none(SeparatorSpacing),
                children: seq[ComponentNode] = @[],
                id = none(ComponentId)): ComponentNode =
  ## Creates a raw high-level node for dynamic component construction.
  ComponentNode(
    id: id,
    kind: kind,
    text: text,
    customId: customId,
    url: url,
    disabled: disabled,
    buttonStyle: buttonStyle,
    emoji: emoji,
    skuId: skuId,
    placeholder: placeholder,
    minValues: minValues,
    maxValues: maxValues,
    required: required,
    options: options,
    defaultValues: defaultValues,
    channelTypes: channelTypes,
    description: description,
    spoiler: spoiler,
    accentColor: accentColor,
    divider: divider,
    spacing: spacing,
    children: children
  )

func textDisplay*(text: string; id = none(ComponentId)): ComponentNode =
  ## Creates a markdown text display.
  component(mckTextDisplay, text = text, id = id)

func button*(label: string, customId = "", url = "",
             disabled = false, style = bsPrimary,
             emoji = none(ComponentEmoji),
             id = none(ComponentId)): ComponentNode =
  ## Creates an interactive button or, when `url` is set, a link button.
  component(mckButton, text = label, customId = customId, url = url,
    disabled = disabled,
    buttonStyle = (if url.len != 0: bsLink else: style), emoji = emoji,
    id = id)

func premiumButton*(skuId: SkuId; disabled = false,
                    id = none(ComponentId)): ComponentNode =
  ## Creates a premium button tied to an application SKU.
  ##
  ## Discord forbids labels and emoji on premium buttons; callers that need a
  ## caption should place a Text Display next to the button.
  component(mckButton, disabled = disabled,
    buttonStyle = bsPremium, skuId = some(skuId), id = id)

func componentEmoji*(name: string; id = none(EmojiId);
                     animated = false): ComponentEmoji =
  ## Creates a Unicode or custom component emoji.
  ComponentEmoji(id: id, name: name, animated: animated)

func selectOption*(label, value: string, description = "",
                   default = false,
                   emoji = none(ComponentEmoji)): SelectOption =
  ## Creates one string-select option.
  SelectOption(
    label: label,
    value: value,
    description: description,
    default: default,
    emoji: emoji
  )

func defaultUser*(id: UserId): SelectDefaultValue =
  ## Creates a typed user-select default.
  SelectDefaultValue(kind: sdkUser, userId: id)

func defaultRole*(id: RoleId): SelectDefaultValue =
  ## Creates a typed role-select default.
  SelectDefaultValue(kind: sdkRole, roleId: id)

func defaultChannel*(id: ChannelId): SelectDefaultValue =
  ## Creates a typed channel-select default.
  SelectDefaultValue(kind: sdkChannel, channelId: id)

func stringSelect*(customId: string, options: openArray[SelectOption],
                   placeholder = "", minValues = 1, maxValues = 1,
                   disabled = false,
                   id = none(ComponentId)): ComponentNode =
  ## Creates a string select with explicit choices.
  component(
    mckStringSelect,
    customId = customId,
    disabled = disabled,
    placeholder = placeholder,
    minValues = minValues,
    maxValues = maxValues,
    options = @options,
    id = id
  )

func userSelect*(customId: string, placeholder = "", minValues = 1,
                 maxValues = 1, disabled = false,
                 defaults: seq[SelectDefaultValue] = @[],
                 id = none(ComponentId)): ComponentNode =
  ## Creates a user select; `validate` requires every default to come from
  ## `defaultUser` and checks selection bounds.
  component(mckUserSelect, customId = customId, disabled = disabled,
    placeholder = placeholder, minValues = minValues, maxValues = maxValues,
    defaultValues = defaults, id = id)

func roleSelect*(customId: string, placeholder = "", minValues = 1,
                 maxValues = 1, disabled = false,
                 defaults: seq[SelectDefaultValue] = @[],
                 id = none(ComponentId)): ComponentNode =
  ## Creates a role select; `validate` requires every default to come from
  ## `defaultRole` and checks selection bounds.
  component(mckRoleSelect, customId = customId, disabled = disabled,
    placeholder = placeholder, minValues = minValues, maxValues = maxValues,
    defaultValues = defaults, id = id)

func mentionableSelect*(customId: string, placeholder = "", minValues = 1,
                        maxValues = 1, disabled = false,
                        defaults: seq[SelectDefaultValue] = @[],
                        id = none(ComponentId)):
                        ComponentNode =
  ## Creates a mentionable select; defaults may come from `defaultUser` or
  ## `defaultRole`, with bounds checked by `validate`.
  component(mckMentionableSelect, customId = customId, disabled = disabled,
    placeholder = placeholder, minValues = minValues, maxValues = maxValues,
    defaultValues = defaults, id = id)

func channelSelect*(customId: string, placeholder = "", minValues = 1,
                    maxValues = 1, disabled = false,
                    defaults: seq[SelectDefaultValue] = @[],
                    channelTypes: seq[MessageChannelType] = @[],
                    id = none(ComponentId)):
                    ComponentNode =
  ## Creates a channel select; defaults must come from `defaultChannel`, and an
  ## empty `channelTypes` leaves Discord unfiltered.
  component(mckChannelSelect, customId = customId, disabled = disabled,
    placeholder = placeholder, minValues = minValues, maxValues = maxValues,
    defaultValues = defaults, channelTypes = channelTypes, id = id)

func actionRow*(children: varargs[ComponentNode]): ComponentNode =
  ## Groups buttons or one select in an action row.
  component(mckActionRow, children = @children)

func actionRow*(id: Option[ComponentId];
                children: varargs[ComponentNode]): ComponentNode =
  ## Groups buttons or one select and explicitly controls the row ID.
  component(mckActionRow, children = @children, id = id)

func section*(children: varargs[ComponentNode]): ComponentNode =
  ## Creates a section from text displays and exactly one accessory.
  component(mckSection, children = @children)

func section*(id: Option[ComponentId];
              children: varargs[ComponentNode]): ComponentNode =
  ## Creates a section and explicitly controls its component ID.
  component(mckSection, children = @children, id = id)

func thumbnail*(url: string, description = "", spoiler = false,
                id = none(ComponentId)): ComponentNode =
  ## Creates a thumbnail that `validate` accepts only as the single accessory
  ## of a section.
  component(mckThumbnail, url = url, description = description,
    spoiler = spoiler, id = id)

func separator*(spacing = none(SeparatorSpacing),
                divider = none(bool),
                id = none(ComponentId)): ComponentNode =
  ## Creates a separator, omitting `spacing` or `divider` when their options
  ## are unset.
  component(mckSeparator, spacing = spacing, divider = divider, id = id)

func mediaItem*(url: string, description = "", spoiler = false): ComponentNode =
  ## Creates an item for a media gallery.
  component(mckMediaItem, url = url, description = description,
    spoiler = spoiler)

func mediaGallery*(children: varargs[ComponentNode]): ComponentNode =
  ## Creates a gallery that `validate` restricts to one through ten `mediaItem`
  ## children.
  component(mckMediaGallery, children = @children)

func mediaGallery*(id: Option[ComponentId];
                   children: varargs[ComponentNode]): ComponentNode =
  ## Creates a gallery and explicitly controls its component ID.
  component(mckMediaGallery, children = @children, id = id)

func fileComponent*(uploadReference: string, spoiler = false,
                    id = none(ComponentId)): ComponentNode =
  ## Creates a file component referring to an uploaded attachment.
  component(mckFile, text = uploadReference, spoiler = spoiler, id = id)

func container*(children: varargs[ComponentNode]): ComponentNode =
  ## Creates a styled Components V2 container.
  component(mckContainer, children = @children)

func container*(id: Option[ComponentId];
                children: varargs[ComponentNode]): ComponentNode =
  ## Creates a container and explicitly controls its component ID.
  component(mckContainer, children = @children, id = id)

func v2Draft*(children: varargs[ComponentNode]): MessageDraft[V2] =
  ## Creates a dynamic V2 draft. Call `validate` before serialization.
  MessageDraft[V2](v2: V2Payload(children: @children))

func messageHandle*[Mode](channelId: ChannelId,
                          messageId: MessageId): MessageHandle[Mode] =
  ## Creates a typed handle from IDs obtained at a trusted protocol boundary.
  MessageHandle[Mode](channelId: channelId, messageId: messageId)

func upgradedHandle*(handle: MessageHandle[Legacy]): MessageHandle[V2] =
  ## Returns the handle type produced after a successful V2 upgrade request.
  ##
  ## This function does not perform I/O; the REST operation must succeed before
  ## the caller materializes the returned handle.
  MessageHandle[V2](channelId: handle.channelId, messageId: handle.messageId)
