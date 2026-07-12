## Discord-aware validation for message and modal component trees.

import std/[options, sequtils, sets, unicode]

import cordnim/core/ids
import ./model

const
  MaxLegacyActionRows* = 5 ## Maximum top-level rows in a legacy message.
  MaxMessageComponents* = 40 ## Discord's total Components V2 node limit.
  MaxMessageRootComponents* = 40 ## Maximum root entries in a V2 message.
  MaxContainerComponents* = 40 ## Maximum direct children in a container.
  MaxCustomIdLength* = 100 ## Maximum characters in a component custom ID.
  MaxCustomIdBytes* = MaxCustomIdLength ## Compatibility name; validation uses
    ## Unicode characters, matching Discord's documented limit.

type
  ComponentProblemKind* = enum ## Stable categories returned by validation.
    cpkTooManyComponents, ## Tree exceeds `MaxMessageComponents`.
    cpkCycle, ## A component contains itself through one or more children.
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
    cpkDuplicateId, ## Nonzero integer component IDs collide in one message.
    cpkInvalidMedia, ## Media metadata violates Discord limits.
    cpkInvalidStyle, ## Style-specific fields are inconsistent.
    cpkInvalidText ## A component string is not valid UTF-8.

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

proc validateUtf8Field(value, field, path: string;
                       validation: var ComponentValidation) =
  if value.validateUtf8 != -1:
    validation.addProblem(cpkInvalidText, path,
      field & " must be valid UTF-8")

proc countComponentsImpl(node: ComponentNode,
                         visiting: var HashSet[pointer]): int =
  if node.isNil:
    return 0
  let identity = cast[pointer](node)
  if identity in visiting:
    raise newException(ValueError, "component tree contains a cycle")
  visiting.incl identity
  defer:
    visiting.excl identity
  # Media-gallery items have no component `type` or `id` and therefore do not
  # consume Discord's component-object budget.
  result = ord(node.kind != mckMediaItem)
  for child in node.children:
    result += child.countComponentsImpl(visiting)

proc countComponents*(node: ComponentNode): int =
  ## Counts component objects in `node` and its descendants against Discord's
  ## total limit. Media-gallery items are media objects and are not counted.
  ##
  ## Raises `ValueError` if the public mutable node graph contains a cycle.
  var visiting: HashSet[pointer]
  node.countComponentsImpl(visiting)

func isSelect(kind: MessageComponentKind): bool =
  kind in {
    mckStringSelect, mckUserSelect, mckRoleSelect,
    mckMentionableSelect, mckChannelSelect
  }

