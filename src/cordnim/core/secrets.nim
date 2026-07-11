## Secret values with redacted display and JSON representations.

import std/json

const redactedSecret* = "[REDACTED]" ## Stable replacement used by safe renderers.

type
  BotToken* = object ## Type marker for a Discord bot authorization token.
  InteractionToken* = object ## Type marker for a short-lived interaction token.
  WebhookToken* = object ## Type marker for a webhook credential.

  Secret*[Kind] = object ## A string whose display and JSON forms are redacted.
    value: string

func initSecret*[Kind](value: sink string): Secret[Kind] {.inline.} =
  ## Wraps a credential at an input boundary without copying when possible.
  Secret[Kind](value: value)

func reveal*[Kind](secret: Secret[Kind]): string {.inline.} =
  ## Explicitly copies the underlying secret for a protocol boundary.
  secret.value

func len*[Kind](secret: Secret[Kind]): int {.inline.} =
  ## Returns the credential length without revealing its contents.
  secret.value.len

func isEmpty*[Kind](secret: Secret[Kind]): bool {.inline.} =
  ## Tests whether the wrapped credential is empty.
  secret.value.len == 0

func `==`*[Kind](left, right: Secret[Kind]): bool {.inline.} =
  ## Compares secrets only when their credential kinds match.
  left.value == right.value

func `$`*[Kind](secret: Secret[Kind]): string =
  ## Always returns `redactedSecret`.
  discard secret
  redactedSecret

func repr*[Kind](secret: Secret[Kind]): string =
  ## Redacts the representation used by generic debugging helpers.
  discard secret
  redactedSecret

proc `%`*[Kind](secret: Secret[Kind]): JsonNode =
  ## Serializes a redacted placeholder instead of credential bytes.
  discard secret
  newJString(redactedSecret)

proc toJsonHook*[Kind](secret: Secret[Kind]): JsonNode =
  ## Redacts secrets serialized through `std/jsonutils`.
  %secret
