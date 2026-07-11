## Explicit representations for optional Discord fields and PATCH values.

type
  FieldKind* {.pure.} = enum ## Presence state of a decoded Discord JSON field.
    Absent, ## The property was omitted from the payload.
    NullValue, ## The property was present with JSON `null`.
    Present ## The property contained a typed value.

  DiscordField*[T] = object ## A field preserving omission, JSON null, and
                            ## value.
    case kind*: FieldKind ## Presence discriminator for safe case analysis.
    of FieldKind.Present:
      value*: T ## Decoded value, available only for `Present`.
    of FieldKind.Absent, FieldKind.NullValue:
      discard

  PatchKind* {.pure.} = enum ## Intended update behavior for a Discord property.
    LeaveUnchanged, ## Omit the property from the update payload.
    ClearValue, ## Send JSON `null` to clear the property.
    SetValue ## Send a typed replacement value.

  Patch*[T] = object ## An update field distinguishing no change, clear, and
                     ## set.
    case kind*: PatchKind ## Update behavior discriminator for safe case
                          ## analysis.
    of PatchKind.SetValue:
      value*: T ## Replacement value, available only for `SetValue`.
    of PatchKind.LeaveUnchanged, PatchKind.ClearValue:
      discard

func absent*[T](): DiscordField[T] {.inline.} =
  ## Constructs a decoded field whose property was omitted.
  DiscordField[T](kind: FieldKind.Absent)

func nullValue*[T](): DiscordField[T] {.inline.} =
  ## Constructs a decoded field whose property was explicitly null.
  DiscordField[T](kind: FieldKind.NullValue)

func present*[T](value: sink T): DiscordField[T] {.inline.} =
  ## Constructs a decoded field containing `value`.
  DiscordField[T](kind: FieldKind.Present, value: value)

func isAbsent*[T](field: DiscordField[T]): bool {.inline.} =
  ## Tests whether the property was omitted.
  field.kind == FieldKind.Absent

func isNull*[T](field: DiscordField[T]): bool {.inline.} =
  ## Tests whether the property was explicitly null.
  field.kind == FieldKind.NullValue

func isPresent*[T](field: DiscordField[T]): bool {.inline.} =
  ## Tests whether the property contains a typed value.
  field.kind == FieldKind.Present

proc get*[T](field: DiscordField[T]): T =
  ## Returns the present value or raises `ValueError`.
  if field.kind != FieldKind.Present:
    raise newException(ValueError, "Discord field has no value")
  field.value

func valueOr*[T](field: DiscordField[T]; fallback: sink T): T =
  ## Returns the present value, otherwise `fallback`.
  if field.kind == FieldKind.Present:
    field.value
  else:
    fallback

func leaveUnchanged*[T](): Patch[T] {.inline.} =
  ## Constructs a patch that omits the property.
  Patch[T](kind: PatchKind.LeaveUnchanged)

func clearValue*[T](): Patch[T] {.inline.} =
  ## Constructs a patch that sends JSON `null`.
  Patch[T](kind: PatchKind.ClearValue)

func setValue*[T](value: sink T): Patch[T] {.inline.} =
  ## Constructs a patch that sends `value`.
  Patch[T](kind: PatchKind.SetValue, value: value)

func isLeaveUnchanged*[T](patch: Patch[T]): bool {.inline.} =
  ## Tests whether the patch leaves the property untouched.
  patch.kind == PatchKind.LeaveUnchanged

func isClear*[T](patch: Patch[T]): bool {.inline.} =
  ## Tests whether the patch clears the property.
  patch.kind == PatchKind.ClearValue

func isSet*[T](patch: Patch[T]): bool {.inline.} =
  ## Tests whether the patch supplies a replacement value.
  patch.kind == PatchKind.SetValue

proc get*[T](patch: Patch[T]): T =
  ## Returns the value to set or raises `ValueError`.
  if patch.kind != PatchKind.SetValue:
    raise newException(ValueError, "Discord patch does not set a value")
  patch.value

func valueOr*[T](patch: Patch[T]; fallback: sink T): T =
  ## Returns the set value, otherwise `fallback`.
  if patch.kind == PatchKind.SetValue:
    patch.value
  else:
    fallback
