import std/[assertions, json, options, strutils]

import chronos

import cordnim/core/errors as cordErrors
import cordnim/gateway/[close_policy, payloads, transport]
import cordnim/rest
import cordnim/testing

func bytesText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

func textBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for index, value in text:
    result[index] = byte(value)

# --- Manual clock -----------------------------------------------------------

block manual_clock_is_a_fake_clock_alias:
  var clock = initManualClock(1_000)
  clock.advance(250)
  doAssert clock.nowMs == 1_250
  doAssert clock.nowMillis == 1_250
  var legacy: FakeClock = clock
  legacy.advance(0)
  doAssert legacy.nowMs == 1_250
  doAssertRaises ValueError:
    clock.advance(-1)

block manual_clock_rejects_invalid_instants:
  doAssertRaises ValueError:
    discard initManualClock(-1)
  var clock = initManualClock(high(int64))
  doAssertRaises ValueError:
    clock.advance(1)
  doAssert clock.nowMs == high(int64)

# --- Fixed entropy ----------------------------------------------------------

block fixed_entropy_tracks_remaining_and_exhaustion:
  var entropy = initFixedEntropy(@[0xDE'u8, 0xAD, 0xBE, 0xEF])
  doAssert entropy.remaining == 4
  doAssert entropy.nextByte() == 0xDE'u8
  doAssert entropy.consumed == 1
  doAssert entropy.nextHex(2) == "adbe"
  entropy.assertRemaining(1)
  doAssert entropy.nextBytes(1) == @[0xEF'u8]
  entropy.assertExhausted()
  doAssert entropy.isExhausted

block fixed_entropy_rejects_short_reads_without_consuming:
  var entropy = fixedEntropyFromString("ab")
  doAssertRaises EntropyExhaustedError:
    discard entropy.nextBytes(3)
  # A failed request must not advance the cursor.
  doAssert entropy.remaining == 2
  doAssert entropy.nextBytes(2) == @[byte('a'), byte('b')]
  doAssertRaises EntropyExhaustedError:
    discard entropy.nextByte()

block fixed_entropy_is_a_value_type:
  var original = initFixedEntropy(@[1'u8, 2, 3])
  var copy = original
  discard copy.nextByte()
  doAssert copy.remaining == 2
  doAssert original.remaining == 3 # Copies own independent cursors.

# --- Canonical JSON ---------------------------------------------------------

block canonical_json_ignores_object_key_order:
  doAssert jsonEquiv(%*{"a": 1, "b": {"c": 2, "d": 3}},
    %*{"b": {"d": 3, "c": 2}, "a": 1})
  doAssert canonicalText(%*{"b": 1, "a": 2}) == """{"a":2,"b":1}"""

block canonical_json_reports_the_mismatch_path:
  let mismatch = jsonMismatch(
    %*{"data": {"options": [{"value": "x"}]}},
    %*{"data": {"options": [{"value": "y"}]}})
  doAssert mismatch == "$.data.options[0].value: expected \"x\", got \"y\""
  doAssert jsonMismatchPath(
    %*{"token": "expected-secret"}, %*{"token": "actual-secret"}) == "$.token"
  doAssertRaises AssertionDefect:
    assertJsonEquiv(%*{"n": 1}, %*{"n": 2})
  # Arrays remain order-sensitive.
  doAssert not jsonEquiv(%*[1, 2], %*[2, 1])

# --- Redaction --------------------------------------------------------------

block redaction_strips_headers_urls_and_json:
  let config = defaultRedaction()
  doAssert config.redactHeaderValue("Authorization", "Bot abc") == redactedSecret
  doAssert config.redactHeaderValue("Accept", "application/json") ==
    "application/json"
  # Interaction/webhook tokens live two segments after the collection marker.
  doAssert config.redactUrl("/webhooks/123/supersecret/messages/@original") ==
    "/webhooks/123/" & redactedSecret & "/messages/@original"
  doAssert config.redactUrl("/interactions/9/tok/callback") ==
    "/interactions/9/" & redactedSecret & "/callback"
  doAssert config.redactUrl("/oauth2/token?token=leak&scope=bot") ==
    "/oauth2/token?token=" & redactedSecret & "&scope=bot"
  let redacted = config.redactJson(%*{
    "token": "leak", "nested": {"password": "hunter2", "keep": 1}})
  doAssert redacted["token"].getStr() == redactedSecret
  doAssert redacted["nested"]["password"].getStr() == redactedSecret
  doAssert redacted["nested"]["keep"].getInt() == 1

block redaction_extends_with_custom_keys:
  let original = defaultRedaction()
  let config = original.withRedactedKeys(
    jsonKeys = ["api_key"],
    pathMarkers = ["callbacks"])
  doAssert config.redactJson(%*{"api_key": "x"})["api_key"].getStr() ==
    redactedSecret
  doAssert original.redactJson(%*{"api_key": "x"})["api_key"].getStr() == "x"
  let extended = config.withRedactedKeys(jsonKeys = ["private_key"])
  doAssert extended.redactJson(%*{"private_key": "x"})[
    "private_key"].getStr() == redactedSecret
  doAssert config.redactJson(%*{"private_key": "x"})[
    "private_key"].getStr() == "x"

block redaction_rejects_opaque_text_and_encoded_url_credentials:
  let config = defaultRedaction()
  doAssert config.redactJsonText("opaque secret-token bytes") == redactedSecret
  let encoded = config.redactUrl(
    "https://user:password@example.test/%77ebhooks/1/secret" &
      "?%74oken=query-secret#fragment-secret")
  for secret in ["user", "password", "secret", "query-secret",
      "fragment-secret"]:
    doAssert secret notin encoded
  doAssert redactedSecret in encoded

block recorder_redaction_defaults_cannot_be_disabled_by_an_empty_config:
  let config = RedactionConfig().hardenedRedaction()
  doAssert config.redactJson(%*{"token": "secret"})["token"].getStr() ==
    redactedSecret
  doAssert config.redactHeaderValue("Authorization", "Bot secret") ==
    redactedSecret

block explicitly_registered_secrets_are_scrubbed_under_arbitrary_keys:
  let config = defaultRedaction().withSecretValues([
    "application-secret", "resume-secret"])
  let document = config.redactJson(%*{
    "content": "prefix application-secret suffix",
    "session_id": "gateway-session",
    "nested": {"message": "resume-secret"},
  })
  doAssert "application-secret" notin $document
  doAssert "gateway-session" notin $document
  doAssert "resume-secret" notin $document
  doAssert document["content"].getStr() ==
    "prefix " & redactedSecret & " suffix"

block registered_secrets_are_not_public_or_rendered_and_scrub_names:
  const literal = "registered-literal-secret"
  let config = defaultRedaction().withSecretValues([literal])
  static:
    doAssert not compiles(config.secretValues)
  doAssert literal notin repr(config)
  doAssert literal notin $config
  doAssert literal notin repr(initCassette(config))

  var keyed = newJObject()
  keyed[literal] = %"safe-value"
  let safeJson = config.redactJson(keyed)
  doAssert literal notin $safeJson
  doAssert safeJson.hasKey(redactedSecret)
  let safeHeaders = config.redactHeaders([(literal, "safe-value")])
  doAssert safeHeaders[0][0] == redactedSecret

# --- Fixtures ---------------------------------------------------------------

block fixtures_build_valid_representative_payloads:
  let slash = slashCommandInteraction(name = "ping")
  doAssert slash["type"].getInt() == 2
  doAssert slash["data"]["name"].getStr() == "ping"
  let component = componentInteraction(customId = "confirm")
  doAssert component["type"].getInt() == 3
  doAssert component["data"]["custom_id"].getStr() == "confirm"
  let modal = modalSubmitInteraction(value = "nice")
  doAssert modal["type"].getInt() == 5
  doAssert modal["data"]["components"][0]["components"][0]["value"].getStr() ==
    "nice"

block gateway_fixtures_decode_as_valid_dispatch_envelopes:
  for envelope in [readyDispatch(), messageCreateDispatch(),
      guildCreateDispatch(), unknownDispatch()]:
    let decoded = decodeGatewayDispatch(envelope.copy())
    doAssert decoded.eventName.toString().len > 0
    doAssert not decoded.data.isNil
  doAssert unknownDispatch()["t"].getStr() == "CORDNIM_FUTURE_EVENT"

block fixtures_apply_targeted_overrides_without_sharing_state:
  let overridden = slashCommandInteraction(overrides = %*{
    "data": {"name": "renamed"}})
  doAssert overridden["data"]["name"].getStr() == "renamed"
  # The override must not leak the "type" field or drop siblings.
  doAssert overridden["data"]["type"].getInt() == 1
  # Mutating one result must not affect a freshly built payload.
  var first = slashCommandInteraction()
  first["data"]["name"] = %"mutated"
  doAssert slashCommandInteraction()["data"]["name"].getStr() == "ping"

block merge_json_does_not_mutate_its_base:
  let base = %*{"a": {"x": 1}}
  let merged = mergeJson(base, %*{"a": {"y": 2}})
  doAssert merged["a"]["x"].getInt() == 1
  doAssert merged["a"]["y"].getInt() == 2
  doAssert not base["a"].hasKey("y") # Base is untouched.

block fixture_inputs_are_deep_copied:
  var options = %*[{"name": "target", "type": 3, "value": "before"}]
  let interaction = slashCommandInteraction(options = options)
  options[0]["value"] = %"after"
  doAssert interaction["data"]["options"][0]["value"].getStr() == "before"

  var data = %*{"nested": {"value": 1}}
  let dispatch = dispatchEnvelope("CUSTOM", data)
  data["nested"]["value"] = %2
  doAssert dispatch["d"]["nested"]["value"].getInt() == 1

block representative_message_and_guild_fixtures_include_required_shape:
  let message = messageCreateDispatch()["d"]
  for field in ["timestamp", "edited_timestamp", "pinned", "components",
      "flags"]:
    doAssert message.hasKey(field)
  let role = guildCreateDispatch()["d"]["roles"][0]
  for field in ["color", "hoist", "position", "managed", "mentionable",
      "flags"]:
    doAssert role.hasKey(field)

# --- Scripted REST transport ------------------------------------------------

proc getRequest(path: string, meta = defaultRequestMeta()): RawRequest =
  initRawRequest(routeKey(hmGet, path), path, meta = meta)

block scripted_rest_happy_path_through_the_real_client:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(jsonResponse(200, %*{"id": "42"}),
    matchRoute("GET /users/@me"))
  let client = newChronosRestClient(scripted.asRestTransport())
  client.start()
  let response = waitFor client.submit(getRequest("/users/@me"))
  doAssert response.status == 200
  doAssert parseJson(response.body.bytesText())["id"].getStr() == "42"
  waitFor client.stop()
  doAssert scripted.observedCount == 1
  scripted.assertSatisfied()

block scripted_rest_reports_a_mismatch_diagnostic:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(204), matchMethod(hmPost))
  let callback = scripted.asRestTransport()
  let future = callback(getRequest("/things"))
  doAssert future.finished and future.failed
  doAssert scripted.recordedFailures.len == 1
  doAssert "expected method POST" in scripted.recordedFailures[0]
  doAssertRaises AssertionDefect:
    scripted.assertNoFailures()

block scripted_rest_flags_an_unexpected_request:
  let scripted = newScriptedRestTransport()
  let future = scripted.asRestTransport()(getRequest("/unscripted"))
  doAssert future.failed
  doAssert scripted.recordedFailures.len == 1
  doAssert "unexpected REST request" in scripted.recordedFailures[0]

block scripted_rest_retries_a_transport_failure:
  var meta = defaultRequestMeta()
  meta.idempotency = idSafe
  let scripted = newScriptedRestTransport()
  scripted.expectFailure(cordErrors.newDiscordError(
    cordErrors.TransportError, "boom"))
  scripted.expectRequest(jsonResponse(200, %*{"ok": true}))
  let client = newChronosRestClient(scripted.asRestTransport())
  client.start()
  let response = waitFor client.submit(getRequest("/retry", meta))
  doAssert response.status == 200
  waitFor client.stop()
  doAssert scripted.observedCount == 2 # Original attempt plus one retry.
  scripted.assertSatisfied()

block scripted_rest_body_matcher_verifies_json_bodies:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(200),
    restMatcher(bodyJson = some(%*{"content": "hi"})))
  let request = initRawRequest(routeKey(hmPost, "/channels/1/messages"),
    "/channels/1/messages", body = jsonBody(%*{"content": "hi"}))
  let future = scripted.asRestTransport()(request)
  doAssert future.finished and not future.failed
  scripted.assertSatisfied()

block scripted_rest_observations_are_redacted_owned_snapshots:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(204), restMatcher(
    redactedBodyJson = some(%*{"content": "hi", "token": "irrelevant"})))
  let request = initRawRequest(
    routeKey(hmPost, "/webhooks/{webhook.id}/{webhook.token}", "123"),
    "/webhooks/123/path-secret",
    body = jsonBody(%*{"content": "hi", "token": "body-secret"}),
    headers = [("Authorization", "Bot header-secret")])
  let future = scripted.asRestTransport()(request)
  doAssert future.finished and not future.failed
  var observed = scripted.observedRequests()
  doAssert observed.len == 1
  doAssert observed[0].bodyRedacted
  let body = observed[0].bodyBytes.bytesText()
  doAssert "body-secret" notin body
  doAssert parseJson(body)["token"].getStr() == redactedSecret
  doAssert observed[0].redactedHeaders[0][1] == redactedSecret
  doAssert "path-secret" notin observed[0].redactedPath
  observed[0].bodyBytes[0] = byte('x')
  observed[0].redactedHeaders[0][1] = "mutated"
  let fresh = scripted.observedRequests()
  doAssert fresh[0].bodyBytes.bytesText() == body
  doAssert fresh[0].redactedHeaders[0][1] == redactedSecret
  scripted.assertSatisfied()

block scripted_rest_diagnostics_never_include_mismatched_values:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(200), restMatcher(
    bodyJson = some(%*{"token": "expected-private-value"})))
  let request = initRawRequest(routeKey(hmPost, "/test"), "/test",
    body = jsonBody(%*{"token": "actual-private-value"}))
  let future = scripted.asRestTransport()(request)
  doAssert future.failed
  let diagnostics = scripted.recordedFailures().join(" ")
  doAssert "expected-private-value" notin diagnostics
  doAssert "actual-private-value" notin diagnostics
  doAssert "$.token" in diagnostics

block scripted_rest_freezes_queued_matchers_and_responses:
  var expected = %*{"content": "before"}
  var matcher = restMatcher(bodyJson = some(expected))
  var response = jsonResponse(200, %*{"value": "original"})
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(response, matcher)
  expected["content"] = %"after"
  matcher.bodyJson.get()["content"] = %"after-again"
  response.body[0] = byte('x')
  let request = initRawRequest(routeKey(hmPost, "/freeze"), "/freeze",
    body = jsonBody(%*{"content": "before"}))
  let future = scripted.asRestTransport()(request)
  doAssert future.finished and not future.failed
  doAssert parseJson(future.read().body.bytesText())["value"].getStr() ==
    "original"
  scripted.assertSatisfied()

block scripted_rest_replaces_opaque_request_bytes:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(204))
  let request = initRawRequest(routeKey(hmPost, "/opaque"), "/opaque",
    body = bytesBody("opaque-private-value".textBytes()))
  discard scripted.asRestTransport()(request)
  let observed = scripted.observedRequests()
  doAssert observed[0].bodyBytes.bytesText() == redactedSecret
  doAssert "opaque-private-value" notin observed[0].bodyBytes.bytesText()

