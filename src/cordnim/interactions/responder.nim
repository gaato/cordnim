## Atomic interaction response state and deadline policy.

import std/atomics

import cordnim/rest/request

type
  InteractionResponseState* = enum ## Atomic initial-response lifecycle.
    irFresh, ## No initial response has been claimed.
    irInitialPending, ## One task owns an uncommitted initial response.
    irDeferred, ## Discord accepted an initial deferred response.
    irResponded, ## Discord accepted a non-deferred initial response.
    irExpired, ## The initial response deadline elapsed while fresh.
    irTransportUnknown ## Sending failed after delivery became ambiguous.

  InteractionResponseError* = enum ## Non-exception response-state outcome.
    ireNone, ## Operation completed successfully.
    ireAlreadyAcknowledged, ## No fresh initial-response right remains.
    ireInitialDeadlineExpired, ## The acknowledgement deadline has elapsed.
    ireTokenExpired, ## The follow-up token lifetime has elapsed.
    ireClaimNotPending, ## The supplied claim no longer owns the state.
    irePolicyUnsupported ## Interaction type cannot use this ACK policy.

  InteractionType* = enum ## Interaction classes relevant to response rules.
    ikApplicationCommand, ## Slash, user, or message application command.
    ikMessageComponent, ## Button, select, or other component activation.
    ikAutocomplete, ## Focused command-option autocomplete request.
    ikCommandModalSubmit, ## Modal submitted after an application command.
    ikComponentModalSubmit, ## Modal submitted from a message component.
    ikPing ## Discord endpoint-verification ping.

  InitialResponseKind* = enum ## Semantic kind of an initial response.
    irkMessage, ## Send a channel message response.
    irkDeferredMessage, ## Acknowledge and edit or follow up later.
    irkUpdateMessage, ## Immediately update a component's message.
    irkDeferredUpdate, ## Acknowledge a component update for later editing.
    irkAutocomplete, ## Return autocomplete choices.
    irkModal, ## Present a modal form.
    irkPong ## Answer a Discord ping.

  Visibility* = enum ## Requested visibility of a message response.
    vPublic, ## Visible wherever Discord permits a public response.
    vEphemeral ## Visible only to the invoking user.

  AckPolicyKind* = enum ## Handler acknowledgement strategy.
    apkManual, ## Handler must issue the initial response itself.
    apkAutoDefer, ## Send a deferred message after a threshold.
    apkAutoDeferUpdate ## Send a deferred message update after a threshold.

  AckPolicy* = object ## Deadline-aware initial acknowledgement policy.
    kind*: AckPolicyKind ## Strategy selected by the command or handler.
    afterMs*: int64 ## Delay before automatic acknowledgement.
    visibility*: Visibility ## Visibility requested for a deferred message.

  InteractionDeadlines* = object ## Monotonic interaction lifecycle instants.
    receivedAt*: MonoMillis ## Instant when ingress accepted the interaction.
    ackDeadline*: MonoMillis ## Last instant for the initial response.
    tokenExpiresAt*: MonoMillis ## Last instant for token-backed operations.

  InteractionResponder* = ref object ## Shared atomic authority for exactly one
    ## initial interaction response.
    atomicState: Atomic[uint8]
    deadlines*: InteractionDeadlines ## Immutable lifecycle deadlines.

  InitialResponseClaim* = ref object ## Exclusive capability to commit one
    ## in-progress initial response.
    owner: InteractionResponder

  ClaimResult* = object ## Result of claiming the initial response.
    case ok*: bool ## Whether the claim succeeded; selects `claim` or `error`.
    of true:
      claim*: InitialResponseClaim ## Exclusive claim when `ok` is true.
    of false:
      error*: InteractionResponseError ## Failure when `ok` is false.

  StateResult* = object ## Result of committing or checking response state.
    ok*: bool ## Whether the requested state operation is permitted.
    error*: InteractionResponseError ## Failure reason, or `ireNone`.

func manualAck*(): AckPolicy =
  ## Creates a policy that never starts an automatic acknowledgement task.
  AckPolicy(kind: apkManual, visibility: vPublic)

func autoDefer*(afterMs = 2_000'i64,
                visibility = vEphemeral): AckPolicy =
  ## Creates a delayed deferred-message policy.
  AckPolicy(kind: apkAutoDefer, afterMs: afterMs, visibility: visibility)

