## Validated state transitions for Discord's DAVE end-to-end encryption.

import std/options

type
  DaveProtocolVersion* = distinct uint16 ## Negotiated DAVE wire protocol version.

  DaveSessionPhase* = enum ## Lifecycle phase of DAVE state negotiation.
    daveDisabled,         ## End-to-end encryption is disabled by version zero.
    daveAwaitingExternalSender, ## Session needs the MLS external sender package.
    daveActive,           ## A non-zero DAVE version is active.
    davePreparingTransition, ## A downgrade or epoch transition is being prepared.
    daveTransitionReady,  ## The pending transition is ready to execute.
    daveFailed            ## Session has recorded a DAVE failure.

  DaveTransitionKind* = enum ## Kind of pending DAVE transition.
    daveDowngrade,        ## Transition to unencrypted version zero.
    daveEpochChange       ## Activate a new MLS epoch and protocol version.

  DavePendingTransition* = object ## Validated transition awaiting readiness or execution.
    id*: uint16 ## Voice Gateway transition identifier.
    kind*: DaveTransitionKind ## Operation represented by this transition.
    targetVersion*: DaveProtocolVersion ## Version active after execution.
    epoch*: uint64 ## MLS epoch for an epoch change, or zero for a downgrade.

  DaveSessionState* = object ## Negotiated DAVE version and pending transition state.
    phase*: DaveSessionPhase ## Current lifecycle phase.
    maxSupportedVersion*: DaveProtocolVersion ## Highest locally supported version.
    activeVersion*: DaveProtocolVersion ## Current version, with zero meaning disabled.
    externalSenderReady*: bool ## Whether the MLS external sender is installed.
    pending*: Option[DavePendingTransition] ## Transition awaiting readiness or execution.
    failureReason*: string ## Diagnostic reason recorded after failure.

func `==`*(a, b: DaveProtocolVersion): bool {.borrow.}
  ## Compares DAVE versions by their numeric wire value.
func `<`*(a, b: DaveProtocolVersion): bool {.borrow.}
  ## Orders DAVE versions by their numeric wire value.
func `<=`*(a, b: DaveProtocolVersion): bool {.borrow.}
  ## Orders DAVE versions by their numeric wire value, including equality.
func toUint16*(version: DaveProtocolVersion): uint16 {.inline, raises: [].} =
  ## Returns the version's numeric wire value.
  uint16(version)

proc initDaveSession*(maxSupportedVersion: DaveProtocolVersion): DaveSessionState =
  ## Creates a session waiting for its MLS external sender package.
  ##
  ## Raises `ValueError` when `maxSupportedVersion` is zero.
  if maxSupportedVersion.toUint16 == 0:
    raise newException(ValueError, "DAVE support requires a non-zero protocol version")
  DaveSessionState(
    phase: daveAwaitingExternalSender,
    maxSupportedVersion: maxSupportedVersion,
  )

proc recordExternalSender*(state: var DaveSessionState; data: openArray[byte]) =
  ## Records installation of a non-empty MLS external sender package.
  ##
  ## Raises `ValueError` when `data` is empty.
  if data.len == 0:
    raise newException(ValueError, "MLS external sender package must not be empty")
  state.externalSenderReady = true
  # The sender package alone cannot activate DAVE before a version is negotiated.
  if state.activeVersion.toUint16 > 0:
    state.phase = daveActive

proc prepareDowngrade*(state: var DaveSessionState; transitionId: uint16) =
  ## Prepares `transitionId` to disable DAVE through protocol version zero.
  ##
  ## Raises `ValueError` while another transition is pending.
  if state.pending.isSome:
    raise newException(ValueError, "a DAVE transition is already pending")
  state.pending = some(DavePendingTransition(
    id: transitionId,
    kind: daveDowngrade,
    targetVersion: DaveProtocolVersion(0),
  ))
  state.phase = davePreparingTransition

proc prepareEpoch*(
    state: var DaveSessionState;
    transitionId: uint16;
    epoch: uint64;
    targetVersion: DaveProtocolVersion,
) =
  ## Validates and prepares a transition to an MLS `epoch` and DAVE version.
  ##
  ## Raises `ValueError` when prerequisites are missing, another transition is
  ## pending, the epoch is zero, or the target version is unsupported.
  if not state.externalSenderReady:
    raise newException(ValueError, "MLS external sender must be installed before preparing an epoch")
  if state.pending.isSome:
    raise newException(ValueError, "a DAVE transition is already pending")
  if epoch == 0:
    raise newException(ValueError, "MLS epoch must be greater than zero")
  if targetVersion.toUint16 == 0 or targetVersion > state.maxSupportedVersion:
    raise newException(ValueError, "DAVE target version is not supported")

  state.pending = some(DavePendingTransition(
    id: transitionId,
    kind: daveEpochChange,
    targetVersion: targetVersion,
    epoch: epoch,
  ))
  state.phase = davePreparingTransition

proc markTransitionReady*(state: var DaveSessionState; transitionId: uint16): bool {.raises: [].} =
  ## Marks the matching prepared transition ready and reports whether it matched.
  if state.phase != davePreparingTransition or state.pending.isNone or
      state.pending.get.id != transitionId:
    return false
  state.phase = daveTransitionReady
  true

proc executeTransition*(state: var DaveSessionState; transitionId: uint16): bool {.raises: [].} =
  ## Executes the matching ready transition and reports whether it matched.
  if state.phase != daveTransitionReady or state.pending.isNone:
    return false
  let transition = state.pending.get
  if transition.id != transitionId:
    return false

  state.activeVersion = transition.targetVersion
  state.pending = none(DavePendingTransition)
  # Protocol version zero is the wire-level sentinel for a completed downgrade.
  if state.activeVersion.toUint16 == 0:
    state.phase = daveDisabled
  else:
    state.phase = daveActive
  true

proc fail*(state: var DaveSessionState; reason: sink string) {.raises: [].} =
  ## Records a failure and discards any pending transition.
  state.failureReason = reason
  state.pending = none(DavePendingTransition)
  state.phase = daveFailed
