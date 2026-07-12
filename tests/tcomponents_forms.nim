import std/[assertions, json, options, strutils]

import cordnim/components/forms
import cordnim/components/model
import cordnim/core/ids

var attachmentDecodeCalls {.threadvar.}: int
var resolvedObservations {.threadvar.}: array[ModalResolvedKind, int]

proc trackedAttachment(id: string; raw: JsonNode): ModalAttachment
    {.gcsafe, raises: [ValueError].} =
  inc attachmentDecodeCalls
  result = parseModalAttachment(id, raw)
  result.filename = "tracked-" & result.filename

proc observeResolved(kind: ModalResolvedKind; id: string; raw: JsonNode)
    {.gcsafe, raises: [].} =
  discard id
  discard raw
  inc resolvedObservations[kind]

type
  Environment = enum
    staging
    production

  DeployStrategy = enum
    rolling
    blueGreen

  PreflightCheck = enum
    lint
    unitTests
    backup

  DeployContextForm {.discordModal(
    title = "Deploy context",
    customId = "deploy_context_v1"
  ).} = object
    summary {.textInput(
      label = "Summary",
      minLength = 3,
      maxLength = 100,
      value = "Existing summary"
    ).}: string
    environment {.stringSelect(
      label = "Environment"
    ).}: Environment
    reviewers {.userSelect(
      label = "Reviewers",
      required = false,
      minValues = 0,
      maxValues = 2
    ).}: seq[UserId]
    role {.roleSelect(
      label = "Release role"
    ).}: RoleId
    mentionable {.mentionableSelect(
      label = "Notify",
      required = false,
      minValues = 0
    ).}: Option[MentionableId]

  DeployExecutionForm {.discordModal(
    title = "Deploy execution",
    customId = "deploy_execution_v1"
  ).} = object
    destination {.channelSelect(
      label = "Destination",
      channelTypes = {ModalChannelType.GuildText}
    ).}: ChannelId
    evidence {.fileUpload(
      label = "Evidence",
      maxFiles = 3
    ).}: seq[ModalAttachment]
    strategy {.radioGroup(
      label = "Strategy"
    ).}: DeployStrategy
    checks {.checkboxGroup(
      label = "Preflight checks",
      maxValues = 3
    ).}: set[PreflightCheck]
    approval {.checkbox(
      label = "I understand the impact"
    ).}: bool

  FeedbackForm {.discordModal(title = "Feedback").} = object
    comment {.textInput(
      label = "Comment",
      required = false
    ).}: Option[string]

deriveDiscordModal(DeployContextForm)
deriveDiscordModal(DeployExecutionForm)
deriveDiscordModal(FeedbackForm)

func containsProblem[T](decoded: ModalDecodeResult[T];
                        kind: ModalDecodeProblemKind): bool =
  for problem in decoded.problems:
    if problem.kind == kind:
      return true

block derived_schema:
  let contextSpec = modalSpec(DeployContextForm)
  doAssert contextSpec.customId == "deploy_context_v1"
  doAssert contextSpec.title == "Deploy context"
  doAssert contextSpec.fields.len == 5
  doAssert contextSpec.fields[0].customId == "summary"
  doAssert contextSpec.fields[0].value.get() == "Existing summary"
  doAssert contextSpec.fields[1].options.len == 2
  doAssert contextSpec.validate().len == 0

  let contextWire = contextSpec.toJson()
  doAssert contextWire["components"].len == 5
  doAssert contextWire["components"][0]["type"].getInt() == 18
  doAssert contextWire["components"][0]["component"]["type"].getInt() == 4
  doAssert contextWire["components"][0]["component"]["value"].getStr() ==
    "Existing summary"

  let executionSpec = modalSpec(DeployExecutionForm)
  doAssert executionSpec.fields.len == 5
  doAssert executionSpec.fields[0].channelTypes ==
    {ModalChannelType.GuildText}
  doAssert executionSpec.validate().len == 0
  doAssert executionSpec.toJson()["components"][1]["component"][
    "type"].getInt() == 19
  doAssert modalCustomId(FeedbackForm) == "feedback_form"

