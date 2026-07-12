## Representative Discord interaction and Gateway payload builders for tests.
##
## Each builder returns a valid, wire-shaped `JsonNode` that mirrors Discord's
## documented structure, so tests can drive interaction and Gateway code without
## hand-writing large literals. Every builder accepts an `overrides` object that
## is deep-merged over the produced payload, letting a test change one nested
## field while keeping the rest of the representative shape intact.

import std/json

proc mergeJson*(base, override: JsonNode): JsonNode =
  ## Returns `base` deep-merged with `override`; `override` wins on conflicts.
  ##
  ## Two objects merge key by key and recurse into nested objects. For any other
  ## kind, including arrays, `override` replaces `base` wholesale because there
  ## is no position-independent way to merge Discord arrays.
  if override.isNil:
    return base.copy()
  if base.isNil or base.kind != JObject or override.kind != JObject:
    return override.copy()
  result = base.copy()
  for key, value in override:
    if result.hasKey(key):
      result[key] = mergeJson(result[key], value)
    else:
      result[key] = value.copy()

proc applyOverrides(base: JsonNode, overrides: JsonNode): JsonNode =
  if overrides.isNil:
    base
  else:
    mergeJson(base, overrides)

proc userFixture*(overrides: JsonNode = nil): JsonNode =
  ## Returns a representative Discord user object.
  applyOverrides(%*{
    "id": "80351110224678912",
    "username": "cordnim_tester",
    "discriminator": "0",
    "global_name": "Cordnim Tester",
    "avatar": nil,
    "bot": false,
  }, overrides)

proc slashCommandInteraction*(name = "ping",
                              options: JsonNode = nil,
                              overrides: JsonNode = nil): JsonNode =
  ## Returns an `APPLICATION_COMMAND` (type 2) interaction payload.
  ##
  ## `options` replaces the command option array when supplied; `overrides` is
  ## then deep-merged over the whole interaction for targeted edits.
  let optionArray = if options.isNil: newJArray() else: options.copy()
  let base = %*{
    "id": "846462639632127520",
    "application_id": "234325234325234325",
    "type": 2,
    "token": "aW50ZXJhY3Rpb24tdG9rZW4tc2VjcmV0",
    "version": 1,
    "guild_id": "290926798626357999",
    "channel_id": "645027906669510667",
    "app_permissions": "562949953421311",
    "locale": "en-US",
    "member": {
      "user": userFixture(),
      "roles": [],
      "permissions": "562949953421311",
    },
    "data": {
      "id": "771825006014889984",
      "name": name,
      "type": 1,
      "options": optionArray,
    },
  }
  applyOverrides(base, overrides)

proc componentInteraction*(customId = "click_me",
                           componentType = 2,
                           overrides: JsonNode = nil): JsonNode =
  ## Returns a `MESSAGE_COMPONENT` (type 3) interaction payload.
  ##
  ## `componentType` follows Discord's component-type ids: 2 for a button and 3
  ## for a select menu.
  let base = %*{
    "id": "846462639632127521",
    "application_id": "234325234325234325",
    "type": 3,
    "token": "aW50ZXJhY3Rpb24tdG9rZW4tY29tcG9uZW50",
    "version": 1,
    "guild_id": "290926798626357999",
    "channel_id": "645027906669510667",
    "app_permissions": "562949953421311",
    "member": {
      "user": userFixture(),
      "roles": [],
      "permissions": "562949953421311",
    },
    "message": {
      "id": "917251507530338334",
      "channel_id": "645027906669510667",
      "type": 0,
      "content": "press the button",
    },
    "data": {
      "custom_id": customId,
      "component_type": componentType,
    },
  }
  applyOverrides(base, overrides)

