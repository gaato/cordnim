import std/[assertions, json, options, os, strutils]

import ../tools/schema_codegen as schemaCodegen
import cordnim/raw/[models, schema_info, semantics]

const projectDir = currentSourcePath().parentDir().parentDir()

proc overlayConstraints(): JsonNode =
  parseJson("""{
    "preserveUnknownObjectFields": true,
    "preserveUnknownEnumValues": true,
    "preserveUnknownFlagBits": true,
    "treatOptionalAndNullableSeparately": true,
    "componentsV2Irreversible": true,
    "maximumMessageComponents": 40,
    "legacyAndV2MessageFieldsExclusive": true
  }""")

proc overlayRule(
    target, semantic, representation: string
): JsonNode =
  result = newJObject()
  result["target"] = newJString(target)
  result["semantic"] = newJString(semantic)
  result["representation"] = newJString(representation)
  result["reason"] = newJString("fixture reason")

proc overlayRule(
    targets: openArray[string]; semantic, representation: string
): JsonNode =
  result = overlayRule("placeholder", semantic, representation)
  result["target"] = newJArray()
  for target in targets:
    result["target"].add newJString(target)

proc semanticOverlay(rules: openArray[JsonNode]): JsonNode =
  result = newJObject()
  result["revision"] = newJInt(1)
  result["description"] = newJString("fixture overlay")
  result["rules"] = newJArray()
  for rule in rules:
    result["rules"].add rule
  result["constraints"] = overlayConstraints()

let fixtureSpec = parseJson("""{
  "components": {
    "schemas": {
      "Foo": {
        "type": "object",
        "properties": {
          "kind": {"enum": [1, 2]},
          "allow": {"type": "string"},
          "deny": {"type": "string"}
        }
      }
    }
  }
}""")

block liveOverlayRulesAreAllApplied:
  let spec = parseFile(
    projectDir / "schemas" / "discord-api-spec" / "openapi.json"
  )
  let overlay = parseFile(projectDir / "schemas" / "semantic-overlay.json")
  let plan = schemaCodegen.applySemanticOverlay(spec, overlay)

  doAssert plan.rules.len == discordOverlayRuleCount
  doAssert plan.descriptors.len == discordOverlayDescriptorCount
  doAssert semanticRules.len == discordOverlayRuleCount
  doAssert semanticDescriptors.len == discordOverlayDescriptorCount
  doAssert discordOverlayRuleCount == 10
  doAssert discordOverlayDescriptorCount == 231
  doAssert discordOverlayRuleMatchCounts == [
    1, 12, 3, 8, 16, 157, 6, 1, 14, 13,
  ]
  for index, rule in plan.rules:
    doAssert rule.matchCount > 0
    doAssert rule.matchCount == discordOverlayRuleMatchCounts[index]
    doAssert rule.matchCount == semanticRules[index].matchCount

  for index in 1..<plan.descriptors.len:
    doAssert plan.descriptors[index - 1].jsonPointer <
      plan.descriptors[index].jsonPointer

block generatedSchemaAndPropertyLookup:
  let snowflake = findSemanticDescriptor(
    "#/components/schemas/SnowflakeType"
  )
  doAssert snowflake.isSome
  doAssert snowflake.get.semantic == SemanticKind.Snowflake
  doAssert snowflake.get.schemaName == "SnowflakeType"
  doAssert snowflake.get.propertyName == ""

  let permissions = semanticDescriptorsForProperty(
    "ApplicationOAuth2InstallParams", "permissions"
  )
  doAssert permissions.len == 1
  doAssert permissions[0].semantic == SemanticKind.ExtensibleBits

  let actionRows = semanticDescriptorsForSchema(
    "ActionRowComponentForMessageRequest"
  )
  doAssert actionRows.len == 2
  doAssert actionRows[0].schemaName ==
    "ActionRowComponentForMessageRequest"

  for invalidPointer in [
    "#/components/schemas/CommandPermissionsResponse/properties/permissions",
    "#/components/schemas/TeamMemberResponse/properties/permissions",
    "#/paths/~1applications~1{application_id}~1guilds~1{guild_id}~1commands" &
      "~1{command_id}~1permissions/put/requestBody/content/application~1json" &
      "/schema/properties/permissions",
    "#/paths/~1guilds~1{guild_id}~1requests/get/parameters/0/schema/enum",
    "#/paths/~1guilds~1{guild_id}~1requests~1{request_id}/patch/requestBody" &
      "/content/application~1json/schema/properties/action/enum",
  ]:
    doAssert findSemanticDescriptor(invalidPointer).isNone

