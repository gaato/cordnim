## Option-focused autocomplete decode, encode, and dispatch tests.

import std/[json, options, strutils, unittest]
import chronos

import cordnim/commands
import cordnim/core/ids

type AcServices = object
  prefix: string

const flatInteraction = """{
  "type": 4,
  "locale": "ja",
  "guild_locale": "en-US",
  "guild_id": "7",
  "member": {"user": {"id": "42"}},
  "data": {
    "id": "1", "name": "search", "type": 1,
    "options": [
      {"type": 3, "name": "category", "value": "games"},
      {"type": 3, "name": "query", "value": "zel", "focused": true}
    ]
  }
}"""

suite "autocomplete decode":
  test "isolates the focused option and preserves locales":
    let request = decodeAutocomplete(parseJson(flatInteraction))
    check request.command == initCommandKey(ckChatInput, "search")
    check request.userId == toId(UserId, 42)
    check request.guildId == some(toId(GuildId, 7))
    check request.locale == some(dlJapanese)
    check request.guildLocale == some(dlEnglishUs)
    check request.focusedName == "query"
    check request.focusedKind == some(cokString)
    check request.focusedText == "zel"
    check request.options["category"].getStr() == "games"
    check request.options["query"].getStr() == "zel"
    check request.subcommand.isNone

  test "walks a top-level subcommand path":
    let request = decodeAutocomplete(%*{
      "type": 4, "member": {"user": {"id": "1"}},
      "data": {"name": "config", "type": 1, "options": [
        {"type": 1, "name": "set", "options": [
          {"type": 3, "name": "key", "value": "col", "focused": true}
        ]}
      ]}
    })
    check request.subcommand.isSome
    check request.subcommand.get().group.isNone
    check request.subcommand.get().name == "set"
    check request.focusedName == "key"
    check request.focusedText == "col"

  test "walks a subcommand group path":
    let request = decodeAutocomplete(%*{
      "type": 4, "member": {"user": {"id": "1"}},
      "data": {"name": "config", "type": 1, "options": [
        {"type": 2, "name": "role", "options": [
          {"type": 1, "name": "add", "options": [
            {"type": 3, "name": "name", "value": "ad", "focused": true}
          ]}
        ]}
      ]}
    })
    check request.subcommand.get().group == some("role")
    check request.subcommand.get().name == "add"
    check request.focusedName == "name"
    check request.focusedText == "ad"

  test "rejects a non-autocomplete interaction":
    expect CommandDecodeError:
      discard decodeAutocomplete(%*{
        "type": 2, "data": {"name": "x", "type": 1}
      })

