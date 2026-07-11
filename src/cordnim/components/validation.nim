## Discord-aware validation for message and modal component trees.

import std/[options, sequtils, sets, unicode]

import ./model

const
  MaxMessageComponents* = 40 ## Discord's total Components V2 node limit.
  MaxCustomIdBytes* = 100 ## Maximum UTF-8 bytes in a component custom ID.

type
  ComponentProblemKind* = enum ## Stable categories returned by validation.
    cpkTooManyComponents, ## Tree exceeds `MaxMessageComponents`.
    cpkInvalidRoot, ## Node is not legal at the message root.
    cpkInvalidChild, ## Parent-child relationship is illegal.
    cpkInvalidActionRow, ## Action row cardinality or child mix is illegal.
    cpkInvalidSection, ## Section text/accessory structure is illegal.
    cpkMissingCustomId, ## Interactive component has no custom ID.
    cpkCustomIdTooLong, ## Custom ID exceeds `MaxCustomIdBytes`.
    cpkButtonTargetConflict, ## Button has both or neither custom ID and URL.
    cpkMissingValue, ## Required text, URL, or upload reference is empty.
    cpkInvalidSelect, ## Select values or options violate Discord limits.
    cpkDuplicateCustomId, ## Interactive IDs collide within one message.
    cpkInvalidMedia, ## Media metadata violates Discord limits.
    cpkInvalidStyle ## Style-specific fields are inconsistent.

  ComponentProblem* = object ## One validation failure with a stable tree path.
    kind*: ComponentProblemKind ## Machine-readable category.
    path*: string ## Root-relative component path.
    message*: string ## Human-readable Discord constraint.

  ComponentValidation* = object ## Result of validating an entire draft.
    problems*: seq[ComponentProblem] ## Empty when the draft is legal.

func valid*(validation: ComponentValidation): bool =
  ## Reports whether validation found no problems.
  validation.problems.len == 0

proc addProblem(validation: var ComponentValidation,
                kind: ComponentProblemKind, path, message: string) =
  validation.problems.add(ComponentProblem(
    kind: kind,
    path: path,
    message: message
  ))

func countComponents*(node: ComponentNode): int =
  ## Counts `node` and all descendants against Discord's total limit.
  if node.isNil:
    return 0
  result = 1
  for child in node.children:
    result += child.countComponents()

func isSelect(kind: MessageComponentKind): bool =
  kind in {
    mckStringSelect, mckUserSelect, mckRoleSelect,
    mckMentionableSelect, mckChannelSelect
  }