block selectorAlternationMatchesBothBranches:
  let overlay = semanticOverlay([
    overlayRule(
      "**/properties/allow|**/properties/deny",
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  let plan = schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)
  doAssert plan.rules[0].matchCount == 2
  doAssert plan.descriptors[0].propertyName == "allow"
  doAssert plan.descriptors[1].propertyName == "deny"

block exactTargetArraysAreReviewableAlternatives:
  let overlay = semanticOverlay([
    overlayRule(
      [
        "#/components/schemas/Foo/properties/allow",
        "#/components/schemas/Foo/properties/deny",
      ],
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  let plan = schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)
  doAssert plan.rules[0].matchCount == 2
  doAssert plan.descriptors[0].propertyName == "allow"
  doAssert plan.descriptors[1].propertyName == "deny"

block duplicateSelectorsInsideTargetArrayAreRejected:
  let pointer = "#/components/schemas/Foo/properties/allow"
  let overlay = semanticOverlay([
    overlayRule(
      [pointer, pointer],
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  try:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)
    doAssert false, "duplicate target-array selectors must be rejected"
  except schemaCodegen.OverlayError as error:
    doAssert "repeats selector" in error.msg

block targetArrayOrderIsCanonicalForDuplicateDetection:
  let allowPointer = "#/components/schemas/Foo/properties/allow"
  let denyPointer = "#/components/schemas/Foo/properties/deny"
  let overlay = semanticOverlay([
    overlayRule(
      [allowPointer, denyPointer],
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
    overlayRule(
      [denyPointer, allowPointer],
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  try:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)
    doAssert false, "target-array order must not hide duplicate targets"
  except schemaCodegen.OverlayError as error:
    doAssert "duplicate overlay target" in error.msg

block expectedShapeTableCoversEverySemantic:
  for semantic in schemaCodegen.OverlaySemanticKind:
    doAssert schemaCodegen.semanticExpectedShapes[semantic].len > 0

block validScalarAndEnumShapesAreApplied:
  let bitsOverlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Foo/properties/allow",
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  let bitsPlan = schemaCodegen.applySemanticOverlay(
    fixtureSpec, bitsOverlay
  )
  doAssert bitsPlan.descriptors.len == 1

  let enumOverlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Foo/properties/kind/enum",
      "open-enum",
      "raw-value-plus-known-view",
    ),
  ])
  let enumPlan = schemaCodegen.applySemanticOverlay(
    fixtureSpec, enumOverlay
  )
  doAssert enumPlan.descriptors.len == 1

block extensibleBitsRejectsArrayValuedPermissions:
  let arraySpec = parseJson("""{
    "components": {
      "schemas": {
        "Foo": {
          "type": "object",
          "properties": {
            "permissions": {
              "type": "array",
              "items": {"type": "string"}
            }
          }
        }
      }
    }
  }""")
  let overlay = semanticOverlay([
    overlayRule(
      "**/properties/permissions",
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  try:
    discard schemaCodegen.applySemanticOverlay(arraySpec, overlay)
    doAssert false, "array-valued permissions must be rejected"
  except schemaCodegen.OverlayError as error:
    doAssert "**/properties/permissions" in error.msg
    doAssert "#/components/schemas/Foo/properties/permissions" in error.msg
    doAssert "expected an OpenAPI scalar schema" in error.msg

block snowflakeRejectsObjectSchema:
  let overlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Foo",
      "snowflake",
      "decimal-string-at-json-boundary",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block componentSemanticRequiresTypedDiscriminator:
  let overlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Foo",
      "legal-component-tree",
      "validated-parent-child-tree-max-40",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block componentsV2TransitionRequiresMessageFields:
  let overlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Foo",
      "irreversible-components-v2-transition",
      "separate-legacy-and-v2-types",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block openEnumRejectsScalarSchema:
  let overlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Foo/properties/allow",
      "open-enum",
      "raw-value-plus-known-view",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block openEnumRejectsEmptyEnumArray:
  let emptyEnumSpec = parseJson("""{
    "components": {
      "schemas": {
        "Foo": {
          "type": "object",
          "properties": {"kind": {"enum": []}}
        }
      }
    }
  }""")
  let overlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Foo/properties/kind/enum",
      "open-enum",
      "raw-value-plus-known-view",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(emptyEnumSpec, overlay)

block generationInputsAreOrderIndependent:
  let reorderedSpec = parseJson("""{
    "components": {
      "schemas": {
        "Foo": {
          "properties": {
            "deny": {"type": "string"},
            "kind": {"enum": [1, 2]},
            "allow": {"type": "string"}
          },
          "type": "object"
        }
      }
    }
  }""")
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
  ])
  let first = schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)
  let second = schemaCodegen.applySemanticOverlay(reorderedSpec, overlay)
  doAssert first.rules[0].matchCount == second.rules[0].matchCount
  doAssert first.descriptors.len == second.descriptors.len
  for index in 0..<first.descriptors.len:
    doAssert first.descriptors[index].jsonPointer ==
      second.descriptors[index].jsonPointer

block overlayMetadataFlowsIntoAppliedDescriptors:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
  ])
  overlay["rules"][0]["reason"] = newJString("changed fixture reason")
  let plan = schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)
  doAssert plan.rules[0].reason == "changed fixture reason"
  doAssert plan.descriptors[0].reason == "changed fixture reason"

block unknownSemanticIsRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "closed-enum", "raw-value-plus-known-view"),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block unknownRepresentationIsRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "invented-representation"),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block unknownRuleFieldIsRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
  ])
  overlay["rules"][0]["semantics"] = newJString("open-enum")
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block mistypedConstraintIsRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
  ])
  overlay["constraints"]["preserveUnknownEnumValues"] = newJString("true")
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block falseImplementationInvariantsAreRejected:
  const invariantNames = [
    "preserveUnknownObjectFields",
    "preserveUnknownEnumValues",
    "preserveUnknownFlagBits",
    "treatOptionalAndNullableSeparately",
    "componentsV2Irreversible",
    "legacyAndV2MessageFieldsExclusive",
  ]
  for invariantName in invariantNames:
    let overlay = semanticOverlay([
      overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
    ])
    overlay["constraints"][invariantName] = newJBool(false)
    doAssertRaises schemaCodegen.OverlayError:
      discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block mismatchedComponentLimitIsRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
  ])
  overlay["constraints"]["maximumMessageComponents"] = newJInt(41)
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block incompatibleSemanticPairIsRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "one-of"),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block malformedSelectorIsRejected:
  let overlay = semanticOverlay([
    overlayRule(
      "components/schemas/Foo", "open-enum", "raw-value-plus-known-view"
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block zeroMatchIsRejected:
  let overlay = semanticOverlay([
    overlayRule(
      "#/components/schemas/Missing",
      "snowflake",
      "decimal-string-at-json-boundary",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block zeroMatchAlternativeIsRejected:
  let overlay = semanticOverlay([
    overlayRule(
      "**/properties/allow|**/properties/missing",
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block overlappingAlternativesAreRejected:
  let overlay = semanticOverlay([
    overlayRule(
      "**/enum|#/components/schemas/Foo/properties/kind/enum",
      "open-enum",
      "raw-value-plus-known-view",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block duplicateSemanticMatchesAreRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
    overlayRule(
      "#/components/schemas/Foo/properties/kind/enum",
      "open-enum",
      "raw-value-plus-known-view",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block duplicateTargetsAreRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block conflictingSemanticMatchesAreRejected:
  let overlay = semanticOverlay([
    overlayRule("**/enum", "open-enum", "raw-value-plus-known-view"),
    overlayRule(
      "#/components/schemas/Foo/properties/kind/enum",
      "extensible-bits",
      "decimal-string-arbitrary-width",
    ),
  ])
  doAssertRaises schemaCodegen.OverlayError:
    discard schemaCodegen.applySemanticOverlay(fixtureSpec, overlay)

block generatedHeaderOrphansAreDetectedWithoutClaimingManualFiles:
  let root = getTempDir() / "cordnim-schema-orphan-fixture"
  removeDir(root)
  defer:
    removeDir(root)

  let modelDir = root / "src" / "cordnim" / "raw" / "models"
  let schemaDir = root / "schemas"
  createDir(modelDir)
  createDir(schemaDir)
  let expectedPath = modelDir / "expected.nim"
  let orphanPath = modelDir / "orphan.nim"
  let manualPath = modelDir / "manual.nim"
  let schemaOrphanPath = schemaDir / "orphan.tsv"
  writeFile(
    expectedPath,
    "## expected\n\n" & schemaCodegen.generatedFileMarker & "\n",
  )
  writeFile(orphanPath, schemaCodegen.generatedFileMarker & "\n")
  writeFile(manualPath, "## Handwritten module.\n")
  writeFile(schemaOrphanPath, schemaCodegen.generatedFileMarker & "\n")

  let orphans = schemaCodegen.findGeneratedOrphans(
    root, ["src/cordnim/raw/models/expected.nim"]
  )
  doAssert orphans == @[
    "schemas/orphan.tsv",
    "src/cordnim/raw/models/orphan.nim",
  ]