block mixed_current_modal_components:
  var contextSpec = modalSpec(DeployContextForm)
  for index in 0..<contextSpec.items.len:
    contextSpec.items[index].id = some(toComponentId(uint32(100 + index)))
    contextSpec.items[index].field.componentId =
      some(toComponentId(uint32(200 + index)))

  contextSpec.items[1].field.options[0].selected = true
  contextSpec.items[2].field.defaultValues = @[
    defaultUser(toId(UserId, 1_001))
  ]
  contextSpec.items[3].field.defaultValues = @[
    defaultRole(toId(RoleId, 1_002))
  ]
  contextSpec.items[4].field.defaultValues = @[
    defaultRole(toId(RoleId, 1_003))
  ]

  var executionSpec = modalSpec(DeployExecutionForm)
  for index in 0..<executionSpec.items.len:
    executionSpec.items[index].id =
      some(toComponentId(uint32(300 + index)))
    executionSpec.items[index].field.componentId =
      some(toComponentId(uint32(400 + index)))
  executionSpec.items[0].field.defaultValues = @[
    defaultChannel(toId(ChannelId, 1_004))
  ]
  executionSpec.items[2].field.options[0].selected = true
  executionSpec.items[3].field.options[1].selected = true
  executionSpec.items[4].field.options[0].selected = true

  doAssert contextSpec.validate().len == 0, $contextSpec.validate()
  doAssert executionSpec.validate().len == 0, $executionSpec.validate()

  let contextWire = contextSpec.toJson()
  let executionWire = executionSpec.toJson()

  let expectedTypes = @[4, 3, 5, 6, 7, 8, 19, 21, 22, 23]
  var observedTypes: seq[int]
  for wire in [contextWire, executionWire]:
    for item in wire["components"]:
      observedTypes.add item["component"]["type"].getInt()
      doAssert item.hasKey("id")
      doAssert item["component"].hasKey("id")
  doAssert observedTypes == expectedTypes
  doAssert contextWire["components"][2]["component"]["default_values"][0][
    "type"].getStr() == "user"
  doAssert contextWire["components"][2]["component"]["default_values"][0][
    "id"].getStr() == "1001"
  doAssert contextWire["components"][1]["component"]["options"][0][
    "default"].getBool()
  doAssert contextWire["components"][3]["component"]["default_values"][0][
    "type"].getStr() == "role"
  doAssert contextWire["components"][4]["component"]["default_values"][0][
    "type"].getStr() == "role"
  doAssert executionWire["components"][0]["component"]["default_values"][0][
    "type"].getStr() == "channel"
  doAssert executionWire["components"][2]["component"]["options"][0][
    "default"].getBool()
  doAssert executionWire["components"][3]["component"]["options"][1][
    "default"].getBool()
  doAssert executionWire["components"][4]["component"]["default"].getBool()

  let displaySpec = initModalSpec("display", "Display", [
    modalTextDisplay("## Deployment context", some(toComponentId(500)))
  ])
  doAssert displaySpec.validate().len == 0
  doAssert displaySpec.toJson()["components"][0]["id"].getInt() == 500

block integer_component_id_rules:
  let zero = toComponentId(0)
  let zeros = initModalSpec("zero_ids", "Zero IDs", [
    modalTextDisplay("first", some(zero)),
    modalTextDisplay("second", some(zero))
  ])
  doAssert zeros.validate().len == 0
  let zeroWire = zeros.toJson()
  doAssert zeroWire["components"][0]["id"].getInt() == 0
  doAssert zeroWire["components"][1]["id"].getInt() == 0

  var duplicate = modalSpec(FeedbackForm)
  let duplicateId = some(toComponentId(77))
  duplicate.items[0].id = duplicateId
  duplicate.items[0].field.componentId = duplicateId
  var sawDuplicate = false
  for problem in duplicate.validate():
    if "duplicate nonzero component id" in problem:
      sawDuplicate = true
  doAssert sawDuplicate

block modal_root_item_limit:
  var items: seq[ModalItem]
  for index in 0..<MaxModalRootItems:
    items.add modalTextDisplay("item " & $index)
  var spec = initModalSpec("five_items", "Five Items", items)
  doAssert spec.validate().len == 0
  spec.addTextDisplay("one too many")
  doAssert spec.validate().len > 0

