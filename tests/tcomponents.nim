import std/[options, strutils, unittest]

import cordnim/components
import cordnim/core/ids

suite "Components V2":
  test "literal DSL builds a legal independent message tree":
    let draft = v2Message:
      container:
        text "## Build complete"
        section:
          text "Commit is ready."
          thumbnail "https://example.invalid/icon.png"
        separator()
        actions:
          button "Deploy", "deploy:1"
          button "Cancel", "cancel:1"
    check draft.validate().valid
    check draft.v2.children[0].countComponents == 9

  test "link and interactive targets are mutually exclusive":
    let draft = v2Draft(actionRow(button(
      "broken", customId = "id", url = "https://example.invalid"
    )))
    let validation = draft.validate()
    check not validation.valid
    check validation.problems[0].kind == cpkButtonTargetConflict

  test "premium buttons reject label and emoji fields":
    let labeled = v2Draft(actionRow(component(
      mckButton,
      text = "Buy",
      buttonStyle = bsPremium,
      skuId = some(toId(SkuId, 9))
    )))
    check not labeled.validate().valid
    let decorated = v2Draft(actionRow(component(
      mckButton,
      buttonStyle = bsPremium,
      skuId = some(toId(SkuId, 9)),
      emoji = some(componentEmoji("💎"))
    )))
    check not decorated.validate().valid

  test "custom IDs use character limits and modal-only fields stay out":
    let unicodeId = repeat("界", MaxCustomIdLength)
    check v2Draft(actionRow(button("Run", unicodeId))).validate().valid
    check not v2Draft(actionRow(button(
      "Run", unicodeId & "界"))).validate().valid
    let modalOnly = v2Draft(actionRow(component(
      mckStringSelect,
      customId = "choice",
      required = some(true),
      options = @[selectOption("One", "one")]
    )))
    check not modalOnly.validate().valid

  test "component strings must be valid UTF-8":
    let validation = v2Draft(textDisplay("\xFF")).validate()
    check not validation.valid
    check validation.problems[0].kind == cpkInvalidText

  test "legacy handles only upgrade in one direction":
    let legacy = messageHandle[Legacy](
      toId(ChannelId, 1), toId(MessageId, 2))
    let upgraded = legacy.upgradedHandle()
    check $upgraded.channelId == "1"

suite "persistent component routes":
  proc testSigner(key, message: openArray[byte]): array[32, byte]
      {.gcsafe, raises: [].} =
    ## Deterministic test double. Production must supply HMAC-SHA-256.
    for index, item in key:
      result[index mod result.len] = result[index mod result.len] xor item
    for index, item in message:
      result[index mod result.len] = result[index mod result.len] xor item

  test "routes survive restart through their signed custom ID":
    let codec = RouteCodec(
      activeKeyId: 7,
      keys: @[RouteSigningKey(id: 7, material: @[byte 1, 2, 3])],
      signer: testSigner
    )
    let encoded = codec.encodeRoute(42, 2, 2_000, @[byte 9, 8])
    let decoded = codec.decodeRoute(encoded, 1_000)
    check decoded.ok
    check decoded.envelope.routeTypeId == 42
    check decoded.envelope.version == 2
    check decoded.envelope.payload == @[byte 9, 8]

  test "tampering and expiry are rejected":
    let codec = RouteCodec(
      activeKeyId: 1,
      keys: @[RouteSigningKey(id: 1, material: @[byte 4, 5])],
      signer: testSigner
    )
    let encoded = codec.encodeRoute(1, 1, 50, @[byte 1])
    check codec.decodeRoute(encoded, 51).error == rdeExpired
    var tampered = encoded
    tampered[4] = if tampered[4] == 'A': 'B' else: 'A'
    check not codec.decodeRoute(tampered, 1).ok

  test "malformed encodings are rejected":
    let codec = RouteCodec(
      activeKeyId: 1,
      keys: @[RouteSigningKey(id: 1, material: @[byte 4, 5])],
      signer: testSigner
    )
    check codec.decodeRoute("c.A@AA\n", 1).error == rdeMalformed
    check codec.decodeRoute("c." & repeat('A', 99), 1).error == rdeMalformed