block scripted_rest_unconsumed_response_fails_teardown:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(200))
  doAssert scripted.pendingCount == 1
  doAssertRaises AssertionDefect:
    scripted.assertNoPending()

# --- Scripted Gateway driver ------------------------------------------------

const gatewayUrl = "wss://gateway.discord.gg/?v=10&encoding=json"

block scripted_gateway_happy_path_records_sends_and_close:
  let driver = newScriptedGatewayDriver()
  driver.expectSendJson(%*{"op": 1, "d": nil})
  driver.queueMessageText(toWireText(readyDispatch()))
  driver.queueClose(GatewayCloseCode(1000), "bye")
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  waitFor transport.sendText("""{"d":null,"op":1}""") # Reordered keys.
  let message = waitFor transport.receive()
  doAssert message.kind == gatewayMessageReceived
  doAssert parseJson(message.message.text())["t"].getStr() == "READY"
  let closed = waitFor transport.receive()
  doAssert closed.kind == gatewayTransportClosed
  doAssert closed.closeInfo.code.toUint16() == 1000
  doAssert driver.connectedUrls == @[gatewayUrl]
  doAssert driver.sentMessages.len == 1
  driver.assertSatisfied()

block scripted_gateway_end_of_stream_fails_the_receive:
  let driver = newScriptedGatewayDriver()
  driver.queueMessageText("{}")
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  discard waitFor transport.receive()
  doAssertRaises GatewayTransportError:
    discard waitFor transport.receive()
  driver.assertNoPendingEvents() # The message was consumed; the failure was not queued.