proc validateNode(node: ComponentNode, parent: Option[MessageComponentKind],
                  path: string, validation: var ComponentValidation,
                  customIds: var HashSet[string],
                  componentIds: var HashSet[uint32],
                  visiting: var HashSet[pointer], total: var int) =
  if node.isNil:
    validation.addProblem(cpkInvalidChild, path, "component node is nil")
    return

  let identity = cast[pointer](node)
  if identity in visiting:
    validation.addProblem(cpkCycle, path,
      "component tree contains a cycle")
    return
  visiting.incl identity
  defer:
    visiting.excl identity
  if node.kind != mckMediaItem:
    inc total

  node.text.validateUtf8Field("text", path, validation)
  node.customId.validateUtf8Field("custom_id", path, validation)
  node.url.validateUtf8Field("url", path, validation)
  node.placeholder.validateUtf8Field("placeholder", path, validation)
  node.description.validateUtf8Field("description", path, validation)
  if node.emoji.isSome:
    node.emoji.get.name.validateUtf8Field("emoji name", path, validation)
  for option in node.options:
    option.label.validateUtf8Field("select option label", path, validation)
    option.value.validateUtf8Field("select option value", path, validation)
    option.description.validateUtf8Field(
      "select option description", path, validation)
    if option.emoji.isSome:
      option.emoji.get.name.validateUtf8Field(
        "select option emoji name", path, validation)

  if node.kind == mckMediaItem and node.id.isSome:
    validation.addProblem(cpkInvalidMedia, path,
      "media gallery items are media objects and cannot carry component IDs")
  elif node.id.isSome:
    let id = node.id.get().toUint32()
    # Discord treats zero like an omitted ID and replaces it automatically.
    if id != 0:
      if id in componentIds:
        validation.addProblem(cpkDuplicateId, path,
          "nonzero component id is duplicated within the message")
      else:
        componentIds.incl id

  if node.customId.runeLen > MaxCustomIdLength:
    validation.addProblem(
      cpkCustomIdTooLong, path,
      "custom_id exceeds " & $MaxCustomIdLength & " characters"
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
    if node.required.isSome:
      validation.addProblem(cpkInvalidSelect, path,
        "required is legal only for selects inside modal labels")
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
    if node.defaultValues.len > 0 and
        node.defaultValues.len notin node.minValues..node.maxValues:
      validation.addProblem(cpkInvalidSelect, path,
        "default value count must satisfy min_values and max_values")
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
      let selectedCount = node.options.countIt(it.default)
      if selectedCount > 0 and
          selectedCount notin node.minValues..node.maxValues:
        validation.addProblem(cpkInvalidSelect, path,
          "default option count must satisfy min_values and max_values")
      if node.defaultValues.len != 0:
        validation.addProblem(cpkInvalidSelect, path,
          "string select defaults belong on individual options")
    elif node.options.len != 0:
      validation.addProblem(
        cpkInvalidSelect, path,
        "auto-populated selects cannot carry string options"
      )
    var seenDefaults: HashSet[string]
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
      let key = case value.kind
        of sdkUser: "user:" & $value.userId
        of sdkRole: "role:" & $value.roleId
        of sdkChannel: "channel:" & $value.channelId
      if key in seenDefaults:
        validation.addProblem(cpkInvalidSelect, path,
          "select default values must be unique")
      else:
        seenDefaults.incl key
    if node.kind != mckChannelSelect and node.channelTypes.len != 0:
      validation.addProblem(cpkInvalidSelect, path,
        "channel_types is legal only on a channel select")

  case node.kind
  of mckButton:
    if node.buttonStyle != bsPremium and node.text.len == 0 and
        node.emoji.isNone:
      validation.addProblem(cpkMissingValue, path, "button requires a label")
    if node.buttonStyle == bsPremium:
      if node.skuId.isNone or node.customId.len != 0 or node.url.len != 0 or
          node.text.len != 0 or node.emoji.isSome:
        validation.addProblem(cpkInvalidStyle, path,
          "premium button permits sku_id but not label, emoji, custom_id, or URL")
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
    if node.children.len > MaxContainerComponents:
      validation.addProblem(cpkTooManyComponents, path,
        "container has more than " & $MaxContainerComponents &
          " direct components")
  else:
    discard

  if parent.isSome and parent.get() == mckContainer and node.kind notin {
      mckActionRow, mckFile, mckMediaGallery, mckSection, mckSeparator,
      mckTextDisplay}:
    validation.addProblem(
      cpkInvalidChild, path,
      "component kind is not legal inside a container"
    )
  if parent.isSome and parent.get() == mckActionRow and
      node.kind != mckButton and not node.kind.isSelect:
    validation.addProblem(cpkInvalidChild, path,
      "action rows accept only buttons or selects")
  if parent.isSome and parent.get() notin {
      mckActionRow, mckContainer, mckMediaGallery, mckSection}:
    validation.addProblem(cpkInvalidChild, path,
      "component kind cannot contain child components")

  for index, child in node.children:
    child.validateNode(some(node.kind), path & "." & $index, validation,
      customIds, componentIds, visiting, total)

proc validate*(draft: MessageDraft[V2]): ComponentValidation =
  ## Validates the complete V2 tree before serialization or transport.
  var total = 0
  let legalRoots = {
    mckActionRow, mckSection, mckTextDisplay, mckMediaGallery,
    mckFile, mckSeparator, mckContainer
  }
  var customIds: HashSet[string]
  var componentIds: HashSet[uint32]
  var visiting: HashSet[pointer]
  if draft.v2.children.len == 0:
    result.addProblem(cpkInvalidRoot, "$",
      "Components V2 message requires at least one component")
  elif draft.v2.children.len > MaxMessageRootComponents:
    result.addProblem(cpkTooManyComponents, "$",
      "message has more than " & $MaxMessageRootComponents &
        " root components")
  for index, node in draft.v2.children:
    if node.isNil or node.kind notin legalRoots:
      result.addProblem(
        cpkInvalidRoot, $index,
        "component kind is not legal at the message root"
      )
    node.validateNode(none(MessageComponentKind), $index, result, customIds,
      componentIds, visiting, total)
  if total > MaxMessageComponents:
    result.addProblem(
      cpkTooManyComponents, "$",
      "component tree contains " & $total & " components; Discord allows " &
        $MaxMessageComponents
    )

proc validate*(draft: MessageDraft[Legacy]): ComponentValidation =
  ## Validates the action-row subset available to legacy messages.
  var total = 0
  var customIds: HashSet[string]
  var componentIds: HashSet[uint32]
  var visiting: HashSet[pointer]
  if draft.legacy.components.len > MaxLegacyActionRows:
    result.addProblem(cpkTooManyComponents, "$",
      "legacy message has more than " & $MaxLegacyActionRows & " action rows")
  for index, node in draft.legacy.components:
    if node.isNil or node.kind != mckActionRow:
      result.addProblem(cpkInvalidRoot, $index,
        "legacy message roots must be action rows")
    node.validateNode(none(MessageComponentKind), $index, result, customIds,
      componentIds, visiting, total)

proc requireValid*(draft: MessageDraft[V2]) =
  ## Raises `ValueError` with the first Discord constraint when invalid.
  let validation = draft.validate()
  if not validation.valid:
    let problem = validation.problems[0]
    raise newException(ValueError, problem.path & ": " & problem.message)

proc requireValid*(draft: MessageDraft[Legacy]) =
  ## Raises `ValueError` with the first legacy component constraint violated.
  let validation = draft.validate()
  if not validation.valid:
    let problem = validation.problems[0]
    raise newException(ValueError, problem.path & ": " & problem.message)