block decode_submission:
  let contextPayload = %*{
    "custom_id": "deploy_context_v1",
    "resolved": {
      "users": {
        "100": {"id": "100", "username": "reviewer"},
        "102": {"id": "102", "username": "notify"}
      },
      "roles": {
        "101": {"id": "101", "name": "release"}
      }
    },
    "components": [
      {"type": 18, "component": {
        "type": 4, "custom_id": "summary", "value": "Ship it"
      }},
      {"type": 18, "component": {
        "type": 3, "custom_id": "environment", "values": ["staging"]
      }},
      {"type": 18, "component": {
        "type": 5, "custom_id": "reviewers", "values": ["100"]
      }},
      {"type": 18, "component": {
        "type": 6, "custom_id": "role", "values": ["101"]
      }},
      {"type": 18, "component": {
        "type": 7, "custom_id": "mentionable", "values": ["102"]
      }}
    ]
  }
  let executionPayload = %*{
    "custom_id": "deploy_execution_v1",
    "resolved": {
      "channels": {
        "103": {"id": "103", "name": "deploys", "type": 0}
      },
      "attachments": {
        "104": {
          "id": "104",
          "filename": "report.txt",
          "size": 12,
          "url": "https://cdn.discordapp.com/report.txt",
          "proxy_url": "https://media.discordapp.net/report.txt",
          "content_type": "text/plain",
          "future_field": true
        }
      }
    },
    "components": [
      {"type": 18, "component": {
        "type": 8, "custom_id": "destination", "values": ["103"]
      }},
      {"type": 18, "component": {
        "type": 19, "custom_id": "evidence", "values": ["104"]
      }},
      {"type": 18, "component": {
        "type": 21, "custom_id": "strategy", "value": "blueGreen"
      }},
      {"type": 18, "component": {
        "type": 22, "custom_id": "checks",
        "values": ["lint", "unitTests"]
      }},
      {"type": 18, "component": {
        "type": 23, "custom_id": "approval", "value": true
      }}
    ]
  }
  let unknownPayload = %*{
    "custom_id": "feedback_form",
    "components": [
      {"type": 18, "component": {
        "type": 4, "custom_id": "comment", "value": "kept comment"
      }},
      {"type": 18, "component": {
        "type": 4, "custom_id": "future_field", "value": "kept",
        "future_metadata": {"version": 2}
      }}
    ]
  }

  attachmentDecodeCalls = 0
  resolvedObservations = default(array[ModalResolvedKind, int])
  let contextDecoded = decodeDiscordModal(DeployContextForm, contextPayload,
    ModalDecodeHooks(
      attachmentDecoder: trackedAttachment,
      observeResolved: observeResolved
    ))
  doAssert contextDecoded.ok, $contextDecoded.problems
  doAssert contextDecoded.value.summary == "Ship it"
  doAssert contextDecoded.value.environment == staging
  doAssert contextDecoded.value.reviewers == @[UserId.parseId("100")]
  doAssert contextDecoded.value.role == RoleId.parseId("101")
  doAssert contextDecoded.value.mentionable.isSome
  doAssert contextDecoded.value.mentionable.get().kind == MentionableKind.User

  let executionDecoded = decodeDiscordModal(DeployExecutionForm,
    executionPayload, ModalDecodeHooks(
      attachmentDecoder: trackedAttachment,
      observeResolved: observeResolved
    ))
  doAssert executionDecoded.ok, $executionDecoded.problems
  doAssert executionDecoded.value.destination == ChannelId.parseId("103")
  doAssert executionDecoded.value.evidence.len == 1
  doAssert executionDecoded.value.evidence[0].filename == "tracked-report.txt"
  doAssert executionDecoded.value.evidence[0].raw["future_field"].getBool()
  doAssert attachmentDecodeCalls == 1
  doAssert resolvedObservations[ModalResolvedKind.Attachment] == 1
  doAssert resolvedObservations[ModalResolvedKind.User] == 2
  doAssert resolvedObservations[ModalResolvedKind.Role] == 1
  doAssert resolvedObservations[ModalResolvedKind.Channel] == 1
  doAssert executionDecoded.value.strategy == blueGreen
  doAssert executionDecoded.value.checks == {lint, unitTests}
  doAssert executionDecoded.value.approval

  let unknownDecoded = decodeDiscordModal(FeedbackForm, unknownPayload)
  doAssert unknownDecoded.ok, $unknownDecoded.problems
  doAssert unknownDecoded.value.comment.get() == "kept comment"
  doAssert unknownDecoded.unknownFields.len == 1
  doAssert unknownDecoded.unknownFields[0].customId == "future_field"
  doAssert unknownDecoded.unknownFields[0].raw[
    "future_metadata"]["version"].getInt() == 2

block reject_wrong_modal_and_invalid_values:
  let payload = %*{
    "custom_id": "another_modal",
    "components": [
      {"type": 18, "component": {
        "type": 4, "custom_id": "summary", "value": "x"
      }}
    ]
  }
  let decoded = decodeDiscordModal(DeployContextForm, payload)
  doAssert not decoded.ok
  doAssert decoded.problems[0].kind == ModalDecodeProblemKind.WrongModal
  doAssert decoded.containsProblem(ModalDecodeProblemKind.TextTooShort)
  doAssert decoded.containsProblem(ModalDecodeProblemKind.MissingField)
