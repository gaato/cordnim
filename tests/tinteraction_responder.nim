import std/[strutils, unittest]

import cordnim/interactions
import cordnim/rest/request

suite "interaction responder":
  test "only one initial response claim wins":
    let responder = newInteractionResponder(MonoMillis(1_000))
    let first = responder.beginInitial(MonoMillis(1_100))
    let second = responder.beginInitial(MonoMillis(1_100))
    check first.ok
    check not second.ok
    check second.error == ireAlreadyAcknowledged
    check first.claim.commit(irkDeferredMessage).ok
    check responder.state == irDeferred

  test "deadline expiration is explicit":
    let responder = newInteractionResponder(MonoMillis(1_000))
    let claim = responder.beginInitial(MonoMillis(4_000))
    check not claim.ok
    check claim.error == ireInitialDeadlineExpired
    check responder.state == irExpired

  test "ambiguous transport failure prevents a second response":
    let responder = newInteractionResponder(MonoMillis(0))
    let claim = responder.beginInitial(MonoMillis(1))
    check claim.claim.markTransportUnknown().ok
    check responder.state == irTransportUnknown
    check not responder.beginInitial(MonoMillis(2)).ok

  test "autocomplete cannot auto-defer":
    check validatePolicy(ikAutocomplete, autoDefer()) == irePolicyUnsupported
    check validatePolicy(ikMessageComponent, autoDeferUpdate()) == ireNone

suite "HTTP interaction verification":
  proc acceptingVerifier(publicKey, signature, message: openArray[byte]): bool
      {.gcsafe, raises: [].} =
    publicKey.len == 32 and signature.len == 64 and message.len > 0

  test "valid signatures enter the replay cache exactly once":
    var cache = initReplayCache()
    let config = VerificationConfig(
      allowedSkewSeconds: 300,
      maxBodyBytes: 1_024,
      verifier: acceptingVerifier
    )
    let signature = repeat('a', 128)
    let body = @[byte 1, byte 2]
    check config.verifyInteractionRequest(
      cache, signature, "1000", body, 1000).kind == ivValid
    check config.verifyInteractionRequest(
      cache, signature, "1000", body, 1000).kind == ivReplay
    check config.verifyInteractionRequest(
      cache, signature.toUpperAscii(), "1000", body, 1000).kind == ivReplay

  test "stale requests and missing verifier fail closed":
    var cache = initReplayCache()
    var config = VerificationConfig(
      allowedSkewSeconds: 10,
      maxBodyBytes: 1_024,
      verifier: acceptingVerifier
    )
    check config.verifyInteractionRequest(
      cache, repeat('b', 128), "1", @[], 100).kind ==
        ivTimestampOutsideWindow
    config.verifier = nil
    check config.verifyInteractionRequest(
      cache, repeat('b', 128), "100", @[], 100).kind ==
        ivVerifierUnavailable

  test "extreme signed timestamps cannot overflow skew validation":
    var cache = initReplayCache()
    let config = VerificationConfig(
      allowedSkewSeconds: 300,
      maxBodyBytes: 1_024,
      verifier: acceptingVerifier
    )
    let signature = repeat('c', 128)
    check config.verifyInteractionRequest(
      cache, signature, $low(int64), @[], 0).kind ==
      ivTimestampOutsideWindow
    check config.verifyInteractionRequest(
      cache, signature, $high(int64), @[], 0).kind ==
      ivTimestampOutsideWindow
    check config.verifyInteractionRequest(
      cache, signature, "0", @[], low(int64)).kind ==
      ivTimestampOutsideWindow
    check config.verifyInteractionRequest(
      cache, signature, "0", @[], high(int64)).kind ==
      ivTimestampOutsideWindow
