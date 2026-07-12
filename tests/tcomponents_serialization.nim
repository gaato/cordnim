import std/[json, options, sequtils, unittest]

import cordnim/components
import cordnim/core/ids

suite "Components V2 wire serialization":
  test "sets the irreversible V2 flag and legal component shapes":
    let draft = v2Message:
      container:
        text "## Ready"
        section:
          text "Deploy this build?"
          thumbnail "https://example.invalid/icon.png"
        actions:
          button "Deploy", "deploy:1"
    let wire = draft.toJson()
    check wire["flags"].getInt() == ComponentsV2MessageFlag
    check wire["components"][0]["type"].getInt() == 17
    check wire["components"][0]["components"][0]["type"].getInt() == 10
    check(
      wire["components"][0]["components"][1]["accessory"]["type"]
        .getInt() == 11
    )

  test "serializes string-select options explicitly":
    let draft = v2Draft(actionRow(stringSelect(
      "environment",
      [selectOption("Staging", "staging"),
       selectOption("Production", "production")]
    )))
    let wire = draft.toJson()
    check wire["components"][0]["components"][0]["type"].getInt() == 3
    check wire["components"][0]["components"][0]["options"].len == 2

  test "legacy serialization never sets the V2 flag":
    let wire = legacyMessage("hello").toJson()
    check wire["content"].getStr() == "hello"
    check not wire.hasKey("flags")

  test "serializes every style-specific message component field":
    let draft = v2Draft(
      section(
        textDisplay("Premium"),
        premiumButton(toId(SkuId, 55))
      ),
      actionRow(channelSelect(
        "channel",
        defaults = @[defaultChannel(toId(ChannelId, 77))],
        channelTypes = @[mctGuildText, mctGuildVoice]
      )),
      mediaGallery(mediaItem(
        "https://example.invalid/image.png",
        description = "Architecture", spoiler = true
      )),
      fileComponent("report.pdf", spoiler = true),
      separator(spacing = some(ssLarge), divider = some(false)),
      component(mckContainer, accentColor = some(0x58_65_f2),
        spoiler = true, children = @[textDisplay("Styled")])
    )
    let wire = draft.toJson()
    check wire["components"][0]["accessory"]["sku_id"].getStr() == "55"
    check(
      wire["components"][1]["components"][0]["default_values"][0]["type"]
        .getStr() == "channel"
    )
    check wire["components"][1]["components"][0]["channel_types"].len == 2
    check(
      wire["components"][2]["items"][0]["description"].getStr() ==
        "Architecture"
    )
    check wire["components"][3]["spoiler"].getBool()
    check wire["components"][4]["spacing"].getInt() == 2
    check not wire["components"][4]["divider"].getBool()
    check wire["components"][5]["accent_color"].getInt() == 0x58_65_f2

  test "serializes typed IDs across every component-object constructor":
    var nextId = 1'u32
    proc id(): Option[ComponentId] =
      result = some(toComponentId(nextId))
      inc nextId

    let draft = v2Draft(
      actionRow(id(), button("Run", "run", id = id())),
      actionRow(id(), premiumButton(toId(SkuId, 8), id = id())),
      actionRow(id(), stringSelect("string", [
        selectOption("One", "one")
      ], id = id())),
      actionRow(id(), userSelect("user", id = id())),
      actionRow(id(), roleSelect("role", id = id())),
      actionRow(id(), mentionableSelect("mentionable", id = id())),
      actionRow(id(), channelSelect("channel", id = id())),
      section(id(), textDisplay("Section", id = id()),
        thumbnail("https://example.invalid/thumb.png", id = id())),
      mediaGallery(id(), mediaItem("https://example.invalid/image.png")),
      fileComponent("report.txt", id = id()),
      separator(id = id()),
      container(id(), textDisplay("Contained", id = id())),
      component(mckTextDisplay, text = "Raw", id = id())
    )

    let validation = draft.validate()
    check validation.valid
    let wire = draft.toJson()
    check wire["components"][0]["id"].getInt() == 1
    check wire["components"][0]["components"][0]["id"].getInt() == 2
    check wire["components"][7]["accessory"]["id"].getInt() == 17
    check wire["components"][8]["id"].getInt() == 18
    check not wire["components"][8]["items"][0].hasKey("id")
    check wire["components"][12]["id"].getInt() == 23

  test "accepts explicit zero IDs but rejects duplicate nonzero IDs":
    let zero = some(toComponentId(0))
    let zeros = v2Draft(
      textDisplay("first", id = zero),
      separator(id = zero)
    )
    check zeros.validate().valid
    let wire = zeros.toJson()
    check wire["components"][0]["id"].getInt() == 0
    check wire["components"][1]["id"].getInt() == 0

    let repeated = some(toComponentId(42))
    let duplicate = v2Draft(
      container(repeated, textDisplay("nested", id = repeated))
    )
    let validation = duplicate.validate()
    check not validation.valid
    check validation.problems.anyIt(it.kind == cpkDuplicateId)

  test "enforces root and container item limits":
    var roots: seq[ComponentNode]
    for index in 0..<MaxMessageRootComponents:
      roots.add textDisplay("root " & $index)
    var draft = MessageDraft[V2](v2: V2Payload(children: roots))
    check draft.validate().valid
    draft.v2.children.add textDisplay("root overflow")
    check draft.validate().problems.anyIt(it.kind == cpkTooManyComponents)

    var children: seq[ComponentNode]
    for index in 0..MaxContainerComponents:
      children.add textDisplay("child " & $index)
    let oversizedContainer = v2Draft(component(
      mckContainer,
      children = children
    ))
    check oversizedContainer.validate().problems.anyIt(
      it.kind == cpkTooManyComponents and it.path == "0"
    )
