## Compile-time derivation and runtime decoding for typed Discord modals.
##
## A modal is declared as an ordinary Nim object with metadata pragmas, then
## explicitly derived with `deriveDiscordModal`. The explicit derivation keeps
## the type declaration stable on Nim 2.2 while still generating a schema and
## a decoder for the concrete object type.

import std/[json, macros, options, strutils, tables, unicode]

import cordnim/core/ids

const
  MaxModalComponents* = 40 ## Maximum component count in a current modal.
  MaxModalCustomIdLength* = 100 ## Maximum modal or field custom ID length.

type
  ModalFieldKind* {.pure.} = enum ## Components accepted in a modal label.
    TextInput ## Free-form single-line or paragraph text.
    StringSelect ## Select from application-defined string options.
    UserSelect ## Select one or more Discord users.
    RoleSelect ## Select one or more Discord roles.
    MentionableSelect ## Select one or more users or roles.
    ChannelSelect ## Select one or more channels.
    FileUpload ## Upload one or more files.
    RadioGroup ## Select at most one application-defined option.
    CheckboxGroup ## Select zero or more application-defined options.
    Checkbox ## A single boolean checkbox.

  ModalTextStyle* {.pure.} = enum ## Discord text-input presentation styles.
    Short = 1 ## A single-line text input.
    Paragraph = 2 ## A multi-line text input.

  ModalChannelType* {.pure.} = enum ## Channel types accepted by a modal select.
    GuildText = 0 ## A text channel in a guild.
    Dm = 1 ## A direct-message channel.
    GuildVoice = 2 ## A voice channel in a guild.
    GroupDm = 3 ## A group direct-message channel.
    GuildCategory = 4 ## A guild category.
    GuildAnnouncement = 5 ## A guild announcement channel.
    AnnouncementThread = 10 ## A thread in an announcement channel.
    PublicThread = 11 ## A public thread.
    PrivateThread = 12 ## A private thread.
    GuildStageVoice = 13 ## A guild stage channel.
    GuildDirectory = 14 ## A guild directory channel.
    GuildForum = 15 ## A guild forum channel.
    GuildMedia = 16 ## A guild media channel.

  ModalChoiceSpec* = object ## One application-defined input option.
    label*: string ## User-facing option text.
    value*: string ## Stable value returned by Discord.
    description*: string ## Optional explanatory text.
    selected*: bool ## Whether Discord initially selects the option.

  ModalFieldSpec* = object ## Complete wire metadata for one typed modal field.
    name*: string ## Nim source field name.
    customId*: string ## Stable Discord component custom ID.
    label*: string ## User-facing label wrapper text.
    description*: string ## Optional label description.
    kind*: ModalFieldKind ## Interactive component kind.
    required*: bool ## Whether the field must have a value.
    minValues*: int ## Minimum selection or upload count.
    maxValues*: int ## Maximum selection or upload count.
    minLength*: int ## Minimum text-input character count.
    maxLength*: int ## Maximum text-input character count.
    placeholder*: string ## Optional input placeholder.
    textStyle*: ModalTextStyle ## Text style; ignored by other kinds.
    options*: seq[ModalChoiceSpec] ## Application-defined choices.
    channelTypes*: set[ModalChannelType] ## Allowed channel kinds.

  ModalSpec* = object ## A modal schema independent of interaction transport.
    customId*: string ## Stable routed identifier for the modal.
    title*: string ## User-facing modal title.
    fields*: seq[ModalFieldSpec] ## Ordered typed input fields.

  MentionableKind* {.pure.} = enum ## A mentionable-select entity category.
    User ## A selected Discord user.
    Role ## A selected Discord role.

  MentionableId* = object ## A typed user-or-role mentionable selection.
    case kind*: MentionableKind ## Selected entity category.
    of MentionableKind.User:
      userId*: UserId ## Selected user ID.
    of MentionableKind.Role:
      roleId*: RoleId ## Selected role ID.

  ModalAttachment* = object ## A resolved attachment uploaded through a modal.
    id*: AttachmentId ## Attachment snowflake.
    filename*: string ## Original filename.
    size*: int64 ## Size in bytes.
    url*: string ## Discord CDN URL.
    proxyUrl*: string ## Discord media proxy URL.
    description*: Option[string] ## Optional attachment description.
    contentType*: Option[string] ## Optional MIME type.
    raw*: JsonNode ## Lossless resolved attachment object.

  ModalResolvedKind* {.pure.} = enum ## A modal resolved-entity map category.
    Attachment ## An entry from `resolved.attachments`.
    User ## An entry from `resolved.users`.
    Member ## An entry from `resolved.members`.
    Role ## An entry from `resolved.roles`.
    Channel ## An entry from `resolved.channels`.

  ModalResolvedObserver* = proc(
    kind: ModalResolvedKind;
    id: string;
    raw: JsonNode
  ) {.gcsafe, raises: [].} ## Observes resolved entities used by a decoder.

  ModalAttachmentDecoder* = proc(
    id: string;
    raw: JsonNode
  ): ModalAttachment {.gcsafe, raises: [ValueError].} ## Converts one selected
    ## `resolved.attachments` entry; `ValueError` becomes an `AttachmentDecode`
    ## problem.

  ModalDecodeHooks* = object ## Extension points for resolved submit data.
    attachmentDecoder*: ModalAttachmentDecoder ## Optional converter; nil uses
                                               ## `parseModalAttachment`.
    observeResolved*: ModalResolvedObserver ## Observes consumed resolved data.

  ModalDecodeProblemKind* {.pure.} = enum ## Stable modal decode failures.
    InvalidPayload ## Submit data does not have the expected JSON shape.
    WrongModal ## Submitted modal custom ID does not match the type.
    DuplicateField ## More than one component uses the same custom ID.
    MissingField ## A required field response is absent.
    WrongComponentKind ## A response has a different Discord component type.
    WrongValueKind ## A response value has an unexpected JSON kind.
    TooFewValues ## A field contains too few submitted values.
    TooManyValues ## A field contains too many submitted values.
    TextTooShort ## A text response is shorter than its minimum.
    TextTooLong ## A text response is longer than its maximum.
    InvalidChoice ## A submitted option is not declared by the schema.
    InvalidSnowflake ## A selected entity ID is not a Discord snowflake.
    UnresolvedEntity ## A submitted ID is missing from resolved data.
    AttachmentDecode ## An attachment hook rejected resolved data.

  ModalDecodeProblem* = object ## One field or payload decoding problem.
    kind*: ModalDecodeProblemKind ## Machine-readable failure category.
    field*: string ## Nim field, or empty for payload errors.
    customId*: string ## Discord custom ID, when known.
    message*: string ## Human-readable diagnostic.

  ModalDecodeResult*[T] = object ## A typed value and all decoding problems.
    value*: T ## Partially decoded value on failure.
    problems*: seq[ModalDecodeProblem] ## Empty when decoding succeeded.

  ModalSubmission = object
    customId: string
    responses: Table[string, JsonNode]
    resolved: JsonNode
    problems: seq[ModalDecodeProblem]

template discordModal*(
    title: static[string];
    customId: static[string] = ""
  ) {.pragma.}
  ## Attaches modal-level metadata consumed by `deriveDiscordModal`.
  ##
  ## An empty modal `customId` derives from the Nim type name. Empty field
  ## `customId` values derive from their Nim field names. Derivation converts
  ## both names to snake case, so set explicit IDs before deploying a form that
  ## must survive later source renames.