func autoDeferUpdate*(afterMs = 2_000'i64): AckPolicy =
  ## Creates a delayed deferred-update policy for component-style interactions.
  AckPolicy(kind: apkAutoDeferUpdate, afterMs: afterMs, visibility: vPublic)

func allowedInitialKinds*(kind: InteractionType): set[InitialResponseKind] =
  ## Returns every initial response kind Discord permits for `kind`.
  case kind
  of ikApplicationCommand:
    {irkMessage, irkDeferredMessage, irkModal}
  of ikMessageComponent:
    {irkMessage, irkDeferredMessage, irkUpdateMessage, irkDeferredUpdate,
      irkModal}
  of ikAutocomplete:
    {irkAutocomplete}
  of ikCommandModalSubmit:
    {irkMessage, irkDeferredMessage}
  of ikComponentModalSubmit:
    {irkMessage, irkDeferredMessage, irkUpdateMessage, irkDeferredUpdate}
  of ikPing:
    {irkPong}

func validatePolicy*(kind: InteractionType,
                     policy: AckPolicy): InteractionResponseError =
  ## Validates policy timing and response kind against an interaction class.
  case policy.kind
  of apkManual:
    ireNone
  of apkAutoDefer:
    if irkDeferredMessage in kind.allowedInitialKinds and policy.afterMs >= 0:
      ireNone
    else:
      irePolicyUnsupported
  of apkAutoDeferUpdate:
    if irkDeferredUpdate in kind.allowedInitialKinds and policy.afterMs >= 0:
      ireNone
    else:
      irePolicyUnsupported

proc newInteractionResponder*(receivedAt: MonoMillis,
                              ackWindowMs = 3_000'i64,
                              tokenLifetimeMs = 15 * 60 * 1_000'i64):
                              InteractionResponder =
  ## Creates fresh atomic response authority with monotonic deadlines.
  new result
  result.atomicState.store(uint8(ord(irFresh)))
  result.deadlines = InteractionDeadlines(
    receivedAt: receivedAt,
    ackDeadline: receivedAt + ackWindowMs,
    tokenExpiresAt: receivedAt + tokenLifetimeMs
  )

proc state*(responder: InteractionResponder): InteractionResponseState =
  ## Loads the current response state atomically.
  InteractionResponseState(responder.atomicState.load())

func remainingAckMs*(responder: InteractionResponder,
                     now: MonoMillis): int64 =
  ## Returns non-negative milliseconds left for an initial response.
  max(0'i64, responder.deadlines.ackDeadline - now)

func remainingTokenMs*(responder: InteractionResponder,
                       now: MonoMillis): int64 =
  ## Returns non-negative milliseconds left for token-backed operations.
  max(0'i64, responder.deadlines.tokenExpiresAt - now)

proc expireFresh(responder: InteractionResponder) =
  var expected = uint8(ord(irFresh))
  # A lost CAS means another task already claimed or completed the response.
  # Expiry must never overwrite that newer authority.
  discard responder.atomicState.compareExchange(
    expected, uint8(ord(irExpired)), moAcquireRelease, moAcquire)

proc beginInitial*(responder: InteractionResponder,
                   now: MonoMillis): ClaimResult =
  ## Atomically consumes fresh state and returns exclusive response authority.
  if now >= responder.deadlines.ackDeadline:
    responder.expireFresh()
    return ClaimResult(ok: false, error: ireInitialDeadlineExpired)

  # Claims can cross async boundaries and aliases can survive a move. The
  # atomic state remains the final authority even when static ownership helps.
  var expected = uint8(ord(irFresh))
  if responder.atomicState.compareExchange(
      expected, uint8(ord(irInitialPending)), moAcquireRelease, moAcquire):
    return ClaimResult(ok: true, claim: InitialResponseClaim(owner: responder))
  ClaimResult(ok: false, error: ireAlreadyAcknowledged)

proc finish(claim: InitialResponseClaim,
            desired: InteractionResponseState): StateResult =
  if claim.isNil or claim.owner.isNil:
    return StateResult(ok: false, error: ireClaimNotPending)
  # Only a claim that still observes `pending` may publish a terminal state;
  # stale aliases and duplicate commits must leave that state untouched.
  var expected = uint8(ord(irInitialPending))
  if claim.owner.atomicState.compareExchange(
      expected, uint8(ord(desired)), moAcquireRelease, moAcquire):
    return StateResult(ok: true, error: ireNone)
  StateResult(ok: false, error: ireClaimNotPending)

proc commit*(claim: InitialResponseClaim,
             responseKind: InitialResponseKind): StateResult =
  ## Commits a pending claim as deferred or fully responded.
  case responseKind
  of irkDeferredMessage, irkDeferredUpdate:
    claim.finish(irDeferred)
  else:
    claim.finish(irResponded)

proc markTransportUnknown*(claim: InitialResponseClaim): StateResult =
  ## A transport error after bytes may have left the process is ambiguous. The
  ## caller must not blindly issue a second initial response.
  claim.finish(irTransportUnknown)

proc canFollowup*(responder: InteractionResponder,
                  now: MonoMillis): StateResult =
  ## Checks both token lifetime and whether an initial response was committed.
  if now >= responder.deadlines.tokenExpiresAt:
    return StateResult(ok: false, error: ireTokenExpired)
  if responder.state in {irDeferred, irResponded}:
    StateResult(ok: true, error: ireNone)
  else:
    StateResult(ok: false, error: ireAlreadyAcknowledged)

proc forceExpireForTest*(responder: InteractionResponder) =
  ## Deliberately exported from this alpha for deterministic test drivers. It is
  ## not used by production ingress.
  responder.atomicState.store(uint8(ord(irExpired)), moRelease)
