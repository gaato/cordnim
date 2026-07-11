import std/assertions

import cordnim/voice/dave/state
import cordnim/voice/libdave/raw

block libdave_binding_metadata:
  doAssert libdaveApiRevision == "v1.1.1/cpp"
  doAssert libdaveHeaderSha256.len == 64
  doAssert not libdaveBindingsEnabled
  doAssert sizeof(DAVEEncryptorStats) == 7 * sizeof(uint64)
  doAssert sizeof(DAVEDecryptorStats) == 7 * sizeof(uint64)

block epoch_transition:
  var state = initDaveSession(DaveProtocolVersion(1))
  doAssert state.phase == daveAwaitingExternalSender
  state.recordExternalSender([1'u8, 2, 3])
  state.prepareEpoch(7, 1, DaveProtocolVersion(1))
  doAssert state.phase == davePreparingTransition
  doAssert not state.markTransitionReady(8)
  doAssert state.markTransitionReady(7)
  doAssert not state.executeTransition(8)
  doAssert state.executeTransition(7)
  doAssert state.phase == daveActive
  doAssert state.activeVersion.toUint16 == 1

block downgrade_transition:
  var state = initDaveSession(DaveProtocolVersion(1))
  state.recordExternalSender([1'u8])
  state.prepareEpoch(1, 1, DaveProtocolVersion(1))
  doAssert state.markTransitionReady(1)
  doAssert state.executeTransition(1)
  state.prepareDowngrade(2)
  doAssert state.markTransitionReady(2)
  doAssert state.executeTransition(2)
  doAssert state.phase == daveDisabled
  doAssert state.activeVersion.toUint16 == 0

block invalid_epoch_is_rejected:
  var state = initDaveSession(DaveProtocolVersion(1))
  doAssertRaises ValueError:
    state.prepareEpoch(1, 1, DaveProtocolVersion(1))
  state.recordExternalSender([1'u8])
  doAssertRaises ValueError:
    state.prepareEpoch(1, 0, DaveProtocolVersion(1))
  doAssertRaises ValueError:
    state.prepareEpoch(1, 1, DaveProtocolVersion(2))