template textInput*(
    label: static[string];
    description: static[string] = "";
    style: static[ModalTextStyle] = ModalTextStyle.Short;
    placeholder: static[string] = "";
    required: static[bool] = true;
    minLength: static[int] = 0;
    maxLength: static[int] = 4000;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares a `string` or `Option[string]` text-input field.

template stringSelect*(
    label: static[string];
    description: static[string] = "";
    placeholder: static[string] = "";
    required: static[bool] = true;
    minValues: static[int] = 1;
    maxValues: static[int] = 1;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares an enum-valued string select.
  ##
  ## A scalar uses `enum` or `Option[enum]`; a multi-select uses `seq[enum]` or
  ## `set[enum]`. Optional collections are not accepted and an unselected
  ## collection decodes as an empty value.

template userSelect*(
    label: static[string];
    description: static[string] = "";
    placeholder: static[string] = "";
    required: static[bool] = true;
    minValues: static[int] = 1;
    maxValues: static[int] = 1;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares a `UserId`, `Option[UserId]`, or `seq[UserId]` selection field.
  ##
  ## A non-required scalar must use `Option[UserId]`; an unselected sequence
  ## decodes as empty.

template roleSelect*(
    label: static[string];
    description: static[string] = "";
    placeholder: static[string] = "";
    required: static[bool] = true;
    minValues: static[int] = 1;
    maxValues: static[int] = 1;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares a `RoleId`, `Option[RoleId]`, or `seq[RoleId]` selection field.
  ##
  ## A non-required scalar must use `Option[RoleId]`; an unselected sequence
  ## decodes as empty.

template mentionableSelect*(
    label: static[string];
    description: static[string] = "";
    placeholder: static[string] = "";
    required: static[bool] = true;
    minValues: static[int] = 1;
    maxValues: static[int] = 1;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares a `MentionableId`, `Option[MentionableId]`, or
  ## `seq[MentionableId]` selection field.
  ##
  ## A non-required scalar must use `Option[MentionableId]`; an unselected
  ## sequence decodes as empty.

template channelSelect*(
    label: static[string];
    description: static[string] = "";
    placeholder: static[string] = "";
    required: static[bool] = true;
    minValues: static[int] = 1;
    maxValues: static[int] = 1;
    customId: static[string] = "";
    channelTypes: static[set[ModalChannelType]] = {}
  ) {.pragma.}
  ## Declares a `ChannelId`, `Option[ChannelId]`, or `seq[ChannelId]` selection
  ## field with an optional channel-type filter.
  ##
  ## A non-required scalar must use `Option[ChannelId]`; an unselected sequence
  ## decodes as empty.

template fileUpload*(
    label: static[string];
    description: static[string] = "";
    required: static[bool] = true;
    minFiles: static[int] = 1;
    maxFiles: static[int] = 1;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares a `seq[ModalAttachment]` upload field.

template radioGroup*(
    label: static[string];
    description: static[string] = "";
    required: static[bool] = true;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares an enum or `Option[enum]` radio-group field.

template checkboxGroup*(
    label: static[string];
    description: static[string] = "";
    required: static[bool] = true;
    minValues: static[int] = 1;
    maxValues: static[int] = 10;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares a `seq[enum]` or `set[enum]` checkbox-group field.
  ##
  ## The unselected state is an empty collection; `Option` collections are not
  ## accepted.

template checkbox*(
    label: static[string];
    description: static[string] = "";
    selected: static[bool] = false;
    customId: static[string] = ""
  ) {.pragma.}
  ## Declares a boolean checkbox field.

func ok*[T](decoded: ModalDecodeResult[T]): bool =
  ## Reports whether a modal submission decoded without problems.
  decoded.problems.len == 0

func initModalDecodeHooks*(): ModalDecodeHooks =
  ## Creates hooks that use the standard attachment decoder and no observer.
  ModalDecodeHooks()

proc parseModalAttachment*(id: string; raw: JsonNode): ModalAttachment =
  ## Parses Discord's resolved attachment object while retaining unknown fields.
  ##
  ## Raises `ValueError` when a required attachment field is absent or has an
  ## invalid JSON type.
  if raw.isNil or raw.kind != JObject:
    raise newException(ValueError, "resolved attachment must be an object")

  proc requiredString(name: string): string =
    if not raw.hasKey(name) or raw[name].kind != JString:
      raise newException(ValueError,
        "resolved attachment requires string field '" & name & "'")
    raw[name].getStr()

  if not raw.hasKey("size") or raw["size"].kind != JInt:
    raise newException(ValueError,
      "resolved attachment requires integer field 'size'")
  result = ModalAttachment(
    id: AttachmentId.parseId(id),
    filename: requiredString("filename"),
    size: raw["size"].getBiggestInt(),
    url: requiredString("url"),
    proxyUrl: requiredString("proxy_url"),
    description: none(string),
    contentType: none(string),
    raw: raw.copy()
  )
  if raw.hasKey("description") and raw["description"].kind == JString:
    result.description = some(raw["description"].getStr())
  if raw.hasKey("content_type") and raw["content_type"].kind == JString:
    result.contentType = some(raw["content_type"].getStr())

func addProblem(problems: var seq[ModalDecodeProblem];
                kind: ModalDecodeProblemKind; field, customId,
                message: string) =
  problems.add(ModalDecodeProblem(
    kind: kind,
    field: field,
    customId: customId,
    message: message
  ))

func containsChoice(field: ModalFieldSpec; value: string): bool =
  for choice in field.options:
    if choice.value == value:
      return true

func validate*(modal: ModalSpec): seq[string] =
  ## Returns every Discord schema problem in `modal` without I/O or exceptions.
  if modal.customId.runeLen notin 1..MaxModalCustomIdLength:
    result.add "modal custom_id must contain between 1 and " &
      $MaxModalCustomIdLength & " characters"
  if modal.title.runeLen notin 1..45:
    result.add "modal title must contain between 1 and 45 characters"
  if modal.fields.len notin 1..MaxModalComponents:
    result.add "modal must contain between 1 and " & $MaxModalComponents &
      " fields"

  var customIds: seq[string]
  for field in modal.fields:
    if field.customId.runeLen notin 1..MaxModalCustomIdLength:
      result.add field.name & ": custom_id must contain between 1 and " &
        $MaxModalCustomIdLength & " characters"
    if field.customId in customIds:
      result.add field.name & ": duplicate custom_id '" & field.customId & "'"
    customIds.add field.customId
    if field.label.runeLen notin 1..45:
      result.add field.name & ": label must contain between 1 and 45 characters"
    if field.description.len > 0 and field.description.runeLen > 100:
      result.add field.name & ": description exceeds 100 characters"
    if field.placeholder.runeLen >
        (if field.kind == ModalFieldKind.TextInput: 100 else: 150):
      result.add field.name & ": placeholder is too long"

    case field.kind
    of ModalFieldKind.TextInput:
      if field.minLength notin 0..4000 or field.maxLength notin 1..4000 or
          field.maxLength < field.minLength:
        result.add field.name & ": invalid text length range"
    of ModalFieldKind.StringSelect, ModalFieldKind.UserSelect,
        ModalFieldKind.RoleSelect, ModalFieldKind.MentionableSelect,
        ModalFieldKind.ChannelSelect:
      if field.minValues notin 0..25 or field.maxValues notin 1..25 or
          field.maxValues < field.minValues:
        result.add field.name & ": invalid select cardinality"
      if field.kind == ModalFieldKind.StringSelect and
          field.options.len notin 1..25:
        result.add field.name & ": string select requires 1-25 options"
      if field.kind == ModalFieldKind.StringSelect and
          field.maxValues > field.options.len:
        result.add field.name & ": maxValues exceeds the option count"
    of ModalFieldKind.FileUpload:
      if field.minValues notin 0..10 or field.maxValues notin 1..10 or
          field.maxValues < field.minValues:
        result.add field.name & ": invalid file cardinality"
    of ModalFieldKind.RadioGroup:
      if field.options.len notin 2..10:
        result.add field.name & ": radio group requires 2-10 options"
    of ModalFieldKind.CheckboxGroup:
      if field.options.len notin 1..10:
        result.add field.name & ": checkbox group requires 1-10 options"
      if field.minValues notin 0..10 or field.maxValues notin 1..10 or
          field.maxValues < field.minValues or
          field.maxValues > field.options.len:
        result.add field.name & ": invalid checkbox cardinality"
    of ModalFieldKind.Checkbox:
      discard

    if field.required and field.kind notin {
        ModalFieldKind.TextInput, ModalFieldKind.RadioGroup} and
        field.kind != ModalFieldKind.Checkbox and field.minValues == 0:
      result.add field.name & ": required field must select at least one value"
    for choice in field.options:
      if choice.label.runeLen notin 1..100 or
          choice.value.runeLen notin 1..100 or
          choice.description.runeLen > 100:
        result.add field.name &
          ": option text must contain at most 100 characters"

func componentType(kind: ModalFieldKind): int =
  case kind
  of ModalFieldKind.TextInput: 4
  of ModalFieldKind.StringSelect: 3
  of ModalFieldKind.UserSelect: 5
  of ModalFieldKind.RoleSelect: 6
  of ModalFieldKind.MentionableSelect: 7
  of ModalFieldKind.ChannelSelect: 8
  of ModalFieldKind.FileUpload: 19
  of ModalFieldKind.RadioGroup: 21
  of ModalFieldKind.CheckboxGroup: 22
  of ModalFieldKind.Checkbox: 23

func toJson*(modal: ModalSpec): JsonNode =
  ## Serializes a schema as Discord modal callback data.
  ##
  ## This function does not validate. Call `validate` first and serialize only
  ## when it returns an empty sequence.
  result = newJObject()
  result["custom_id"] = %modal.customId
  result["title"] = %modal.title
  result["components"] = newJArray()

  for field in modal.fields:
    var input = newJObject()
    input["type"] = %field.kind.componentType()
    input["custom_id"] = %field.customId
    case field.kind
    of ModalFieldKind.TextInput:
      input["style"] = %ord(field.textStyle)
      input["required"] = %field.required
      input["min_length"] = %field.minLength
      input["max_length"] = %field.maxLength
      if field.placeholder.len > 0:
        input["placeholder"] = %field.placeholder
    of ModalFieldKind.StringSelect, ModalFieldKind.RadioGroup,
        ModalFieldKind.CheckboxGroup:
      input["options"] = newJArray()
      for choice in field.options:
        var option = %*{"label": choice.label, "value": choice.value}
        if choice.description.len > 0:
          option["description"] = %choice.description
        if choice.selected:
          option["default"] = %true
        input["options"].add option
      input["required"] = %field.required
      if field.kind != ModalFieldKind.RadioGroup:
        input["min_values"] = %field.minValues
        input["max_values"] = %field.maxValues
      if field.kind == ModalFieldKind.StringSelect and
          field.placeholder.len > 0:
        input["placeholder"] = %field.placeholder
    of ModalFieldKind.UserSelect, ModalFieldKind.RoleSelect,
        ModalFieldKind.MentionableSelect, ModalFieldKind.ChannelSelect:
      input["required"] = %field.required
      input["min_values"] = %field.minValues
      input["max_values"] = %field.maxValues
      if field.placeholder.len > 0:
        input["placeholder"] = %field.placeholder
      if field.kind == ModalFieldKind.ChannelSelect and
          field.channelTypes.card > 0:
        input["channel_types"] = newJArray()
        for channelType in field.channelTypes:
          input["channel_types"].add(%ord(channelType))
    of ModalFieldKind.FileUpload:
      input["required"] = %field.required
      input["min_values"] = %field.minValues
      input["max_values"] = %field.maxValues
    of ModalFieldKind.Checkbox:
      if field.options.len > 0 and field.options[0].selected:
        input["default"] = %true

    var label = %*{
      "type": 18,
      "label": field.label,
      "component": input
    }
    if field.description.len > 0:
      label["description"] = %field.description
    result["components"].add label

func unwrapData(payload: JsonNode): JsonNode =
  if not payload.isNil and payload.kind == JObject and
      payload.hasKey("data") and payload["data"].kind == JObject:
    payload["data"]
  else:
    payload

proc collectResponses(node: JsonNode; submission: var ModalSubmission) =
  if node.isNil or node.kind != JObject:
    return
  # Current Label responses use `component`; deprecated modal Action Rows use
  # `components`. Recursing through both keeps one decoder for either payload.
  if node.hasKey("custom_id") and node["custom_id"].kind == JString:
    let customId = node["custom_id"].getStr()
    if submission.responses.hasKey(customId):
      submission.problems.addProblem(
        ModalDecodeProblemKind.DuplicateField, "", customId,
        "more than one submitted component uses custom_id '" & customId & "'"
      )
    else:
      submission.responses[customId] = node
  if node.hasKey("component"):
    collectResponses(node["component"], submission)
  if node.hasKey("components") and node["components"].kind == JArray:
    for child in node["components"]:
      collectResponses(child, submission)

proc parseSubmission(payload: JsonNode): ModalSubmission =
  let data = payload.unwrapData()
  result.responses = initTable[string, JsonNode]()
  result.resolved = newJObject()
  if data.isNil or data.kind != JObject:
    result.problems.addProblem(
      ModalDecodeProblemKind.InvalidPayload, "", "",
      "modal submit data must be a JSON object"
    )
    return
  if data.hasKey("custom_id") and data["custom_id"].kind == JString:
    result.customId = data["custom_id"].getStr()
  else:
    result.problems.addProblem(
      ModalDecodeProblemKind.InvalidPayload, "", "",
      "modal submit data requires string custom_id"
    )
  if data.hasKey("resolved") and data["resolved"].kind == JObject:
    result.resolved = data["resolved"]
  if data.hasKey("components") and data["components"].kind == JArray:
    for component in data["components"]:
      collectResponses(component, result)
  else:
    result.problems.addProblem(
      ModalDecodeProblemKind.InvalidPayload, "", "",
      "modal submit data requires a components array"
    )

func submissionProblems(submission: ModalSubmission):
    seq[ModalDecodeProblem] =
  submission.problems

func submissionCustomId(submission: ModalSubmission): string =
  submission.customId

func response(submission: ModalSubmission; field: ModalFieldSpec;
              problems: var seq[ModalDecodeProblem]): JsonNode =
  if not submission.responses.hasKey(field.customId):
    if field.required:
      problems.addProblem(
        ModalDecodeProblemKind.MissingField, field.name, field.customId,
        "required modal field is missing"
      )
    return nil
  result = submission.responses[field.customId]
  if not result.hasKey("type") or result["type"].kind != JInt or
      result["type"].getInt() != field.kind.componentType():
    problems.addProblem(
      ModalDecodeProblemKind.WrongComponentKind, field.name, field.customId,
      "submitted component type does not match the derived field"
    )

func validateCount(field: ModalFieldSpec; count: int;
                   problems: var seq[ModalDecodeProblem]) =
  if count < field.minValues:
    problems.addProblem(
      ModalDecodeProblemKind.TooFewValues, field.name, field.customId,
      "submitted field contains fewer than " & $field.minValues & " values"
    )
  if count > field.maxValues:
    problems.addProblem(
      ModalDecodeProblemKind.TooManyValues, field.name, field.customId,
      "submitted field contains more than " & $field.maxValues & " values"
    )

func decodeText(response: JsonNode; field: ModalFieldSpec;
                problems: var seq[ModalDecodeProblem]): Option[string] =
  if response.isNil:
    return none(string)
  if not response.hasKey("value") or response["value"].kind == JNull:
    if field.required:
      problems.addProblem(
        ModalDecodeProblemKind.MissingField, field.name, field.customId,
        "required text input has no value"
      )
    return none(string)
  if response["value"].kind != JString:
    problems.addProblem(
      ModalDecodeProblemKind.WrongValueKind, field.name, field.customId,
      "text input value must be a string"
    )
    return none(string)
  let value = response["value"].getStr()
  if value.runeLen < field.minLength:
    problems.addProblem(
      ModalDecodeProblemKind.TextTooShort, field.name, field.customId,
      "text input is shorter than " & $field.minLength & " characters"
    )
  if value.runeLen > field.maxLength:
    problems.addProblem(
      ModalDecodeProblemKind.TextTooLong, field.name, field.customId,
      "text input is longer than " & $field.maxLength & " characters"
    )
  some(value)

func decodeValues(response: JsonNode; field: ModalFieldSpec;
                  problems: var seq[ModalDecodeProblem]): seq[string] =
  if response.isNil:
    return
  if not response.hasKey("values") or response["values"].kind != JArray:
    problems.addProblem(
      ModalDecodeProblemKind.WrongValueKind, field.name, field.customId,
      "submitted component requires a values array"
    )
    return
  for node in response["values"]:
    if node.kind != JString:
      problems.addProblem(
        ModalDecodeProblemKind.WrongValueKind, field.name, field.customId,
        "submitted values must be strings"
      )
    else:
      result.add(node.getStr())
  field.validateCount(result.len, problems)

func decodeChoiceValues(response: JsonNode; field: ModalFieldSpec;
                        problems: var seq[ModalDecodeProblem]): seq[string] =
  result = decodeValues(response, field, problems)
  for value in result:
    if not field.containsChoice(value):
      problems.addProblem(
        ModalDecodeProblemKind.InvalidChoice, field.name, field.customId,
        "submitted value '" & value & "' is not a declared option"
      )

func decodeRadio(response: JsonNode; field: ModalFieldSpec;
                 problems: var seq[ModalDecodeProblem]): Option[string] =
  if response.isNil:
    return none(string)
  if not response.hasKey("value") or response["value"].kind == JNull:
    if field.required:
      problems.addProblem(
        ModalDecodeProblemKind.MissingField, field.name, field.customId,
        "required radio group has no selection"
      )
    return none(string)
  if response["value"].kind != JString:
    problems.addProblem(
      ModalDecodeProblemKind.WrongValueKind, field.name, field.customId,
      "radio group value must be a string or null"
    )
    return none(string)
  let value = response["value"].getStr()
  if not field.containsChoice(value):
    problems.addProblem(
      ModalDecodeProblemKind.InvalidChoice, field.name, field.customId,
      "submitted value '" & value & "' is not a declared option"
    )
  some(value)

func decodeCheckbox(response: JsonNode; field: ModalFieldSpec;
                    problems: var seq[ModalDecodeProblem]): bool =
  if response.isNil:
    return false
  if not response.hasKey("value") or response["value"].kind != JBool:
    problems.addProblem(
      ModalDecodeProblemKind.WrongValueKind, field.name, field.customId,
      "checkbox value must be a boolean"
    )
    return false
  response["value"].getBool()

func resolvedNode(submission: ModalSubmission; mapName, id: string): JsonNode =
  if submission.resolved.kind != JObject or
      not submission.resolved.hasKey(mapName) or
      submission.resolved[mapName].kind != JObject or
      not submission.resolved[mapName].hasKey(id):
    return nil
  submission.resolved[mapName][id]

proc observe(hooks: ModalDecodeHooks; kind: ModalResolvedKind;
             id: string; raw: JsonNode) =
  if not hooks.observeResolved.isNil:
    hooks.observeResolved(kind, id, raw)

proc decodeEntityValues(submission: ModalSubmission; response: JsonNode;
                        field: ModalFieldSpec; hooks: ModalDecodeHooks;
                        mapName: string; kind: ModalResolvedKind;
                        problems: var seq[ModalDecodeProblem]): seq[string] =
  result = decodeValues(response, field, problems)
  for id in result:
    let raw = submission.resolvedNode(mapName, id)
    if raw.isNil:
      problems.addProblem(
        ModalDecodeProblemKind.UnresolvedEntity, field.name, field.customId,
        "selected ID '" & id & "' is missing from resolved." & mapName
      )
    else:
      hooks.observe(kind, id, raw)
      if kind == ModalResolvedKind.User:
        let member = submission.resolvedNode("members", id)
        if not member.isNil:
          hooks.observe(ModalResolvedKind.Member, id, member)

proc decodeAttachments(submission: ModalSubmission; response: JsonNode;
                       field: ModalFieldSpec; hooks: ModalDecodeHooks;
                       problems: var seq[ModalDecodeProblem]):
                       seq[ModalAttachment] =
  let values = decodeValues(response, field, problems)
  for id in values:
    let raw = submission.resolvedNode("attachments", id)
    if raw.isNil:
      problems.addProblem(
        ModalDecodeProblemKind.UnresolvedEntity, field.name, field.customId,
        "attachment '" & id & "' is missing from resolved.attachments"
      )
    else:
      hooks.observe(ModalResolvedKind.Attachment, id, raw)
      try:
        if hooks.attachmentDecoder.isNil:
          result.add(parseModalAttachment(id, raw))
        else:
          result.add(hooks.attachmentDecoder(id, raw))
      except ValueError as error:
        problems.addProblem(
          ModalDecodeProblemKind.AttachmentDecode, field.name, field.customId,
          error.msg
        )

func wireName(name: string): string =
  for character in name:
    if character in {'A'..'Z'}:
      if result.len > 0:
        result.add('_')
      result.add(character.toLowerAscii())
    else:
      result.add(character)

proc parseTypedId[T](text: string): T =
  parseId(T, text)

type
  DerivedField = object
    sourceName: string
    symbol: NimNode
    typeNode: NimNode
    spec: ModalFieldSpec

  DerivedModal = object
    typeNode: NimNode
    title: string
    customId: string
    fields: seq[DerivedField]

proc decodeMentionable(submission: ModalSubmission; id: string;
                       field: ModalFieldSpec; hooks: ModalDecodeHooks;
                       problems: var seq[ModalDecodeProblem]): MentionableId

proc rendered(typeNode: NimNode): string {.compileTime.}

proc isNamed(node: NimNode; name: string): bool {.compileTime.} =
  node.kind in {nnkIdent, nnkSym} and node.strVal == name

proc pragmaCall(pragmas: NimNode; names: openArray[string]): NimNode
    {.compileTime.} =
  for pragma in pragmas:
    if pragma.kind == nnkCall and pragma.len > 0:
      for name in names:
        if pragma[0].isNamed(name):
          return pragma
  newEmptyNode()

proc enumNames(typeNode: NimNode): seq[string] {.compileTime.} =
  let implementation = typeNode.getTypeImpl()
  if implementation.kind != nnkEnumTy:
    return
  for index in 1..<implementation.len:
    let field = implementation[index]
    case field.kind
    of nnkSym, nnkIdent:
      result.add field.strVal
    of nnkEnumFieldDef:
      result.add field[0].strVal
    else:
      discard

proc genericPart(typeNode: NimNode; genericName: string): NimNode
    {.compileTime.} =
  if typeNode.kind == nnkBracketExpr and typeNode.len == 2 and
      typeNode[0].isNamed(genericName):
    typeNode[1]
  else:
    newEmptyNode()

proc valueType(typeNode: NimNode): NimNode {.compileTime.} =
  let optional = typeNode.genericPart("Option")
  if optional.kind != nnkEmpty: optional else: typeNode

proc choiceSpecs(typeNode: NimNode; field: NimNode): seq[ModalChoiceSpec]
    {.compileTime.} =
  var optionType = typeNode.valueType()
  let sequence = optionType.genericPart("seq")
  let setItem = optionType.genericPart("set")
  if sequence.kind != nnkEmpty:
    optionType = sequence
  elif setItem.kind != nnkEmpty:
    optionType = setItem
  let names = optionType.enumNames()
  if names.len == 0:
    error("field choices require an enum, seq[enum], or set[enum] type", field)
  for name in names:
    result.add(ModalChoiceSpec(label: name, value: name))

proc modalKind(name: string; field: NimNode): ModalFieldKind
    {.compileTime.} =
  case name
  of "textInput": result = ModalFieldKind.TextInput
  of "stringSelect": result = ModalFieldKind.StringSelect
  of "userSelect": result = ModalFieldKind.UserSelect
  of "roleSelect": result = ModalFieldKind.RoleSelect
  of "mentionableSelect": result = ModalFieldKind.MentionableSelect
  of "channelSelect": result = ModalFieldKind.ChannelSelect
  of "fileUpload": result = ModalFieldKind.FileUpload
  of "radioGroup": result = ModalFieldKind.RadioGroup
  of "checkboxGroup": result = ModalFieldKind.CheckboxGroup
  of "checkbox": result = ModalFieldKind.Checkbox
  else:
    error("unknown modal field pragma '" & name & "'", field)

proc modalChannelType(ordinal: int; field: NimNode): ModalChannelType
    {.compileTime.} =
  case ordinal
  of 0: result = ModalChannelType.GuildText
  of 1: result = ModalChannelType.Dm
  of 2: result = ModalChannelType.GuildVoice
  of 3: result = ModalChannelType.GroupDm
  of 4: result = ModalChannelType.GuildCategory
  of 5: result = ModalChannelType.GuildAnnouncement
  of 10: result = ModalChannelType.AnnouncementThread
  of 11: result = ModalChannelType.PublicThread
  of 12: result = ModalChannelType.PrivateThread
  of 13: result = ModalChannelType.GuildStageVoice
  of 14: result = ModalChannelType.GuildDirectory
  of 15: result = ModalChannelType.GuildForum
  of 16: result = ModalChannelType.GuildMedia
  else:
    error("invalid Discord channel type in channelSelect", field)

proc boolValue(node: NimNode): bool {.compileTime.} =
  node.intVal != 0

proc validateFieldType(field: DerivedField; source: NimNode)
    {.compileTime.} =
  let optionalType = field.typeNode.genericPart("Option")
  let unwrapped = if optionalType.kind == nnkEmpty:
      field.typeNode
    else:
      optionalType
  let sequenceType = unwrapped.genericPart("seq")
  let setType = unwrapped.genericPart("set")
  let collection = sequenceType.kind != nnkEmpty or setType.kind != nnkEmpty
  let scalar = if sequenceType.kind != nnkEmpty:
      sequenceType
    elif setType.kind != nnkEmpty:
      setType
    else:
      unwrapped

  if optionalType.kind != nnkEmpty and collection:
    error("optional modal collections use an empty collection, not " &
      "Option[seq] or Option[set]", source)

  case field.spec.kind
  of ModalFieldKind.TextInput:
    if unwrapped.rendered() != "string":
      error("textInput field type must be string or Option[string]", source)
  of ModalFieldKind.StringSelect:
    if scalar.getTypeImpl().kind != nnkEnumTy:
      error("stringSelect requires enum, seq[enum], or set[enum]", source)
  of ModalFieldKind.UserSelect:
    if not scalar.rendered().endsWith("UserId"):
      error("userSelect requires UserId, Option[UserId], or seq[UserId]",
        source)
  of ModalFieldKind.RoleSelect:
    if not scalar.rendered().endsWith("RoleId"):
      error("roleSelect requires RoleId, Option[RoleId], or seq[RoleId]",
        source)
  of ModalFieldKind.MentionableSelect:
    if not scalar.rendered().endsWith("MentionableId"):
      error("mentionableSelect requires MentionableId, " &
        "Option[MentionableId], or seq[MentionableId]", source)
  of ModalFieldKind.ChannelSelect:
    if not scalar.rendered().endsWith("ChannelId"):
      error("channelSelect requires ChannelId, Option[ChannelId], or " &
        "seq[ChannelId]", source)
  of ModalFieldKind.FileUpload:
    if sequenceType.kind == nnkEmpty or
        not sequenceType.rendered().endsWith("ModalAttachment"):
      error("fileUpload field type must be seq[ModalAttachment]", source)
  of ModalFieldKind.RadioGroup:
    if collection or scalar.getTypeImpl().kind != nnkEnumTy:
      error("radioGroup field type must be enum or Option[enum]", source)
  of ModalFieldKind.CheckboxGroup:
    if not collection or scalar.getTypeImpl().kind != nnkEnumTy:
      error("checkboxGroup requires seq[enum] or set[enum]", source)
  of ModalFieldKind.Checkbox:
    if field.typeNode.rendered() != "bool":
      error("checkbox field type must be bool", source)

  if field.spec.kind notin {
      ModalFieldKind.TextInput, ModalFieldKind.FileUpload,
      ModalFieldKind.RadioGroup, ModalFieldKind.CheckboxGroup,
      ModalFieldKind.Checkbox} and not collection and
      field.spec.maxValues != 1:
    error("a scalar select field requires maxValues = 1", source)
  if field.spec.kind notin {
      ModalFieldKind.FileUpload, ModalFieldKind.CheckboxGroup,
      ModalFieldKind.Checkbox} and not field.spec.required and
      not collection and optionalType.kind == nnkEmpty:
    error("a non-required scalar modal field must use Option[T]", source)
  if field.spec.kind == ModalFieldKind.RadioGroup and
      field.spec.required == (optionalType.kind != nnkEmpty):
    error("radioGroup required metadata must agree with Option[T]", source)
  if field.spec.kind == ModalFieldKind.TextInput and
      field.spec.required == (optionalType.kind != nnkEmpty):
    error("textInput required metadata must agree with Option[string]", source)

proc parseField(definition, declaredName, typeNode: NimNode): DerivedField
    {.compileTime.} =
  var nameNode = declaredName
  var pragmas = newEmptyNode()
  if declaredName.kind == nnkPragmaExpr:
    nameNode = declaredName[0]
    pragmas = declaredName[1]
  if pragmas.kind == nnkEmpty:
    error("modal object field requires a modal component pragma", declaredName)

  let metadata = pragmas.pragmaCall([
    "textInput", "stringSelect", "userSelect", "roleSelect",
    "mentionableSelect", "channelSelect", "fileUpload", "radioGroup",
    "checkboxGroup", "checkbox"
  ])
  if metadata.kind == nnkEmpty:
    error("modal object field requires one supported component pragma",
      declaredName)

  # Semchecked pragma templates include a duplicate argument tail on Nim 2.2.
  # Fixed parameter positions deliberately read only the first expanded set.
  let pragmaName = metadata[0].strVal
  result.sourceName = nameNode.strVal
  result.symbol = nameNode
  result.typeNode = typeNode
  result.spec = ModalFieldSpec(
    name: result.sourceName,
    customId: result.sourceName.wireName(),
    kind: modalKind(pragmaName, declaredName),
    textStyle: ModalTextStyle.Short
  )

  case result.spec.kind
  of ModalFieldKind.TextInput:
    result.spec.label = metadata[1].strVal
    result.spec.description = metadata[2].strVal
    result.spec.textStyle = ModalTextStyle(metadata[3].intVal)
    result.spec.placeholder = metadata[4].strVal
    result.spec.required = metadata[5].boolValue()
    result.spec.minLength = metadata[6].intVal.int
    result.spec.maxLength = metadata[7].intVal.int
    if metadata[8].strVal.len > 0:
      result.spec.customId = metadata[8].strVal
  of ModalFieldKind.StringSelect, ModalFieldKind.UserSelect,
      ModalFieldKind.RoleSelect, ModalFieldKind.MentionableSelect,
      ModalFieldKind.ChannelSelect:
    result.spec.label = metadata[1].strVal
    result.spec.description = metadata[2].strVal
    result.spec.placeholder = metadata[3].strVal
    result.spec.required = metadata[4].boolValue()
    result.spec.minValues = metadata[5].intVal.int
    result.spec.maxValues = metadata[6].intVal.int
    if metadata[7].strVal.len > 0:
      result.spec.customId = metadata[7].strVal
    if result.spec.kind == ModalFieldKind.StringSelect:
      result.spec.options = choiceSpecs(typeNode, declaredName)
    elif result.spec.kind == ModalFieldKind.ChannelSelect:
      for item in metadata[8]:
        result.spec.channelTypes.incl(modalChannelType(item.intVal.int,
          declaredName))
  of ModalFieldKind.FileUpload:
    result.spec.label = metadata[1].strVal
    result.spec.description = metadata[2].strVal
    result.spec.required = metadata[3].boolValue()
    result.spec.minValues = metadata[4].intVal.int
    result.spec.maxValues = metadata[5].intVal.int
    if metadata[6].strVal.len > 0:
      result.spec.customId = metadata[6].strVal
  of ModalFieldKind.RadioGroup:
    result.spec.label = metadata[1].strVal
    result.spec.description = metadata[2].strVal
    result.spec.required = metadata[3].boolValue()
    if metadata[4].strVal.len > 0:
      result.spec.customId = metadata[4].strVal
    result.spec.options = choiceSpecs(typeNode, declaredName)
  of ModalFieldKind.CheckboxGroup:
    result.spec.label = metadata[1].strVal
    result.spec.description = metadata[2].strVal
    result.spec.required = metadata[3].boolValue()
    result.spec.minValues = metadata[4].intVal.int
    result.spec.maxValues = metadata[5].intVal.int
    if metadata[6].strVal.len > 0:
      result.spec.customId = metadata[6].strVal
    result.spec.options = choiceSpecs(typeNode, declaredName)
  of ModalFieldKind.Checkbox:
    result.spec.label = metadata[1].strVal
    result.spec.description = metadata[2].strVal
    result.spec.required = false
    result.spec.options = @[
      ModalChoiceSpec(label: "checked", value: "true",
        selected: metadata[3].boolValue())
    ]
    if metadata[4].strVal.len > 0:
      result.spec.customId = metadata[4].strVal

  result.validateFieldType(declaredName)

proc deriveModal(typeNode: NimNode): DerivedModal {.compileTime.} =
  let implementation = typeNode.getImpl()
  if implementation.kind != nnkTypeDef:
    error("deriveDiscordModal expects a named object type", typeNode)
  result.typeNode = typeNode

  var typePragmas = newEmptyNode()
  if implementation[0].kind == nnkPragmaExpr:
    typePragmas = implementation[0][1]
  let metadata = typePragmas.pragmaCall(["discordModal"])
  if metadata.kind == nnkEmpty:
    error("modal type must use {.discordModal(title = ...).}", typeNode)
  # See the field metadata note above about duplicated semchecked arguments.
  result.title = metadata[1].strVal
  result.customId = metadata[2].strVal
  if result.customId.len == 0:
    result.customId = typeNode.strVal.wireName()

  let body = implementation[2]
  if body.kind != nnkObjectTy:
    error("deriveDiscordModal expects an object type", typeNode)
  if body[1].kind != nnkEmpty:
    error("modal object inheritance is not supported", typeNode)
  for definition in body[2]:
    if definition.kind != nnkIdentDefs:
      error("modal object supports only ordinary named fields", definition)
    let fieldType = definition[^2]
    for index in 0..<definition.len - 2:
      result.fields.add(parseField(definition, definition[index], fieldType))

  let schema = ModalSpec(
    customId: result.customId,
    title: result.title,
    fields: block:
      var fields: seq[ModalFieldSpec]
      for field in result.fields:
        fields.add field.spec
      fields
  )
  let problems = schema.validate()
  if problems.len > 0:
    error("invalid Discord modal: " & problems.join("; "), typeNode)

proc choiceExpr(choice: ModalChoiceSpec): NimNode {.compileTime.} =
  let choiceType = bindSym"ModalChoiceSpec"
  newTree(nnkObjConstr, choiceType,
    newTree(nnkExprColonExpr, ident"label", newLit(choice.label)),
    newTree(nnkExprColonExpr, ident"value", newLit(choice.value)),
    newTree(nnkExprColonExpr, ident"description",
      newLit(choice.description)),
    newTree(nnkExprColonExpr, ident"selected", newLit(choice.selected)))

proc fieldSpecExpr(field: ModalFieldSpec): NimNode {.compileTime.} =
  var choices = newTree(nnkPrefix, ident"@", newTree(nnkBracket))
  for choice in field.options:
    choices[1].add(choiceExpr(choice))
  var channels = newTree(nnkCurly)
  for channelType in field.channelTypes:
    channels.add(newDotExpr(bindSym"ModalChannelType",
      ident($channelType)))
  let specType = bindSym"ModalFieldSpec"
  result = newTree(nnkObjConstr, specType,
    newTree(nnkExprColonExpr, ident"name", newLit(field.name)),
    newTree(nnkExprColonExpr, ident"customId", newLit(field.customId)),
    newTree(nnkExprColonExpr, ident"label", newLit(field.label)),
    newTree(nnkExprColonExpr, ident"description",
      newLit(field.description)),
    newTree(nnkExprColonExpr, ident"kind",
      newCall(bindSym"ModalFieldKind", newLit(ord(field.kind)))),
    newTree(nnkExprColonExpr, ident"required", newLit(field.required)),
    newTree(nnkExprColonExpr, ident"minValues", newLit(field.minValues)),
    newTree(nnkExprColonExpr, ident"maxValues", newLit(field.maxValues)),
    newTree(nnkExprColonExpr, ident"minLength", newLit(field.minLength)),
    newTree(nnkExprColonExpr, ident"maxLength", newLit(field.maxLength)),
    newTree(nnkExprColonExpr, ident"placeholder",
      newLit(field.placeholder)),
    newTree(nnkExprColonExpr, ident"textStyle",
      newCall(bindSym"ModalTextStyle", newLit(ord(field.textStyle)))),
    newTree(nnkExprColonExpr, ident"options", choices),
    newTree(nnkExprColonExpr, ident"channelTypes", channels))

proc specExpr(modal: DerivedModal): NimNode {.compileTime.} =
  var fields = newTree(nnkPrefix, ident"@", newTree(nnkBracket))
  for field in modal.fields:
    fields[1].add(fieldSpecExpr(field.spec))
  newTree(nnkObjConstr, bindSym"ModalSpec",
    newTree(nnkExprColonExpr, ident"customId", newLit(modal.customId)),
    newTree(nnkExprColonExpr, ident"title", newLit(modal.title)),
    newTree(nnkExprColonExpr, ident"fields", fields))

proc rendered(typeNode: NimNode): string {.compileTime.} =
  typeNode.repr.replace(" ", "")

proc zeroValueExpr(typeNode: NimNode): NimNode {.compileTime.} =
  let value = genSym(nskVar, "zeroValue")
  result = quote do:
    block:
      var `value`: `typeNode`
      `value`

proc scalarDecode(typeNode, value, field, problems: NimNode;
                  idKind = ""): NimNode {.compileTime.} =
  let typeName = typeNode.rendered()
  let implementation = typeNode.getTypeImpl()
  let zeroValue = typeNode.zeroValueExpr()
  if typeName == "string":
    result = value
  elif implementation.kind == nnkEnumTy:
    let parse = bindSym"parseEnum"
    let invalid = bindSym"InvalidChoice"
    result = quote do:
      try:
        `parse`[`typeNode`](`value`)
      except ValueError:
        `problems`.addProblem(
          ModalDecodeProblemKind.`invalid`, `field`.name, `field`.customId,
          "submitted value '" & `value` & "' is not representable by the " &
            "field type"
        )
        `zeroValue`
  elif typeName.endsWith(idKind) and idKind.len > 0:
    let parse = bindSym"parseTypedId"
    let invalid = bindSym"InvalidSnowflake"
    result = quote do:
      try:
        `parse`[`typeNode`](`value`)
      except ValueError:
        `problems`.addProblem(
          ModalDecodeProblemKind.`invalid`, `field`.name, `field`.customId,
          "submitted value '" & `value` & "' is not a valid Discord snowflake"
        )
        `zeroValue`
  else:
    error("unsupported modal field scalar type '" & typeName & "'", typeNode)

proc decodeFieldExpr(derived: DerivedField; submission, field, hooks,
                     problems: NimNode): NimNode {.compileTime.} =
  let responseCall = newCall(bindSym"response", submission, field, problems)
  let responseLocal = genSym(nskLet, "response")
  let typeNode = derived.typeNode
  let optionalType = typeNode.genericPart("Option")
  let sequenceType = typeNode.genericPart("seq")
  let setType = typeNode.genericPart("set")

  case derived.spec.kind
  of ModalFieldKind.TextInput:
    let textValue = genSym(nskLet, "textValue")
    let decode = bindSym"decodeText"
    if optionalType.kind != nnkEmpty and optionalType.rendered() == "string":
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          `decode`(`responseLocal`, `field`, `problems`)
    elif typeNode.rendered() == "string":
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          let `textValue` = `decode`(`responseLocal`, `field`, `problems`)
          `textValue`.get("")
    else:
      error("textInput field type must be string or Option[string]",
        derived.symbol)
  of ModalFieldKind.StringSelect, ModalFieldKind.CheckboxGroup:
    let decode = bindSym"decodeChoiceValues"
    let values = genSym(nskLet, "values")
    if sequenceType.kind != nnkEmpty:
      let item = genSym(nskForVar, "item")
      let converted = scalarDecode(sequenceType, item, field, problems)
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          let `values` = `decode`(`responseLocal`, `field`, `problems`)
          var decoded: `typeNode`
          for `item` in `values`:
            decoded.add `converted`
          decoded
    elif setType.kind != nnkEmpty:
      if setType.getTypeImpl().kind != nnkEnumTy:
        error("modal set field requires an enum element type", derived.symbol)
      let item = genSym(nskForVar, "item")
      let converted = scalarDecode(setType, item, field, problems)
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          let `values` = `decode`(`responseLocal`, `field`, `problems`)
          var decoded: `typeNode`
          for `item` in `values`:
            decoded.incl `converted`
          decoded
    else:
      let baseType = if optionalType.kind != nnkEmpty:
          optionalType
        else:
          typeNode
      let first = genSym(nskLet, "first")
      let converted = scalarDecode(baseType, first, field, problems)
      let zeroValue = typeNode.zeroValueExpr()
      if optionalType.kind != nnkEmpty:
        let someProc = bindSym"some"
        let noneProc = bindSym"none"
        result = quote do:
          block:
            let `responseLocal` = `responseCall`
            let `values` = `decode`(`responseLocal`, `field`, `problems`)
            if `values`.len > 0:
              let `first` = `values`[0]
              `someProc`(`converted`)
            else:
              `noneProc`(`baseType`)
      else:
        result = quote do:
          block:
            let `responseLocal` = `responseCall`
            let `values` = `decode`(`responseLocal`, `field`, `problems`)
            if `values`.len > 0:
              let `first` = `values`[0]
              `converted`
            else:
              `zeroValue`
  of ModalFieldKind.UserSelect, ModalFieldKind.RoleSelect,
      ModalFieldKind.ChannelSelect:
    let decode = bindSym"decodeEntityValues"
    let values = genSym(nskLet, "values")
    let suffix = case derived.spec.kind
      of ModalFieldKind.UserSelect: "UserId"
      of ModalFieldKind.RoleSelect: "RoleId"
      else: "ChannelId"
    let mapName = case derived.spec.kind
      of ModalFieldKind.UserSelect: newLit("users")
      of ModalFieldKind.RoleSelect: newLit("roles")
      else: newLit("channels")
    let resolvedKindName = case derived.spec.kind
      of ModalFieldKind.UserSelect: "User"
      of ModalFieldKind.RoleSelect: "Role"
      else: "Channel"
    let resolvedKind = newDotExpr(bindSym"ModalResolvedKind",
      ident(resolvedKindName))
    if sequenceType.kind != nnkEmpty:
      let item = genSym(nskForVar, "item")
      let converted = scalarDecode(sequenceType, item, field, problems, suffix)
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          let `values` = `decode`(`submission`, `responseLocal`, `field`,
            `hooks`, `mapName`, `resolvedKind`, `problems`)
          var decoded: `typeNode`
          for `item` in `values`:
            decoded.add `converted`
          decoded
    else:
      let baseType = if optionalType.kind != nnkEmpty:
          optionalType
        else:
          typeNode
      let first = genSym(nskLet, "first")
      let converted = scalarDecode(baseType, first, field, problems, suffix)
      let zeroValue = typeNode.zeroValueExpr()
      if optionalType.kind != nnkEmpty:
        let someProc = bindSym"some"
        let noneProc = bindSym"none"
        result = quote do:
          block:
            let `responseLocal` = `responseCall`
            let `values` = `decode`(`submission`, `responseLocal`, `field`,
              `hooks`, `mapName`, `resolvedKind`, `problems`)
            if `values`.len > 0:
              let `first` = `values`[0]
              `someProc`(`converted`)
            else:
              `noneProc`(`baseType`)
      else:
        result = quote do:
          block:
            let `responseLocal` = `responseCall`
            let `values` = `decode`(`submission`, `responseLocal`, `field`,
              `hooks`, `mapName`, `resolvedKind`, `problems`)
            if `values`.len > 0:
              let `first` = `values`[0]
              `converted`
            else:
              `zeroValue`
  of ModalFieldKind.MentionableSelect:
    let decode = bindSym"decodeValues"
    let values = genSym(nskLet, "values")
    let item = genSym(nskForVar, "item")
    let decoder = bindSym"decodeMentionable"
    if sequenceType.kind != nnkEmpty and
        sequenceType.rendered().endsWith("MentionableId"):
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          let `values` = `decode`(`responseLocal`, `field`, `problems`)
          var decoded: `typeNode`
          for `item` in `values`:
            decoded.add `decoder`(`submission`, `item`, `field`, `hooks`,
              `problems`)
          decoded
    else:
      let baseType = if optionalType.kind != nnkEmpty:
          optionalType
        else:
          typeNode
      if not baseType.rendered().endsWith("MentionableId"):
        error("mentionableSelect requires MentionableId, " &
          "Option[MentionableId], or seq[MentionableId]", derived.symbol)
      let first = genSym(nskLet, "first")
      let converted = newCall(decoder, submission, first, field, hooks,
        problems)
      let zeroValue = typeNode.zeroValueExpr()
      if optionalType.kind != nnkEmpty:
        let someProc = bindSym"some"
        let noneProc = bindSym"none"
        result = quote do:
          block:
            let `responseLocal` = `responseCall`
            let `values` = `decode`(`responseLocal`, `field`, `problems`)
            if `values`.len > 0:
              let `first` = `values`[0]
              `someProc`(`converted`)
            else:
              `noneProc`(`baseType`)
      else:
        result = quote do:
          block:
            let `responseLocal` = `responseCall`
            let `values` = `decode`(`responseLocal`, `field`, `problems`)
            if `values`.len > 0:
              let `first` = `values`[0]
              `converted`
            else:
              `zeroValue`
  of ModalFieldKind.FileUpload:
    if sequenceType.kind == nnkEmpty or
        not sequenceType.rendered().endsWith("ModalAttachment"):
      error("fileUpload field type must be seq[ModalAttachment]",
        derived.symbol)
    let decode = bindSym"decodeAttachments"
    result = quote do:
      block:
        let `responseLocal` = `responseCall`
        `decode`(`submission`, `responseLocal`, `field`, `hooks`, `problems`)
  of ModalFieldKind.RadioGroup:
    let decode = bindSym"decodeRadio"
    let selected = genSym(nskLet, "selected")
    let baseType = if optionalType.kind != nnkEmpty: optionalType else: typeNode
    if baseType.getTypeImpl().kind != nnkEnumTy:
      error("radioGroup field type must be enum or Option[enum]",
        derived.symbol)
    let item = genSym(nskLet, "item")
    let converted = scalarDecode(baseType, item, field, problems)
    let zeroValue = typeNode.zeroValueExpr()
    if optionalType.kind != nnkEmpty:
      let someProc = bindSym"some"
      let noneProc = bindSym"none"
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          let `selected` = `decode`(`responseLocal`, `field`, `problems`)
          if `selected`.isSome:
            let `item` = `selected`.get()
            `someProc`(`converted`)
          else:
            `noneProc`(`baseType`)
    else:
      result = quote do:
        block:
          let `responseLocal` = `responseCall`
          let `selected` = `decode`(`responseLocal`, `field`, `problems`)
          if `selected`.isSome:
            let `item` = `selected`.get()
            `converted`
          else:
            `zeroValue`
  of ModalFieldKind.Checkbox:
    if typeNode.rendered() != "bool":
      error("checkbox field type must be bool", derived.symbol)
    let decode = bindSym"decodeCheckbox"
    result = quote do:
      block:
        let `responseLocal` = `responseCall`
        `decode`(`responseLocal`, `field`, `problems`)

proc decodeMentionable(submission: ModalSubmission; id: string;
                       field: ModalFieldSpec; hooks: ModalDecodeHooks;
                       problems: var seq[ModalDecodeProblem]): MentionableId =
  let user = submission.resolvedNode("users", id)
  if not user.isNil:
    hooks.observe(ModalResolvedKind.User, id, user)
    try:
      return MentionableId(
        kind: MentionableKind.User,
        userId: UserId.parseId(id)
      )
    except ValueError:
      problems.addProblem(
        ModalDecodeProblemKind.InvalidSnowflake, field.name, field.customId,
        "mentionable user ID is not a Discord snowflake"
      )
      return MentionableId(kind: MentionableKind.User)

  let role = submission.resolvedNode("roles", id)
  if not role.isNil:
    hooks.observe(ModalResolvedKind.Role, id, role)
    try:
      return MentionableId(
        kind: MentionableKind.Role,
        roleId: RoleId.parseId(id)
      )
    except ValueError:
      problems.addProblem(
        ModalDecodeProblemKind.InvalidSnowflake, field.name, field.customId,
        "mentionable role ID is not a Discord snowflake"
      )
      return MentionableId(kind: MentionableKind.Role)

  problems.addProblem(
    ModalDecodeProblemKind.UnresolvedEntity, field.name, field.customId,
    "mentionable '" & id & "' is absent from resolved users and roles"
  )
  MentionableId(kind: MentionableKind.User)

macro deriveDiscordModal*(modalType: typedesc): untyped =
  ## Generates `modalSpec`, `modalCustomId`, and `decodeDiscordModal` overloads.
  ##
  ## Invoke this once, at module scope, after declaring an object annotated with
  ## `discordModal`. The generated overloads are exported for the declared type
  ## and perform no I/O. `decodeDiscordModal` returns a partially decoded value
  ## and aggregates malformed submit data in `ModalDecodeResult.problems`
  ## instead of raising it.
  let modal = deriveModal(modalType)
  let typeNode = modal.typeNode
  let schema = modal.specExpr()
  let customId = newLit(modal.customId)
  let modalSpecProc = ident"modalSpec"
  let modalCustomIdProc = ident"modalCustomId"
  let decodeProc = ident"decodeDiscordModal"
  let payload = genSym(nskParam, "payload")
  let hooks = genSym(nskParam, "hooks")
  let decoded = genSym(nskVar, "decoded")
  let submission = genSym(nskLet, "submission")
  let getSubmissionProblems = bindSym"submissionProblems"
  let getSubmissionCustomId = bindSym"submissionCustomId"

  var decodeBody = newStmtList()
  decodeBody.add quote do:
    var `decoded`: ModalDecodeResult[`typeNode`]
    let `submission` = parseSubmission(`payload`)
    `decoded`.problems.add `getSubmissionProblems`(`submission`)
    let submittedCustomId = `getSubmissionCustomId`(`submission`)
    if submittedCustomId.len > 0 and submittedCustomId != `customId`:
      `decoded`.problems.addProblem(
        ModalDecodeProblemKind.WrongModal, "", submittedCustomId,
        "submitted modal custom_id does not match " & `customId`
      )

  for derived in modal.fields:
    let fieldSpec = derived.spec.fieldSpecExpr()
    let fieldLocal = genSym(nskLet, derived.sourceName & "Spec")
    let value = decodeFieldExpr(derived, submission, fieldLocal, hooks,
      newDotExpr(decoded, ident"problems"))
    let target = newDotExpr(newDotExpr(decoded, ident"value"),
      ident(derived.sourceName))
    decodeBody.add quote do:
      let `fieldLocal` = `fieldSpec`
      `target` = `value`
  decodeBody.add(newTree(nnkReturnStmt, decoded))

  # The explicit macro emits ordinary overloads instead of mutating the type
  # declaration, which avoids relying on experimental type pragma transforms.
  result = quote do:
    func `modalSpecProc`*(t: typedesc[`typeNode`]): ModalSpec =
      ## Returns the compile-time-derived Discord modal schema.
      `schema`

    func `modalCustomIdProc`*(t: typedesc[`typeNode`]): string =
      ## Returns the modal custom ID generated for this form type.
      `customId`

    proc `decodeProc`*(t: typedesc[`typeNode`]; `payload`: JsonNode;
                       `hooks`: ModalDecodeHooks = initModalDecodeHooks()):
                       ModalDecodeResult[`typeNode`] =
      ## Decodes submit data, collecting malformed fields instead of raising.
      ##
      ## On failure, `value` may be partially populated and `problems` contains
      ## every detected payload, field, resolved-entity, and attachment problem.
      `decodeBody`
