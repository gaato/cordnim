## Shared semantic request-field states.
##
## Discord PATCH bodies distinguish an omitted key from an explicit JSON
## `null`. `FieldEdit` preserves that distinction without exposing a mutable
## JSON document to callers. Its zero value omits the field.

type
  FieldEditKind = enum
    feOmit,
    feClear,
    feSet

  FieldEdit*[T] = object ## Omit, clear, or set one Discord request field.
    case kind: FieldEditKind
    of feSet:
      value: T
    else:
      discard

func editSet*[T](value: T): FieldEdit[T] =
  ## Sends a concrete value.
  FieldEdit[T](kind: feSet, value: value)

func editClear*(T: typedesc): FieldEdit[T] =
  ## Sends an explicit JSON `null`.
  FieldEdit[T](kind: feClear)

func editOmit*(T: typedesc): FieldEdit[T] =
  ## Leaves the field out of the request body.
  FieldEdit[T](kind: feOmit)

func isOmit*[T](edit: FieldEdit[T]): bool = edit.kind == feOmit
  ## Reports whether the field is omitted.

func isClear*[T](edit: FieldEdit[T]): bool = edit.kind == feClear
  ## Reports whether the field is sent as JSON `null`.

func isSet*[T](edit: FieldEdit[T]): bool = edit.kind == feSet
  ## Reports whether the field carries a concrete value.

func editValue*[T](edit: FieldEdit[T]): T =
  ## Returns the concrete value, raising when the edit is omit or clear.
  if edit.kind != feSet:
    raise newException(ValueError, "field edit carries no value")
  edit.value