block scripted_gateway_cancellation_aborts_the_transport:
  let driver = newScriptedGatewayDriver()
  driver.queueReceiveCancellation()
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  doAssertRaises CancelledError:
    discard waitFor transport.receive()
  doAssert transport.isClosed
  doAssert driver.abortCount == 1

block scripted_gateway_send_mismatch_is_recorded:
  let driver = newScriptedGatewayDriver()
  driver.expectSendText("expected")
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  waitFor transport.sendText("actual")
  doAssert driver.sendFailures.len == 1
  doAssertRaises AssertionDefect:
    driver.assertSendsMatched()
  transport.abort()

block scripted_gateway_redacts_sent_identify_payloads_and_returns_copies:
  let driver = newScriptedGatewayDriver()
  var expected = %*{"op": 2, "d": {"token": "Bot identify-secret"}}
  driver.expectSendJson(expected)
  expected["d"]["token"] = %"mutated-after-queue"
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  waitFor transport.sendText(
    $(%*{"op": 2, "d": {"token": "Bot identify-secret"}}))
  var sent = driver.sentMessages()
  doAssert sent.len == 1
  let recorded = parseJson(sent[0].text())
  doAssert recorded["d"]["token"].getStr() == redactedSecret
  doAssert "identify-secret" notin sent[0].text()
  sent[0].data[0] = byte('x')
  doAssert parseJson(driver.sentMessages()[0].text())["op"].getInt() == 2
  driver.assertSendsMatched()
  transport.abort()

