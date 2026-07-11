import std/[assertions, json, options]

import cordnim/components/forms
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

  DeployForm {.discordModal(
    title = "Deploy",
    customId = "deploy_form_v1"
  ).} = object
    summary {.textInput(
      label = "Summary",
      minLength = 3,
      maxLength = 100
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

deriveDiscordModal(DeployForm)
deriveDiscordModal(FeedbackForm)

func containsProblem[T](decoded: ModalDecodeResult[T];
                        kind: ModalDecodeProblemKind): bool =
  for problem in decoded.problems:
    if problem.kind == kind:
      return true

block derived_schema:
  let spec = modalSpec(DeployForm)
  doAssert spec.customId == "deploy_form_v1"
  doAssert spec.title == "Deploy"
  doAssert spec.fields.len == 10
  doAssert spec.fields[0].customId == "summary"
  doAssert spec.fields[1].options.len == 2
  doAssert spec.fields[5].channelTypes == {ModalChannelType.GuildText}
  doAssert spec.validate().len == 0

  let wire = spec.toJson()
  doAssert wire["components"].len == 10
  doAssert wire["components"][0]["type"].getInt() == 18
  doAssert wire["components"][0]["component"]["type"].getInt() == 4
  doAssert wire["components"][6]["component"]["type"].getInt() == 19
  doAssert modalCustomId(FeedbackForm) == "feedback_form"

block decode_submission:
  let payload = %*{
    "custom_id": "deploy_form_v1",
    "resolved": {
      "users": {
        "100": {"id": "100", "username": "reviewer"},
        "102": {"id": "102", "username": "notify"}
      },
      "roles": {
        "101": {"id": "101", "name": "release"}
      },
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
      }},
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

  attachmentDecodeCalls = 0
  resolvedObservations = default(array[ModalResolvedKind, int])
  let decoded = decodeDiscordModal(DeployForm, payload,
    ModalDecodeHooks(
      attachmentDecoder: trackedAttachment,
      observeResolved: observeResolved
    ))
  doAssert decoded.ok, $decoded.problems
  doAssert decoded.value.summary == "Ship it"
  doAssert decoded.value.environment == staging
  doAssert decoded.value.reviewers == @[UserId.parseId("100")]
  doAssert decoded.value.role == RoleId.parseId("101")
  doAssert decoded.value.mentionable.isSome
  doAssert decoded.value.mentionable.get().kind == MentionableKind.User
  doAssert decoded.value.destination == ChannelId.parseId("103")
  doAssert decoded.value.evidence.len == 1
  doAssert decoded.value.evidence[0].filename == "tracked-report.txt"
  doAssert decoded.value.evidence[0].raw["future_field"].getBool()
  doAssert attachmentDecodeCalls == 1
  doAssert resolvedObservations[ModalResolvedKind.Attachment] == 1
  doAssert resolvedObservations[ModalResolvedKind.User] == 2
  doAssert resolvedObservations[ModalResolvedKind.Role] == 1
  doAssert resolvedObservations[ModalResolvedKind.Channel] == 1
  doAssert decoded.value.strategy == blueGreen
  doAssert decoded.value.checks == {lint, unitTests}
  doAssert decoded.value.approval

block reject_wrong_modal_and_invalid_values:
  let payload = %*{
    "custom_id": "another_modal",
    "components": [
      {"type": 18, "component": {
        "type": 4, "custom_id": "summary", "value": "x"
      }}
    ]
  }
  let decoded = decodeDiscordModal(DeployForm, payload)
  doAssert not decoded.ok
  doAssert decoded.problems[0].kind == ModalDecodeProblemKind.WrongModal
  doAssert decoded.containsProblem(ModalDecodeProblemKind.TextTooShort)
  doAssert decoded.containsProblem(ModalDecodeProblemKind.MissingField)
