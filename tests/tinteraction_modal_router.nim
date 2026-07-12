import std/[json, options, strutils, unittest]

import chronos

import cordnim/[components, interactions]
import cordnim/rest/chronos_driver

type
  Services = object
    prefix: string

  ReviewRoute = object
    ticket: uint16

  ReviewForm {.discordModal(title = "Review", customId = "review_v1").} = object
    summary {.textInput(
      label = "Summary",
      minLength = 3,
      maxLength = 100
    ).}: string

deriveDiscordModal(ReviewForm)

proc signer(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} =
  for index, value in key:
    result[index mod result.len] = result[index mod result.len] xor value
  for index, value in message:
    result[index mod result.len] = result[index mod result.len] xor value

proc encodeReviewRoute(value: ReviewRoute): seq[byte] {.gcsafe, raises: [].} =
  @[byte(value.ticket shr 8), byte(value.ticket)]

proc decodeReviewRoute(payload: openArray[byte]): ReviewRoute
    {.gcsafe, raises: [ValueError].} =
  if payload.len != 2:
    raise newException(ValueError, "bad route payload")
  ReviewRoute(ticket: uint16(payload[0]) shl 8 or uint16(payload[1]))

func stateCodec(typeId: uint16 = 20): TypedRouteCodec[ReviewRoute] =
  let envelope = RouteCodec(
    activeKeyId: 1,
    keys: @[RouteSigningKey(id: 1, material: @[byte 9, 8, 7])],
    signer: signer
  )
  TypedRouteCodec[ReviewRoute](
    envelope: envelope,
    routeTypeId: typeId,
    activeVersion: 1,
    encodePayload: encodeReviewRoute,
    decoders: @[
      VersionedRouteDecoder[ReviewRoute](version: 1, decode: decodeReviewRoute)
    ]
  )

proc reviewDecoder(data: JsonNode, hooks: ModalDecodeHooks):
    ModalDecodeResult[ReviewForm] {.gcsafe, raises: [CatchableError].} =
  decodeDiscordModal(ReviewForm, data, hooks)

proc svc(prefix = ""): ref Services =
  new result
  result.prefix = prefix

proc submission(customId: string, summary = "Ship it",
                extraField = false): JsonNode =
  result = %*{
    "id": "100",
    "application_id": "200",
    "type": 5,
    "token": "tkn",
    "context": 1,
    "user": {"id": "42"},
    "data": {
      "custom_id": customId,
      "components": [
        {"type": 18, "component": {
          "type": 4, "custom_id": "summary", "value": summary
        }}
      ]
    }
  }
  if extraField:
    result["data"]["components"].add(%*{"type": 18, "component": {
      "type": 4, "custom_id": "future_field", "value": "kept"
    }})

proc handleReview(context: ModalCtx[Services], route: ReviewRoute,
                  form: ModalDecodeResult[ReviewForm]):
    Future[ComponentResponse] {.async.} =
  if not form.ok:
    return replyComponent(%*{"content": "invalid:" & $form.problems.len})
  return replyComponent(%*{"content":
    context.services.prefix & $route.ticket & ":" & form.value.summary &
      ":u" & $form.unknownFields.len})

proc handleBoom(context: ModalCtx[Services], route: ReviewRoute,
                form: ModalDecodeResult[ReviewForm]):
    Future[ComponentResponse] {.async.} =
  discard context
  discard route
  discard form
  raise newException(ValueError, "SECRET-modal-detail")

proc handleDeferredUpdate(context: ModalCtx[Services], route: ReviewRoute,
                          form: ModalDecodeResult[ReviewForm]):
    Future[ComponentResponse] {.async.} =
  discard route
  discard form
  await context.deferUpdate()
  return respondedViaContext()

proc handleImmediateUpdate(context: ModalCtx[Services], route: ReviewRoute,
                           form: ModalDecodeResult[ReviewForm]):
    Future[ComponentResponse] {.async.} =
  discard context
  discard route
  discard form
  return updateComponent(%*{"content": "updated source"})

