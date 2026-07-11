import std/[assertions, json, options]

import cordnim/raw/[model, models, schema_info]

block generated_schema_inventory:
  doAssert schemaNames.len == discordSchemaCount
  doAssert discordSchemaCount == 538
  doAssert preservesUnknownObjectFields
  doAssert preservesUnknownEnumValues
  doAssert preservesUnknownFlagBits

block lossless_unknown_field_round_trip:
  let payload = parseJson("""{
    "id": "123",
    "name": "example",
    "future_discord_field": {"enabled": true}
  }""")
  let application = decodeModel(ApplicationResponse, payload)
  let encoded = application.toJson
  doAssert encoded["id"].getStr == "123"
  doAssert encoded["future_discord_field"]["enabled"].getBool

  let unknown = unknownFields(encoded, ["id", "name"])
  doAssert unknown.len == 1
  doAssert unknown[0].name == "future_discord_field"

block open_enum_retains_unknown_wire_value:
  let value = initRawEnumValue(9001)
  doAssert not value.isKnown([1, 2, 3])
  doAssert value.knownValue([1, 2, 3]).isNone
  doAssert value.raw == 9001

block nil_model_is_rejected:
  doAssertRaises RawModelError:
    discard decodeModel(ApplicationResponse, nil)
