## Move-only typed capabilities for the first interaction response.
##
## The capability layer prevents ordinary code from acknowledging one fresh
## interaction twice. It deliberately separates claim, transport I/O, and
## commit so the network `await` remains visible. The atomic responder remains
## authoritative when aliases or asynchronous failure escape static checking.

import std/json

import cordnim/rest/request
import ./responder

type
  Fresh* = object ## Marker for an unused initial response right.
  Deferred* = object ## Marker for a committed deferred response.
  Responded* = object ## Marker for a committed immediate response.
  TransportUnknown* = object ## Marker for ambiguous transport delivery.

  Interaction*[State] = object ## Move-only view of one interaction response
    ## lifecycle state.
    responder: InteractionResponder
    interactionType: InteractionType

  PendingInitial*[Next] = object ## Move-only claim held while caller-owned
    ## transport I/O is in progress.
    responder: InteractionResponder
    claim: InitialResponseClaim
    responseKind: InitialResponseKind

  BeginInitialResult*[Next] = object ## Result of atomically claiming a typed
    ## first-response transition.
    case ok*: bool ## Whether the claim succeeded; selects `pending` or `error`.
    of true:
      pending*: PendingInitial[Next] ## Exclusive pending transport capability.
    of false:
      error*: InteractionResponseError ## Runtime rejection reason.

proc `=copy`*[State](destination: var Interaction[State],
                     source: Interaction[State]) {.error:
    "interaction response capabilities are move-only".} ## Rejects copying an
    ## interaction response right at compile time.

proc `=copy`*[Next](destination: var PendingInitial[Next],
                    source: PendingInitial[Next]) {.error:
    "pending interaction response capabilities are move-only".} ## Rejects
    ## copying a claimed initial response while transport I/O is pending.

func `$`*[State](interaction: Interaction[State]): string =
  ## Metadata-only rendering; never traverses the responder claim or state.
  "Interaction(type: " & $interaction.interactionType & ")"

func repr*[State](interaction: Interaction[State]): string =
  ## Safe debug rendering that never reaches the atomic responder authority.
  $interaction

proc `%`*[State](interaction: Interaction[State]): JsonNode =
  ## Serializes only the safe interaction-type metadata.
  %*{"interactionType": $interaction.interactionType}

proc toJsonHook*[State](interaction: Interaction[State]): JsonNode =
  ## Redacts move-only capabilities serialized through `std/jsonutils`.
  %interaction

func `$`*[Next](pending: PendingInitial[Next]): string =
  ## Metadata-only rendering of a pending claim; never traverses the claim.
  "PendingInitial(kind: " & $pending.responseKind & ")"

func repr*[Next](pending: PendingInitial[Next]): string =
  ## Safe debug rendering that never reaches the pending response claim.
  $pending

proc `%`*[Next](pending: PendingInitial[Next]): JsonNode =
  ## Serializes safe response-kind metadata only.
  %*{"responseKind": $pending.responseKind}

proc toJsonHook*[Next](pending: PendingInitial[Next]): JsonNode =
  ## Redacts pending claims serialized through std/jsonutils.
  %pending

func `$`*[Next](begun: BeginInitialResult[Next]): string =
  ## Safe transition outcome without traversing a pending claim.
  if begun.ok: "BeginInitialResult(ok: true)"
  else: "BeginInitialResult(ok: false, error: " & $begun.error & ")"

func repr*[Next](begun: BeginInitialResult[Next]): string =
  $begun

proc `%`*[Next](begun: BeginInitialResult[Next]): JsonNode =
  result = %*{"ok": begun.ok}
  if not begun.ok:
    result["error"] = %($begun.error)

proc toJsonHook*[Next](begun: BeginInitialResult[Next]): JsonNode =
  %begun

proc freshInteraction*(interactionType: InteractionType,
                       receivedAt: MonoMillis): Interaction[Fresh] =
  ## Creates a fresh typed capability backed by an atomic responder.
  Interaction[Fresh](
    responder: newInteractionResponder(receivedAt),
    interactionType: interactionType
  )

func deadlines*[State](interaction: Interaction[State]):
    InteractionDeadlines =
  ## Returns the immutable ACK and token deadlines.
  interaction.responder.deadlines

proc beginTransition[Next](interaction: sink Interaction[Fresh],
                           responseKind: InitialResponseKind,
                           now: MonoMillis): BeginInitialResult[Next] =
  # The runtime claim remains authoritative even if compiler-visible ownership
  # is obscured by an alias or closure boundary.
  if responseKind notin interaction.interactionType.allowedInitialKinds:
    return BeginInitialResult[Next](ok: false, error: irePolicyUnsupported)
  let claimed = interaction.responder.beginInitial(now)
  if not claimed.ok:
    return BeginInitialResult[Next](ok: false, error: claimed.error)
  BeginInitialResult[Next](
    ok: true,
    pending: PendingInitial[Next](
      responder: interaction.responder,
      claim: claimed.claim,
      responseKind: responseKind
    )
  )

proc beginReply*(interaction: sink Interaction[Fresh],
                 now: MonoMillis): BeginInitialResult[Responded] =
  ## Claims an immediate message response before caller-owned transport I/O.
  beginTransition[Responded](interaction, irkMessage, now)

proc beginDefer*(interaction: sink Interaction[Fresh], now: MonoMillis,
                 update = false): BeginInitialResult[Deferred] =
  ## Claims a deferred message or component-update response.
  beginTransition[Deferred](interaction,
    if update: irkDeferredUpdate else: irkDeferredMessage, now)

proc beginDeferredUpdate*(interaction: sink Interaction[Fresh],
                          now: MonoMillis): BeginInitialResult[Deferred] =
  ## Claims an update-style deferred response without a boolean mode flag.
  beginTransition[Deferred](interaction, irkDeferredUpdate, now)

proc beginUpdate*(interaction: sink Interaction[Fresh],
                  now: MonoMillis): BeginInitialResult[Responded] =
  ## Claims an immediate source-message update response.
  beginTransition[Responded](interaction, irkUpdateMessage, now)

proc beginAutocomplete*(interaction: sink Interaction[Fresh],
                        now: MonoMillis): BeginInitialResult[Responded] =
  ## Claims an autocomplete choices response.
  beginTransition[Responded](interaction, irkAutocomplete, now)

proc beginModal*(interaction: sink Interaction[Fresh],
                 now: MonoMillis): BeginInitialResult[Responded] =
  ## Claims a modal response for an interaction type that permits one.
  beginTransition[Responded](interaction, irkModal, now)

proc commit*[Next](pending: sink PendingInitial[Next]): Interaction[Next] =
  ## Commits after transport success and returns the next typed state.
  let committed = pending.claim.commit(pending.responseKind)
  if not committed.ok:
    raise newException(ValueError,
      "pending interaction claim is no longer authoritative")
  Interaction[Next](responder: pending.responder)

proc markTransportUnknown*[Next](pending: sink PendingInitial[Next]):
    Interaction[TransportUnknown] =
  ## Seals a claim after ambiguous transport failure; retrying is unsafe.
  let marked = pending.claim.markTransportUnknown()
  if not marked.ok:
    raise newException(ValueError,
      "pending interaction claim is no longer authoritative")
  Interaction[TransportUnknown](responder: pending.responder)

proc canFollowup*[State: Deferred | Responded](
                  interaction: Interaction[State],
                  now: MonoMillis): StateResult =
  ## Checks token lifetime for a state that has a committed acknowledgement.
  interaction.responder.canFollowup(now)