suite "autocomplete response encoding":
  test "encodes a type-8 response with typed values":
    let response = autocompleteResponse(@[
      initAutocompleteChoice("Alpha", "a"),
      initAutocompleteChoice("One", 1'i64),
      initAutocompleteChoice("Pi", 3.5)
    ])
    check response["type"].getInt() == 8
    check response["data"]["choices"].len == 3
    check response["data"]["choices"][0]["value"].getStr() == "a"
    check response["data"]["choices"][1]["value"].getInt() == 1
    check response["data"]["choices"][2]["value"].getFloat() == 3.5

  test "serializes localized choice names":
    let choice = initAutocompleteChoice("happy", "happy",
      nameLocalizations = initLocalizationMap({dlJapanese: "嬉しい"}))
    check choice.toJson()["name_localizations"]["ja"].getStr() == "嬉しい"

  test "rejects more than 25 choices":
    var many: seq[AutocompleteChoice]
    for index in 0..25:
      many.add(initAutocompleteChoice("name" & $index, "value"))
    expect CommandSpecError:
      discard autocompleteResponse(many)

suite "autocomplete registry":
  test "dispatches to a focused-option handler":
    var registry = initAutocompleteRegistry[AcServices]()
    let handler: AutocompleteHandler[AcServices] = proc(
        services: ref AcServices,
        request: AutocompleteRequest):
        Future[seq[AutocompleteChoice]] {.async.} =
      return @[initAutocompleteChoice(
        services.prefix & request.focusedText, "v")]
    registry.register(initCommandKey(ckChatInput, "search"), "query", handler)
    check registry.len == 1
    check registry.contains(initCommandKey(ckChatInput, "search"), "query")

    expect CommandSpecError:
      registry.register(
        initCommandKey(ckChatInput, "search"), "query", handler)

    var services: ref AcServices
    new(services)
    services.prefix = "p:"
    let request = decodeAutocomplete(parseJson(flatInteraction))
    let choices = waitFor registry.dispatch(services, request)
    check choices.len == 1
    check choices[0].name == "p:zel"

  test "returns no suggestions when no handler matches":
    let registry = initAutocompleteRegistry[AcServices]()
    var services: ref AcServices
    new(services)
    let request = decodeAutocomplete(parseJson(flatInteraction))
    let choices = waitFor registry.dispatch(services, request)
    check choices.len == 0

  test "rejects a nil handler":
    var registry = initAutocompleteRegistry[AcServices]()
    expect CommandSpecError:
      registry.register(initCommandKey(ckChatInput, "search"), "query", nil)

proc pathInteraction(subcommand: string): JsonNode =
  %*{
    "type": 4, "member": {"user": {"id": "1"}},
    "data": {"name": "config", "type": 1, "options": [
      {"type": 1, "name": subcommand, "options": [
        {"type": 3, "name": "key", "value": "c", "focused": true}
      ]}
    ]}
  }

suite "autocomplete path-keyed registry":
  test "routes the same option name by subcommand path":
    var registry = initAutocompleteRegistry[AcServices]()
    let setHandler: AutocompleteHandler[AcServices] = proc(
        services: ref AcServices, request: AutocompleteRequest):
        Future[seq[AutocompleteChoice]] {.async.} =
      return @[initAutocompleteChoice("set", "v")]
    let showHandler: AutocompleteHandler[AcServices] = proc(
        services: ref AcServices, request: AutocompleteRequest):
        Future[seq[AutocompleteChoice]] {.async.} =
      return @[initAutocompleteChoice("show", "v")]
    let command = initCommandKey(ckChatInput, "config")
    registry.register(command, "key", setHandler, subcommand = some("set"))
    registry.register(command, "key", showHandler, subcommand = some("show"))
    check registry.len == 2

    var services: ref AcServices
    new(services)
    let setChoices = waitFor registry.dispatch(
      services, decodeAutocomplete(pathInteraction("set")))
    check setChoices[0].name == "set"
    let showChoices = waitFor registry.dispatch(
      services, decodeAutocomplete(pathInteraction("show")))
    check showChoices[0].name == "show"

  test "a flat registration does not match a subcommand request":
    var registry = initAutocompleteRegistry[AcServices]()
    let handler: AutocompleteHandler[AcServices] = proc(
        services: ref AcServices, request: AutocompleteRequest):
        Future[seq[AutocompleteChoice]] {.async.} =
      return @[initAutocompleteChoice("flat", "v")]
    registry.register(initCommandKey(ckChatInput, "config"), "key", handler)
    var services: ref AcServices
    new(services)
    let choices = waitFor registry.dispatch(
      services, decodeAutocomplete(pathInteraction("set")))
    check choices.len == 0

suite "autocomplete strict decoding":
  test "requires exactly one focused option":
    expect CommandDecodeError:
      discard decodeAutocomplete(%*{
        "type": 4, "member": {"user": {"id": "1"}},
        "data": {"name": "search", "type": 1, "options": [
          {"type": 3, "name": "query", "value": "z"}
        ]}
      })
    expect CommandDecodeError:
      discard decodeAutocomplete(%*{
        "type": 4, "member": {"user": {"id": "1"}},
        "data": {"name": "search", "type": 1, "options": [
          {"type": 3, "name": "a", "value": "x", "focused": true},
          {"type": 3, "name": "b", "value": "y", "focused": true}
        ]}
      })

suite "autocomplete response limits":
  test "rejects oversized names, values, and non-finite numbers":
    expect CommandSpecError:
      discard autocompleteResponse(@[
        initAutocompleteChoice(repeat('a', 101), "v")])
    expect CommandSpecError:
      discard autocompleteResponse(@[
        initAutocompleteChoice("name", repeat('a', 101))])
    expect CommandSpecError:
      discard autocompleteResponse(@[
        initAutocompleteChoice("name", 9007199254740992'i64)])
    expect CommandSpecError:
      discard autocompleteResponse(@[
        initAutocompleteChoice("name", NaN)])
    expect CommandSpecError:
      discard autocompleteResponse(@[
        initAutocompleteChoice("name", 1e300)]) # number beyond 2^53
    let longLoc = initLocalizationMap({dlJapanese: repeat("あ", 101)})
    expect CommandSpecError:
      discard autocompleteResponse(@[
        initAutocompleteChoice("name", "v", nameLocalizations = longLoc)])

func requestWith(kind: Option[CommandOptionKind]): AutocompleteRequest =
  AutocompleteRequest(
    command: initCommandKey(ckChatInput, "search"),
    focusedName: "query", focusedKind: kind,
    options: newJObject(), focusedValue: newJNull())

suite "autocomplete response value kind":
  test "choice kinds must match the focused option kind":
    check autocompleteResponse(requestWith(some(cokString)),
      @[initAutocompleteChoice("a", "v")])["type"].getInt() == 8
    check autocompleteResponse(requestWith(some(cokInteger)),
      @[initAutocompleteChoice("a", 1'i64)])["data"]["choices"].len == 1
    check autocompleteResponse(requestWith(some(cokNumber)),
      @[initAutocompleteChoice("a", 1.5)])["data"]["choices"].len == 1

  test "mismatched, missing, or unsupported focused kinds are rejected":
    expect CommandSpecError: # STRING focus, integer choice
      discard autocompleteResponse(requestWith(some(cokString)),
        @[initAutocompleteChoice("a", 1'i64)])
    expect CommandSpecError: # no focused kind decoded
      discard autocompleteResponse(requestWith(none(CommandOptionKind)),
        @[initAutocompleteChoice("a", "v")])
    expect CommandSpecError: # BOOLEAN cannot autocomplete
      discard autocompleteResponse(requestWith(some(cokBoolean)),
        @[initAutocompleteChoice("a", "v")])

suite "autocomplete decode is defect-free on malformed input":
  test "malformed payloads raise CommandDecodeError, never crash":
    let malformed = @[
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1}},                       # no options
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": 5}},          # options int
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [
           {"type": 1, "options": [
             {"type": 3, "name": "k", "value": "c", "focused": true}
           ]}]}},                                                  # sub no name
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [
           {"type": 2, "name": "g", "options": []}]}},             # empty group
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [
           {"type": 2, "name": "g", "options": [
             {"type": 1, "name": "s"}]}]}},                        # sub no opts
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [
           {"type": 3, "name": "q", "value": "z"}]}}               # none focused
    ]
    for payload in malformed:
      expect CommandDecodeError:
        discard decodeAutocomplete(payload)

suite "autocomplete decode tolerates malformed array entries":
  test "null and non-object option entries never crash":
    let payloads = @[
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [newJNull()]}},
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [5, "s"]}},
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [
           {"type": 3}]}},                                   # leaf, no name
      %*{"type": 4, "member": {"user": {"id": "1"}},
         "data": {"name": "x", "type": 1, "options": [
           {"type": 2, "name": "g", "options": [newJNull()]}]}}
    ]
    for payload in payloads:
      expect CommandDecodeError:
        discard decodeAutocomplete(payload)