proc validateNode(node: ComponentNode, parent: Option[MessageComponentKind],
                  path: string, validation: var ComponentValidation,
                  customIds: var HashSet[string]) =
  if node.isNil:
    validation.addProblem(cpkInvalidChild, path, "component node is nil")
    return

  if node.customId.len > MaxCustomIdBytes:
    validation.addProblem(
      cpkCustomIdTooLong, path,
      "custom_id exceeds " & $MaxCustomIdBytes & " UTF-8 bytes"
    )

  if node.customId.len != 0:
    if node.customId in customIds:
      validation.addProblem(cpkDuplicateCustomId, path,
        "custom_id is duplicated within the message")
    else:
      customIds.incl node.customId

  if node.kind.isSelect and node.customId.len == 0:
    validation.addProblem(cpkMissingCustomId, path, "select requires custom_id")
  if node.kind.isSelect:
    if node.minValues < 0 or node.maxValues < node.minValues or
        node.maxValues > 25:
      validation.addProblem(
        cpkInvalidSelect, path,
        "select values must satisfy 0 <= min_values <= max_values <= 25"
      )
    if node.placeholder.runeLen > 150:
      validation.addProblem(cpkInvalidSelect, path,
        "select placeholder exceeds 150 characters")
    if node.defaultValues.len > 25:
      validation.addProblem(cpkInvalidSelect, path,
        "select has more than 25 default values")
    if node.kind == mckStringSelect:
      if node.options.len notin 1..25:
        validation.addProblem(
          cpkInvalidSelect, path,
          "string select requires between one and 25 options"
        )
      for option in node.options:
        if option.label.len == 0 or option.value.len == 0:
          validation.addProblem(
            cpkInvalidSelect, path,
            "string select option label and value cannot be empty"
          )
        if option.label.runeLen > 100 or option.value.runeLen > 100 or
            option.description.runeLen > 100:
          validation.addProblem(cpkInvalidSelect, path,
            "string select option fields exceed Discord's length limits")
      if node.defaultValues.len != 0:
        validation.addProblem(cpkInvalidSelect, path,
          "string select defaults belong on individual options")
    elif node.options.len != 0:
      validation.addProblem(
        cpkInvalidSelect, path,
        "auto-populated selects cannot carry string options"
      )
    for value in node.defaultValues:
      let compatible = case node.kind
        of mckUserSelect: value.kind == sdkUser
        of mckRoleSelect: value.kind == sdkRole
        of mckChannelSelect: value.kind == sdkChannel
        of mckMentionableSelect: value.kind in {sdkUser, sdkRole}
        else: false
      if not compatible:
        validation.addProblem(cpkInvalidSelect, path,
          "default value kind does not match the select kind")
    if node.kind != mckChannelSelect and node.channelTypes.len != 0:
      validation.addProblem(cpkInvalidSelect, path,
        "channel_types is legal only on a channel select")

  case node.kind
  of mckButton:
    if node.buttonStyle != bsPremium and node.text.len == 0 and
        node.emoji.isNone:
      validation.addProblem(cpkMissingValue, path, "button requires a label")
    if node.buttonStyle == bsPremium:
      if node.skuId.isNone or node.customId.len != 0 or node.url.len != 0:
        validation.addProblem(cpkInvalidStyle, path,
          "premium button requires only sku_id as its target")
    elif node.skuId.isSome:
      validation.addProblem(cpkInvalidStyle, path,
        "sku_id is legal only on a premium button")
    elif (node.customId.len == 0) == (node.url.len == 0):
      validation.addProblem(
        cpkButtonTargetConflict, path,
        "button requires exactly one of custom_id or url"
      )
    if node.url.len != 0 and node.buttonStyle != bsLink:
      validation.addProblem(
        cpkButtonTargetConflict, path,
        "URL button must use link style"
      )
    if node.url.len == 0 and node.buttonStyle == bsLink:
      validation.addProblem(
        cpkButtonTargetConflict, path,
        "link-style button requires a URL"
      )
    if node.url.len > 512:
      validation.addProblem(cpkButtonTargetConflict, path,
        "button URL exceeds 512 characters")
    if node.text.runeLen > 80:
      validation.addProblem(cpkMissingValue, path,
        "button label exceeds 80 characters")
    if node.emoji.isSome and node.emoji.get().name.len == 0 and
        node.emoji.get().id.isNone:
      validation.addProblem(cpkMissingValue, path,
        "button emoji requires a name or custom emoji ID")
  of mckTextDisplay:
    if node.text.len == 0:
      validation.addProblem(cpkMissingValue, path,
        "text display cannot be empty")
    elif node.text.runeLen > 4_000:
      validation.addProblem(cpkMissingValue, path,
        "text display exceeds 4000 characters")
  of mckThumbnail:
    if node.url.len == 0:
      validation.addProblem(cpkMissingValue, path,
        "media component requires a url")
    if parent.isNone or parent.get() != mckSection:
      validation.addProblem(
        cpkInvalidChild, path,
        "thumbnail is legal only as a section accessory"
      )
    if node.description.runeLen > 1_024:
      validation.addProblem(cpkInvalidMedia, path,
        "thumbnail description exceeds 1024 characters")
  of mckMediaItem:
    if node.url.len == 0:
      validation.addProblem(cpkMissingValue, path,
        "media component requires a url")
    if parent.isNone or parent.get() != mckMediaGallery:
      validation.addProblem(
        cpkInvalidChild, path,
        "media item is legal only inside a media gallery"
      )
    if node.description.runeLen > 1_024:
      validation.addProblem(cpkInvalidMedia, path,
        "media description exceeds 1024 characters")
  of mckFile:
    if node.text.len == 0:
      validation.addProblem(cpkMissingValue, path,
        "file requires an upload reference")
  of mckActionRow:
    let selects = node.children.countIt(it != nil and it.kind.isSelect)
    let buttons = node.children.countIt(it != nil and it.kind == mckButton)
    if node.children.len == 0 or
        (selects == 1 and node.children.len != 1) or
        (selects == 0 and (buttons != node.children.len or buttons > 5)) or
        selects > 1:
      validation.addProblem(
        cpkInvalidActionRow, path,
        "action row requires one select or between one and five buttons"
      )
  of mckSection:
    let textCount = node.children.countIt(
      it != nil and it.kind == mckTextDisplay)
    let accessoryCount = node.children.countIt(
      it != nil and it.kind in {mckButton, mckThumbnail})
    if textCount notin 1..3 or accessoryCount != 1 or
        textCount + accessoryCount != node.children.len:
      validation.addProblem(
        cpkInvalidSection, path,
        "section requires one to three text displays and exactly one accessory"
      )
  of mckMediaGallery:
    if node.children.len == 0 or
        node.children.anyIt(it == nil or it.kind != mckMediaItem):
      validation.addProblem(
        cpkInvalidChild, path,
        "media gallery accepts only media items"
      )
    if node.children.len > 10:
      validation.addProblem(
        cpkInvalidChild, path,
        "media gallery accepts at most ten media items"
      )
  of mckContainer:
    if node.children.len == 0:
      validation.addProblem(cpkInvalidChild, path, "container cannot be empty")
    if node.accentColor.isSome and
        node.accentColor.get() notin 0..0xff_ff_ff:
      validation.addProblem(cpkInvalidStyle, path,
        "container accent color must be a 24-bit RGB value")
  else:
    discard

  if parent.isSome and parent.get() == mckContainer and node.kind notin {
      mckActionRow, mckFile, mckMediaGallery, mckSection, mckSeparator,
      mckTextDisplay}:
    validation.addProblem(
      cpkInvalidChild, path,
      "component kind is not legal inside a container"
    )

  for index, child in node.children:
    child.validateNode(some(node.kind), path & "." & $index, validation,
      customIds)

proc validate*(draft: MessageDraft[V2]): ComponentValidation =
  ## Validates the complete V2 tree before serialization or transport.
  var total = 0
  let legalRoots = {
    mckActionRow, mckSection, mckTextDisplay, mckMediaGallery,
    mckFile, mckSeparator, mckContainer
  }
  var customIds: HashSet[string]
  if draft.v2.children.len == 0:
    result.addProblem(cpkInvalidRoot, "$",
      "Components V2 message requires at least one component")
  for index, node in draft.v2.children:
    total += node.countComponents()
    if node.isNil or node.kind notin legalRoots:
      result.addProblem(
        cpkInvalidRoot, $index,
        "component kind is not legal at the message root"
      )
    node.validateNode(none(MessageComponentKind), $index, result, customIds)
  if total > MaxMessageComponents:
    result.addProblem(
      cpkTooManyComponents, "$",
      "component tree contains " & $total & " components; Discord allows " &
        $MaxMessageComponents
    )

proc requireValid*(draft: MessageDraft[V2]) =
  ## Raises `ValueError` with the first Discord constraint when invalid.
  let validation = draft.validate()
  if not validation.valid:
    let problem = validation.problems[0]
    raise newException(ValueError, problem.path & ": " & problem.message)
