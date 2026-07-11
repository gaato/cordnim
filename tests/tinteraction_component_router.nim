import std/[json, unittest]

import chronos

import cordnim/[components, interactions]

type
  Services = object
    prefix: string

  DeployAction = object
    buildId: uint16

proc signer(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} =
  for index, value in key:
    result[index mod result.len] = result[index mod result.len] xor value
  for index, value in message:
    result[index mod result.len] = result[index mod result.len] xor value

proc encodeAction(value: DeployAction): seq[byte]
    {.gcsafe, raises: [].} =
  @[byte(value.buildId shr 8), byte(value.buildId)]

proc decodeAction(payload: openArray[byte]): DeployAction
    {.gcsafe, raises: [ValueError].} =
  if payload.len != 2:
    raise newException(ValueError, "wrong action length")
  DeployAction(buildId: uint16(payload[0]) shl 8 or uint16(payload[1]))

func routeCodec(): TypedRouteCodec[DeployAction] =
  let envelope = RouteCodec(
    activeKeyId: 1,
    keys: @[RouteSigningKey(id: 1, material: @[byte 3, 4, 5])],
    signer: signer
  )
  TypedRouteCodec[DeployAction](
    envelope: envelope,
    routeTypeId: 10,
    activeVersion: 2,
    encodePayload: encodeAction,
    decoders: @[
      VersionedRouteDecoder[DeployAction](version: 1, decode: decodeAction),
      VersionedRouteDecoder[DeployAction](version: 2, decode: decodeAction)
    ]
  )

proc interaction(customId: string): JsonNode =
  %*{
    "id": "100",
    "type": 3,
    "context": 1,
    "user": {"id": "42"},
    "data": {
      "component_type": 2,
      "custom_id": customId
    }
  }

proc handleDeploy(context: ComponentCtx[Services], action: DeployAction):
    Future[ComponentResponse] {.async.} =
  return updateComponent(%*{
    "content": context.services.prefix & $action.buildId
  })

suite "persistent component router":
  test "authenticates and dispatches typed state after a restart":
    proc scenario(): Future[JsonNode] {.async.} =
      let codec = routeCodec()
      let customId = codec.encode(DeployAction(buildId: 9001), 2_000)
      let router = newComponentRouter(
        Services(prefix: "build:"), codec.envelope)
      router.register(codec, handleDeploy)
      return await router.route(interaction(customId), 1_000)

    let response = waitFor scenario()
    check response["type"].getInt() == 7
    check response["data"]["content"].getStr() == "build:9001"
    check response["data"]["allowed_mentions"]["parse"].len == 0

  test "rejects tampering before invoking a route handler":
    proc scenario(): Future[bool] {.async.} =
      let codec = routeCodec()
      var customId = codec.encode(DeployAction(buildId: 7), 2_000)
      customId[^1] = if customId[^1] == 'A': 'B' else: 'A'
      let router = newComponentRouter(Services(), codec.envelope)
      router.register(codec, handleDeploy)
      try:
        discard await router.route(interaction(customId), 1_000)
        return false
      except ComponentRouteDispatchError:
        return true

    check waitFor scenario()