suite "typed modal submission router":
  test "recovers route state and decodes the form after a restart":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = stateCodec()
      let customId = codec.encode(ReviewRoute(ticket: 77), 2_000)
      let router = newModalRouter(svc("ok:"), codec.envelope)
      router.register(codec, reviewDecoder, handleReview)
      result = await router.route(submission(customId), 1_000)
      await router.close()

    let response = waitFor scenario()
    check response["type"].getInt() == 4
    # The signed route authenticated identity, so the redundant WrongModal
    # problem is stripped and the form decodes cleanly.
    check response["data"]["content"].getStr() == "ok:77:Ship it:u0"

  test "shows and round-trips a routed modal custom_id":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = stateCodec()
      let shownSpec = routedModalSpec(
        codec, ReviewRoute(ticket: 5), modalSpec(ReviewForm), 2_000)
      let shown = shownSpec.toJson()
      doAssert shown["custom_id"].getStr().startsWith("c.")
      let router = newModalRouter(svc("rt:"), codec.envelope)
      router.register(codec, reviewDecoder, handleReview)
      result = await router.route(
        submission(shown["custom_id"].getStr(), "Hello!"), 1_000)
      await router.close()

    check waitFor(scenario())["data"]["content"].getStr() == "rt:5:Hello!:u0"

  test "routed modal serialization rejects an invalid schema":
    expect ValueError:
      discard routedModalJson(
        stateCodec(), ReviewRoute(ticket: 5),
        initModalSpec("ignored", "", []), 2_000)

  test "hands accumulated validation problems to the handler":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = stateCodec()
      let customId = codec.encode(ReviewRoute(ticket: 1), 2_000)
      let router = newModalRouter(svc(), codec.envelope)
      router.register(codec, reviewDecoder, handleReview)
      result = await router.route(submission(customId, "ab"), 1_000)
      await router.close()

    check waitFor(scenario())["data"]["content"].getStr().startsWith("invalid:")

  test "preserves undeclared submitted fields for the handler":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = stateCodec()
      let customId = codec.encode(ReviewRoute(ticket: 2), 2_000)
      let router = newModalRouter(svc("u:"), codec.envelope)
      router.register(codec, reviewDecoder, handleReview)
      result = await router.route(
        submission(customId, "Ship it", extraField = true), 1_000)
      await router.close()

    check waitFor(scenario())["data"]["content"].getStr() == "u:2:Ship it:u1"

  test "wrong modal route type fails explicitly":
    proc scenario(): Future[bool] {.async.} =
      let registered = stateCodec(20)
      let foreign = stateCodec(99)
      let customId = foreign.encode(ReviewRoute(ticket: 1), 2_000)
      let router = newModalRouter(svc(), registered.envelope)
      router.register(registered, reviewDecoder, handleReview)
      try:
        discard await router.route(submission(customId), 1_000)
        return false
      except ModalRouteDispatchError:
        await router.close()
        return true

    check waitFor scenario()

  test "rejects a tampered custom_id before decoding":
    proc scenario(): Future[bool] {.async.} =
      let codec = stateCodec()
      var customId = codec.encode(ReviewRoute(ticket: 1), 2_000)
      customId[^1] = if customId[^1] == 'A': 'B' else: 'A'
      let router = newModalRouter(svc(), codec.envelope)
      router.register(codec, reviewDecoder, handleReview)
      try:
        discard await router.route(submission(customId), 1_000)
        return false
      except ModalRouteDispatchError:
        await router.close()
        return true

    check waitFor scenario()

  test "duplicate route registrations fail explicitly":
    let codec = stateCodec()
    let router = newModalRouter(svc(), codec.envelope)
    router.register(codec, reviewDecoder, handleReview)
    expect ValueError:
      router.register(codec, reviewDecoder, handleReview)
    waitFor router.close()

  test "application exceptions are redacted at the dispatch boundary":
    proc scenario(): Future[string] {.async.} =
      let codec = stateCodec(21)
      let customId = codec.encode(ReviewRoute(ticket: 1), 2_000)
      let router = newModalRouter(svc(), codec.envelope)
      router.register(codec, reviewDecoder, handleBoom)
      try:
        discard await router.route(submission(customId), 1_000)
        return "no error"
      except ModalRouteDispatchError as error:
        await router.close()
        return error.msg

    let message = waitFor scenario()
    check not message.contains("SECRET")
    check message.contains("modal route handler failed")

  test "command-origin modal submissions reject update callbacks":
    proc scenario(): Future[bool] {.async.} =
      let codec = stateCodec(22)
      let customId = codec.encode(ReviewRoute(ticket: 1), 2_000)
      let router = newModalRouter(svc(), codec.envelope)
      router.register(codec, reviewDecoder, handleDeferredUpdate)
      try:
        discard await router.route(submission(customId), 1_000)
        return false
      except ModalRouteDispatchError:
        await router.close()
        return true

    check waitFor scenario()

  test "component-origin modal submissions permit defer and update":
    proc scenario(): Future[(JsonNode, JsonNode)] {.async.} =
      let deferredCodec = stateCodec(23)
      let deferredId = deferredCodec.encode(ReviewRoute(ticket: 1), 2_000)
      let deferredRouter = newModalRouter(svc(), deferredCodec.envelope)
      deferredRouter.register(
        deferredCodec, reviewDecoder, handleDeferredUpdate)
      var deferredSubmit = submission(deferredId)
      deferredSubmit["message"] = %*{"id": "900", "channel_id": "901"}
      let deferred = await deferredRouter.route(deferredSubmit, 1_000)
      await deferredRouter.close()

      let updateCodec = stateCodec(24)
      let updateId = updateCodec.encode(ReviewRoute(ticket: 2), 2_000)
      let updateRouter = newModalRouter(svc(), updateCodec.envelope)
      updateRouter.register(updateCodec, reviewDecoder, handleImmediateUpdate)
      var updateSubmit = submission(updateId)
      updateSubmit["message"] = %*{"id": "902", "channel_id": "903"}
      let updated = await updateRouter.route(updateSubmit, 1_000)
      await updateRouter.close()
      return (deferred, updated)

    let (deferred, updated) = waitFor scenario()
    check deferred["type"].getInt() == 6
    check updated["type"].getInt() == 7