proc modalSubmitInteraction*(customId = "feedback_modal",
                             fieldId = "feedback_field",
                             value = "great library",
                             overrides: JsonNode = nil): JsonNode =
  ## Returns a `MODAL_SUBMIT` (type 5) interaction payload.
  ##
  ## The single text input echoes `fieldId`/`value`; use `overrides` to add more
  ## action rows or components.
  let base = %*{
    "id": "846462639632127522",
    "application_id": "234325234325234325",
    "type": 5,
    "token": "aW50ZXJhY3Rpb24tdG9rZW4tbW9kYWw",
    "version": 1,
    "guild_id": "290926798626357999",
    "channel_id": "645027906669510667",
    "member": {
      "user": userFixture(),
      "roles": [],
      "permissions": "562949953421311",
    },
    "data": {
      "custom_id": customId,
      "components": [{
        "type": 1,
        "components": [{
          "type": 4,
          "custom_id": fieldId,
          "value": value,
        }],
      }],
    },
  }
  applyOverrides(base, overrides)

proc dispatchEnvelope*(eventName: string, data: JsonNode,
                       sequence = 1,
                       overrides: JsonNode = nil): JsonNode =
  ## Returns a raw opcode-0 dispatch envelope `{op, s, t, d}`.
  ##
  ## This is the general form behind the named dispatch builders and the entry
  ## point for representing a future or unknown event with arbitrary `data`.
  let base = %*{
    "op": 0,
    "s": sequence,
    "t": eventName,
    "d": (if data.isNil: newJNull() else: data.copy()),
  }
  applyOverrides(base, overrides)

proc readyDispatch*(sequence = 1, overrides: JsonNode = nil): JsonNode =
  ## Returns a representative `READY` dispatch envelope.
  dispatchEnvelope("READY", %*{
    "v": 10,
    "user": userFixture(%*{"bot": true}),
    "session_id": "8a1b2c3d4e5f60718293a4b5c6d7e8f9",
    "resume_gateway_url": "wss://gateway.discord.gg",
    "guilds": [{"id": "290926798626357999", "unavailable": true}],
    "application": {"id": "234325234325234325", "flags": 0},
  }, sequence, overrides)

proc messageCreateDispatch*(content = "hello from a fixture",
                            sequence = 2,
                            overrides: JsonNode = nil): JsonNode =
  ## Returns a representative `MESSAGE_CREATE` dispatch envelope.
  dispatchEnvelope("MESSAGE_CREATE", %*{
    "id": "917251507530338334",
    "channel_id": "645027906669510667",
    "guild_id": "290926798626357999",
    "author": userFixture(),
    "content": content,
    "timestamp": "2026-07-12T00:00:00.000000+00:00",
    "edited_timestamp": nil,
    "type": 0,
    "tts": false,
    "pinned": false,
    "mention_everyone": false,
    "mentions": [],
    "mention_roles": [],
    "attachments": [],
    "embeds": [],
    "components": [],
    "flags": 0,
  }, sequence, overrides)

proc guildCreateDispatch*(sequence = 3, overrides: JsonNode = nil): JsonNode =
  ## Returns a representative `GUILD_CREATE` dispatch envelope.
  dispatchEnvelope("GUILD_CREATE", %*{
    "id": "290926798626357999",
    "name": "Cordnim Test Guild",
    "owner_id": "80351110224678912",
    "member_count": 2,
    "unavailable": false,
    "channels": [{
      "id": "645027906669510667",
      "type": 0,
      "name": "general",
    }],
    "roles": [{
      "id": "290926798626357999",
      "name": "@everyone",
      "color": 0,
      "hoist": false,
      "position": 0,
      "permissions": "104324161",
      "managed": false,
      "mentionable": false,
      "flags": 0,
    }],
  }, sequence, overrides)

proc unknownDispatch*(eventName = "CORDNIM_FUTURE_EVENT",
                      sequence = 4,
                      overrides: JsonNode = nil): JsonNode =
  ## Returns a dispatch envelope for an event this version does not model.
  ##
  ## It exercises forward-compatible decoders that must retain an unrecognized
  ## `t` and its raw `d` without failing.
  dispatchEnvelope(eventName, %*{
    "unknown_field": "retained verbatim",
    "nested": {"value": 42},
  }, sequence, overrides)

proc toWireText*(node: JsonNode): string =
  ## Serializes a fixture payload to the compact wire text Discord sends.
  $node