block scripted_gateway_json_mismatch_diagnostics_are_value_free:
  let driver = newScriptedGatewayDriver()
  driver.expectSendJson(%*{"op": 2, "d": {"token": "expected-secret"}})
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  waitFor transport.sendText(
    $(%*{"op": 2, "d": {"token": "actual-secret"}}))
  let diagnostics = driver.sendFailures().join(" ")
  doAssert "expected-secret" notin diagnostics
  doAssert "actual-secret" notin diagnostics
  doAssert "$.d.token" in diagnostics
  transport.abort()

block scripted_gateway_rejects_sends_beyond_the_expected_sequence:
  let driver = newScriptedGatewayDriver()
  driver.expectSendText("one")
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  waitFor transport.sendText("one")
  waitFor transport.sendText("two")
  doAssert driver.sendFailures().join(" ").contains("unexpected Gateway send")
  doAssert not driver.satisfied
  transport.abort()

block scripted_gateway_copies_queued_binary_events:
  var bytes = @[1'u8, 2, 3]
  let driver = newScriptedGatewayDriver()
  driver.queueMessageBinary(bytes)
  bytes[0] = 9
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  let event = waitFor transport.receive()
  doAssert event.message.data == @[1'u8, 2, 3]
  driver.assertSatisfied()
  transport.abort()

block scripted_gateway_connect_failure_is_one_shot:
  let driver = newScriptedGatewayDriver()
  driver.failConnect()
  let backend = driver.asDriver()
  doAssertRaises GatewayTransportError:
    discard waitFor connectGatewayTransport(gatewayUrl, backend)
  let transport = waitFor connectGatewayTransport(gatewayUrl, backend)
  transport.abort()

block scripted_gateway_redacts_urls_and_close_reasons:
  let driver = newScriptedGatewayDriver()
  let transport = waitFor connectGatewayTransport(
    gatewayUrl & "&token=url-secret#fragment-secret", driver.asDriver())
  waitFor transport.closeWait(reason = "close-secret")
  let urls = driver.connectedUrls()
  doAssert "url-secret" notin urls[0]
  doAssert "fragment-secret" notin urls[0]
  doAssert driver.closeCalls()[0].reason == redactedSecret

block scripted_gateway_pending_receive_is_reported_and_cancelled:
  let driver = newScriptedGatewayDriver()
  driver.queueReceivePending()
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  let pending = transport.receive()
  waitFor sleepAsync(0.milliseconds)
  doAssert driver.unfinishedReceiveCount == 1
  var report = initTeardownReport()
  report.check(driver)
  doAssert report.problems.join(" ").contains("unfinished receive")
  transport.abort()
  try:
    discard waitFor pending
  except CancelledError:
    discard
  waitFor sleepAsync(0.milliseconds)
  doAssert driver.unfinishedReceiveCount == 0

# --- Cassette record/replay -------------------------------------------------

block cassette_redacts_and_round_trips_rest_exchanges:
  var cassette = initCassette()
  let request = initRawRequest(
    routeKey(hmPost,
      "/webhooks/{webhook.id}/{webhook.token}/messages", "555"),
    "/webhooks/555/supersecret/messages",
    body = jsonBody(%*{"content": "hi", "token": "leak"}),
    headers = [("Authorization", "Bot secret-token")])
  let response = jsonResponse(200, %*{"id": "1", "token": "leak"})
  cassette.recordRestExchange(request, response)
  let exported = cassette.toJson()
  let text = $exported
  doAssert "supersecret" notin text
  doAssert "leak" notin text
  doAssert "secret-token" notin text
  doAssert redactedSecret in text
  # JSON round-trips and never reconstructs the original secret.
  let reloaded = parseCassette(exported)
  doAssert reloaded.restExchanges.len == 1
  doAssert redactedSecret in $reloaded.toJson()
  # Replay yields the recorded (redacted) response through the real client.
  let scripted = reloaded.replayRestTransport()
  let client = newChronosRestClient(scripted.asRestTransport())
  client.start()
  let replayRequest = initRawRequest(
    routeKey(hmPost,
      "/webhooks/{webhook.id}/{webhook.token}/messages", "555"),
    "/webhooks/555/different-secret/messages",
    body = jsonBody(%*{"content": "hi", "token": "different-body-secret"}),
    headers = [("Authorization", "Bot different-header-secret")])
  let replayed = waitFor client.submit(replayRequest)
  doAssert replayed.status == 200
  doAssert parseJson(replayed.body.bytesText())["token"].getStr() ==
    redactedSecret
  waitFor client.stop()
  scripted.assertSatisfied()

block cassette_replay_rejects_a_different_rest_request:
  var cassette = initCassette()
  let recorded = initRawRequest(routeKey(hmPost, "/channels/{channel.id}", "1"),
    "/channels/1", body = jsonBody(%*{"name": "recorded"}))
  cassette.recordRestExchange(recorded, transportResponse(204))
  let scripted = cassette.replayRestTransport()
  let different = initRawRequest(routeKey(hmPost, "/channels/{channel.id}", "2"),
    "/channels/2", body = jsonBody(%*{"name": "different"}))
  let future = scripted.asRestTransport()(different)
  doAssert future.failed
  doAssert scripted.recordedFailures().len == 1

block cassette_replay_matches_empty_body_kind_and_redacted_headers:
  var cassette = initCassette()
  let recorded = initRawRequest(routeKey(hmPost, "/empty"), "/empty",
    headers = [("X-Test", "recorded")])
  cassette.recordRestExchange(recorded, transportResponse(204))
  let scripted = cassette.replayRestTransport()
  let different = initRawRequest(routeKey(hmPost, "/empty"), "/empty",
    body = jsonBody(%*{"unexpected": true}),
    headers = [("X-Test", "different")])
  let future = scripted.asRestTransport()(different)
  doAssert future.failed
  doAssert not scripted.satisfied

block cassette_replay_matches_opaque_body_length:
  var cassette = initCassette()
  let recorded = initRawRequest(routeKey(hmPost, "/opaque-cassette"),
    "/opaque-cassette", body = bytesBody(@[1'u8, 2, 3]))
  cassette.recordRestExchange(recorded, transportResponse(204))
  let scripted = cassette.replayRestTransport()
  let different = initRawRequest(routeKey(hmPost, "/opaque-cassette"),
    "/opaque-cassette", body = bytesBody(@[1'u8, 2]))
  let future = scripted.asRestTransport()(different)
  doAssert future.failed
  doAssert "body length" in scripted.recordedFailures().join(" ")

block cassette_drops_response_representation_headers_after_redaction:
  var cassette = initCassette()
  let request = getRequest("/representation")
  let response = jsonResponse(200, %*{"token": "private"}, [
    ("Content-Length", "999"),
    ("Content-Encoding", "gzip"),
    ("ETag", "private-validator"),
    ("X-RateLimit-Limit", "5"),
  ])
  cassette.recordRestExchange(request, response)
  let exportedHeaders = cassette.toJson()["rest"][0]["response"]["headers"]
  let exportedText = $exportedHeaders
  for removed in ["Content-Length", "Content-Encoding", "ETag",
      "private-validator"]:
    doAssert removed notin exportedText
  doAssert "X-RateLimit-Limit" in exportedText
  let replay = cassette.replayRestTransport()
  let future = replay.asRestTransport()(request)
  doAssert future.finished and not future.failed
  let replayedHeaders = future.read().headers
  for (name, _) in replayedHeaders:
    doAssert name.toLowerAscii() notin ["content-length", "content-encoding",
      "etag"]

block cassette_drops_opaque_response_representation_metadata:
  var cassette = initCassette()
  let request = getRequest("/opaque-response")
  let response = transportResponse(206, "private-image-bytes".textBytes(), [
    ("Content-Type", "image/png"),
    ("Content-Range", "bytes 0-18/19"),
    ("X-RateLimit-Limit", "5"),
  ])
  cassette.recordRestExchange(request, response)
  let exported = cassette.toJson()["rest"][0]["response"]
  doAssert exported["body"].getStr() == redactedSecret
  let headersText = $exported["headers"]
  doAssert "Content-Type" notin headersText
  doAssert "image/png" notin headersText
  doAssert "Content-Range" notin headersText
  doAssert "bytes 0-18/19" notin headersText
  doAssert "X-RateLimit-Limit" in headersText

  let replay = cassette.replayRestTransport()
  let future = replay.asRestTransport()(request)
  doAssert future.finished and not future.failed
  doAssert future.read().body.bytesText() == redactedSecret
  for (name, _) in future.read().headers:
    doAssert name.toLowerAscii() notin ["content-type", "content-range"]

block cassette_records_and_replays_gateway_text_and_close:
  var cassette = initCassette()
  cassette.recordGatewayEvent(messageEvent(textGatewayMessage(
    toWireText(messageCreateDispatch()))))
  cassette.recordGatewayEvent(closeEvent(GatewayCloseInfo(
    code: GatewayCloseCode(1001), reason: "private close reason", clean: true)))
  let reloaded = parseCassette(cassette.toJson())
  let driver = reloaded.replayGatewayDriver()
  let transport = waitFor connectGatewayTransport(gatewayUrl, driver.asDriver())
  let textEvent = waitFor transport.receive()
  doAssert parseJson(textEvent.message.text())["t"].getStr() == "MESSAGE_CREATE"
  let closed = waitFor transport.receive()
  doAssert closed.closeInfo.code.toUint16() == 1001
  doAssert closed.closeInfo.reason == redactedSecret
  driver.assertNoPendingEvents()

block cassette_binary_frames_are_metadata_only_and_unreplayable:
  var cassette = initCassette()
  cassette.recordGatewayEvent(messageEvent(binaryGatewayMessage(
    "binary-secret".textBytes())))
  let exported = cassette.toJson()
  let record = exported["gateway"][0]
  doAssert record["length"].getInt() == "binary-secret".len
  doAssert not record.hasKey("data")
  doAssert "binary-secret" notin $exported
  doAssertRaises ValueError:
    discard parseCassette(exported).replayGatewayDriver()

block cassette_parsing_and_export_redact_untrusted_fields_again:
  let untrusted = %*{
    "version": 2,
    "rest": [{
      "request": {
        "method": "POST",
        "route": "POST /webhooks/1/route-secret",
        "path": "/webhooks/1/path-secret?token=query-secret",
        "headers": [{"name": "Authorization", "value": "Bot header-secret"}],
        "body_kind": "rbJson",
        "body_length": 27,
        "body": "{\"token\":\"request-secret\"}",
      },
      "response": {
        "status": 200,
        "headers": [{"name": "Set-Cookie", "value": "cookie-secret"}],
        "body": "{\"access_token\":\"response-secret\"}",
      },
    }],
    "gateway": [
      {
        "kind": "message_text",
        "text": "{\"d\":{\"token\":\"gateway-secret\"}}",
      },
      {
        "kind": "close",
        "code": 1000,
        "reason": "close-secret",
        "clean": true,
      },
    ],
  }
  var cassette = parseCassette(untrusted)
  cassette.restExchanges[0].request.bodyText =
    "{\"token\":\"mutated-secret\"}"
  cassette.gatewayRecords[0].text =
    "{\"token\":\"mutated-gateway-secret\"}"
  let exported = $cassette.toJson()
  for secret in ["route-secret", "path-secret", "query-secret",
      "header-secret", "request-secret", "cookie-secret", "response-secret",
      "gateway-secret", "close-secret", "mutated-secret",
      "mutated-gateway-secret"]:
    doAssert secret notin exported
  doAssert redactedSecret in exported

block cassette_rejects_invalid_version_status_and_close_code:
  doAssertRaises ValueError:
    discard parseCassette(%*{"version": 1})
  doAssertRaises ValueError:
    discard parseCassette(%*{
      "version": 2,
      "rest": [{
        "request": {"method": "GET", "route": "GET /x", "path": "/x",
          "body_kind": "rbEmpty", "body_length": 0, "body": ""},
        "response": {"status": 999, "body": ""},
      }],
    })
  doAssertRaises ValueError:
    discard parseCassette(%*{
      "version": 2,
      "gateway": [{"kind": "close", "code": 42, "reason": "",
        "clean": true}],
    })

# --- Teardown aggregation ---------------------------------------------------

block teardown_report_aggregates_outstanding_work:
  let scripted = newScriptedRestTransport()
  scripted.expectRequest(transportResponse(200)) # Left unconsumed.
  let driver = newScriptedGatewayDriver()
  driver.queueMessageText("{}") # Left unconsumed.
  var report = initTeardownReport()
  report.check(scripted, "rest")
  report.check(driver, "gateway")
  doAssert not report.isClean
  doAssert report.problems.len == 2
  doAssertRaises AssertionDefect:
    report.assertClean()

block teardown_report_is_clean_when_everything_is_consumed:
  let scripted = newScriptedRestTransport()
  var report = initTeardownReport()
  report.check(scripted)
  doAssert report.isClean
  report.assertClean()

block teardown_reports_an_idle_but_running_rest_client:
  let scripted = newScriptedRestTransport()
  let client = newChronosRestClient(scripted.asRestTransport())
  client.start()
  var runningReport = initTeardownReport()
  runningReport.check(client)
  doAssert not runningReport.isClean
  doAssert "still running" in runningReport.problems.join(" ")
  waitFor client.stop()
  var stoppedReport = initTeardownReport()
  stoppedReport.check(client)
  doAssert stoppedReport.isClean
