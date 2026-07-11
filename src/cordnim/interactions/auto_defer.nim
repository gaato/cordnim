## Deadline-aware automatic acknowledgement using Chronos.

import chronos

import cordnim/rest/chronos_driver
import ./responder

type
  InitialAckSender* = proc(kind: InitialResponseKind,
                           visibility: Visibility): Future[void]
    {.gcsafe, raises: [].} ## Transport callback for one initial response.

proc autoDeferTask*(responder: InteractionResponder,
                    interactionType: InteractionType,
                    policy: AckPolicy,
                    sender: InitialAckSender): Future[void] {.
                    async: (raises: [CancelledError, ValueError]).} =
  ## Waits for the declared threshold, then atomically claims and defers.
  ##
  ## If the handler responds first, the claim loses harmlessly. A failure after
  ## claiming is marked transport-unknown so no second initial response is sent.
  if interactionType.validatePolicy(policy) != ireNone:
    raise newException(ValueError,
      "acknowledgement policy is invalid for interaction type")
  if policy.kind == apkManual:
    return
  if sender.isNil:
    raise newException(ValueError, "auto-defer sender must not be nil")

  await sleepAsync(policy.afterMs.milliseconds)
  let claim = responder.beginInitial(monotonicMillis())
  if not claim.ok:
    return
  let responseKind = if policy.kind == apkAutoDeferUpdate:
    irkDeferredUpdate
  else:
    irkDeferredMessage
  try:
    await sender(responseKind, policy.visibility)
    discard claim.claim.commit(responseKind)
  except CancelledError:
    discard claim.claim.markTransportUnknown()
    raise
  except CatchableError:
    discard claim.claim.markTransportUnknown()
