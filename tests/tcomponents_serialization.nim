import std/[json, options, unittest]

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
    check wire["components"][0]["components"][1]["accessory"]["type"].getInt() == 11

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
    check wire["components"][1]["components"][0]["default_values"][0]["type"].getStr() == "channel"
    check wire["components"][1]["components"][0]["channel_types"].len == 2
    check wire["components"][2]["items"][0]["description"].getStr() == "Architecture"
    check wire["components"][3]["spoiler"].getBool()
    check wire["components"][4]["spacing"].getInt() == 2
    check not wire["components"][4]["divider"].getBool()
    check wire["components"][5]["accent_color"].getInt() == 0x58_65_f2
