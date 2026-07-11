import std/unittest

import cordnim/components

type DeployAction = object
  buildId: uint32
  revision: uint16

proc encodeDeploy(value: DeployAction): seq[byte]
    {.gcsafe, raises: [].} =
  @[
    byte(value.buildId shr 24), byte(value.buildId shr 16),
    byte(value.buildId shr 8), byte(value.buildId),
    byte(value.revision shr 8), byte(value.revision)
  ]

proc decodeDeploy(payload: openArray[byte]): DeployAction
    {.gcsafe, raises: [ValueError].} =
  if payload.len != 6:
    raise newException(ValueError, "invalid deploy route length")
  result.buildId = uint32(payload[0]) shl 24 or uint32(payload[1]) shl 16 or
    uint32(payload[2]) shl 8 or uint32(payload[3])
  result.revision = uint16(payload[4]) shl 8 or uint16(payload[5])

proc testSigner(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} =
  for index, value in key:
    result[index mod result.len] = result[index mod result.len] xor value
  for index, value in message:
    result[index mod result.len] = result[index mod result.len] xor value

func deployCodec(version = 2'u8): TypedRouteCodec[DeployAction] =
  TypedRouteCodec[DeployAction](
    envelope: RouteCodec(
      activeKeyId: 7,
      keys: @[RouteSigningKey(id: 7, material: @[byte 1, 2, 3])],
      signer: testSigner
    ),
    routeTypeId: 42,
    activeVersion: version,
    encodePayload: encodeDeploy,
    decoders: @[
      VersionedRouteDecoder[DeployAction](version: 1, decode: decodeDeploy),
      VersionedRouteDecoder[DeployAction](version: 2, decode: decodeDeploy)
    ]
  )

suite "typed persistent component routes":
  test "recovers a typed action without process-local collector state":
    let codec = deployCodec()
    let action = DeployAction(buildId: 9001, revision: 3)
    let customId = codec.encode(action, 2_000)
    let decoded = codec.decode(customId, 1_000)
    check decoded.ok
    check decoded.value.buildId == 9001
    check decoded.value.revision == 3
    check routedButton("Deploy", codec, action, 2_000).customId == customId

  test "accepts migration versions and rejects unrelated route types":
    let oldId = deployCodec(1).encode(
      DeployAction(buildId: 4, revision: 1), 2_000)
    check deployCodec(2).decode(oldId, 1_000).ok

    var wrong = deployCodec(2)
    wrong.routeTypeId = 99
    check wrong.decode(oldId, 1_000).error == treWrongRouteType
