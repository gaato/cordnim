import std/[atomics, json, jsonutils, options, os, strutils, unittest]

import chronos

import cordnim/[commands, interactions]
import cordnim/interactions/autocomplete {.all.}
import cordnim/interactions/dispatch_core {.all.}
import cordnim/core/[errors, ids]
import cordnim/rest/[chronos_driver, request]

type Services = object

var
  slowAutocompleteStarted: Atomic[bool]
  slowAutocompleteStopped: Atomic[bool]

proc svc(): ref Services =
  new result

proc interaction(value: JsonNode, optionType = 3, nested = false): JsonNode =
  let focused = %*{
    "name": "query", "type": optionType, "value": value, "focused": true
  }
  let options =
    if nested:
      %*[{"name": "group", "type": 2, "options": [
        {"name": "sub", "type": 1, "options": [focused]}]}]
    else:
      %*[focused]
  %*{
    "id": "100", "application_id": "200", "type": 4, "token": "tkn",
    "context": 0, "guild_id": "300",
    "authorizing_integration_owners": {"0": "300"},
    "user": {"id": "42"}, "locale": "en-US", "guild_locale": "en-GB",
    "data": {"name": "search", "type": 1, "options": options}
  }

proc suggest(services: ref Services, request: AutocompleteRequest):
    Future[seq[AutocompleteChoice]] {.async.} =
  discard services
  for rendered in [$request, repr(request), $(%request),
                   $jsonutils.toJson(request)]:
    doAssert "tkn" notin rendered
  doAssert request.command.name == "search"
  doAssert request.focusedName == "query"
  doAssert request.focusedText() == "ni"
  doAssert request.locale.isSome
  return @[
    initAutocompleteChoice("First", "a"),
    initAutocompleteChoice("Second", "b")]

proc overflow(services: ref Services, request: AutocompleteRequest):
    Future[seq[AutocompleteChoice]] {.async.} =
  discard services
  discard request
  for index in 0 ..< 30:
    result.add initAutocompleteChoice("choice " & $index, index.int64)

proc boom(services: ref Services, request: AutocompleteRequest):
    Future[seq[AutocompleteChoice]] {.async.} =
  discard services
  discard request
  raise newException(ValueError, "SECRET-autocomplete-handler-detail")

proc slow(services: ref Services, request: AutocompleteRequest):
    Future[seq[AutocompleteChoice]] {.async.} =
  discard services
  discard request
  slowAutocompleteStarted.store(true)
  try:
    await sleepAsync(30.seconds)
  finally:
    slowAutocompleteStopped.store(true)

proc synchronousBurn(services: ref Services, request: AutocompleteRequest):
    Future[seq[AutocompleteChoice]] {.async.} =
  discard services
  discard request
  # Burn the acknowledgement budget synchronously, before any await, so the
  # deadline timer cannot fire on this event-loop turn and only the pre-select
  # re-sample can catch the overrun.
  sleep(500)
  return @[initAutocompleteChoice("late", "late")]

proc registryWith(handler: AutocompleteHandler[Services];
                  group = none(string); subcommand = none(string)):
    AutocompleteRegistry[Services] =
  result = initAutocompleteRegistry[Services]()
  result.register(
    initCommandKey(ckChatInput, "search"), "query", handler,
    group, subcommand)

suite "autocomplete dispatch bridge":
  test "decodes, dispatches, and selects a delivered type-8 callback":
    proc scenario(): Future[JsonNode] {.async.} =
      let selected = await selectAutocompleteResponse(
        registryWith(suggest), svc(), interaction(%"ni"), monotonicMillis())
      doAssert selected.hasDelivery()
      selected.confirmDelivery()
      return selected.body

    let body = waitFor scenario()
    check body["type"].getInt() == 8
    check body["data"]["choices"].len == 2
    check body["data"]["choices"][0]["name"].getStr() == "First"
    check body["data"]["choices"][1]["value"].getStr() == "b"

  test "an unmatched registry still yields a valid empty callback":
    proc scenario(): Future[JsonNode] {.async.} =
      let selected = await selectAutocompleteResponse(
        initAutocompleteRegistry[Services](), svc(), interaction(%"ni"),
        monotonicMillis())
      selected.confirmDelivery()
      return selected.body

    let body = waitFor scenario()
    check body["type"].getInt() == 8
    check body["data"]["choices"].len == 0

  test "resolves a focused option nested under a subcommand group":
    proc scenario(): Future[JsonNode] {.async.} =
      # The handler asserts focusedText == "ni", so route it through the group.
      let nested = interaction(%"ni", nested = true)
      let selected = await selectAutocompleteResponse(
        registryWith(suggest, some("group"), some("sub")),
        svc(), nested, monotonicMillis())
      selected.confirmDelivery()
      return selected.body

    check waitFor(scenario())["data"]["choices"].len == 2

  test "redacts response validation failures and observes only the ID":
    var observed: Atomic[int]
    observed.store(0)
    proc observer(interactionId: Option[InteractionId])
        {.gcsafe, raises: [].} =
      if interactionId.isSome and $interactionId.get() == "100":
        observed.store(1)

    proc scenario(): Future[string] {.async.} =
      try:
        discard await selectAutocompleteResponse(
          registryWith(overflow), svc(), interaction(%""), monotonicMillis(),
          observer)
        return "no error"
      except AutocompleteDispatchError as error:
        return error.msg

    let message = waitFor scenario()
    check message == "autocomplete response could not be selected"
    check observed.load() == 1

  test "redacts handler failures and observes only the interaction ID":
    var observed: Atomic[int]
    observed.store(0)
    proc observer(interactionId: Option[InteractionId])
        {.gcsafe, raises: [].} =
      if interactionId.isSome and $interactionId.get() == "100":
        observed.store(1)

    proc scenario(): Future[string] {.async.} =
      try:
        discard await selectAutocompleteResponse(
          registryWith(boom), svc(), interaction(%"n"), monotonicMillis(),
          observer)
        return "no error"
      except AutocompleteDispatchError as error:
        return error.msg

    let message = waitFor scenario()
    check message == "autocomplete handler failed"
    check not message.contains("SECRET")
    check observed.load() == 1

  test "deadline timeout cancels and joins the autocomplete handler":
    slowAutocompleteStarted.store(false)
    slowAutocompleteStopped.store(false)
    proc scenario(): Future[bool] {.async.} =
      try:
        discard await selectAutocompleteResponse(
          registryWith(slow), svc(), interaction(%"n"),
          monotonicMillis() + -2_700'i64)
        return false
      except InteractionExpiredError:
        return true

    check waitFor scenario()
    check slowAutocompleteStarted.load()
    check slowAutocompleteStopped.load()

  test "rejects a non-autocomplete interaction":
    proc scenario(): Future[void] {.async.} =
      let notAutocomplete = %*{"id": "1", "type": 2, "user": {"id": "42"}}
      discard await selectAutocompleteResponse(
        registryWith(suggest), svc(), notAutocomplete, monotonicMillis())

    expect AutocompleteDispatchError:
      waitFor scenario()

  test "synchronous pre-await work past the send margin expires, not selects":
    var observerFired: Atomic[int]
    observerFired.store(0)
    proc observer(interactionId: Option[InteractionId])
        {.gcsafe, raises: [].} =
      discard interactionId
      observerFired.store(1)

    proc scenario(): Future[bool] {.async.} =
      # ~600 ms remaining, so the initial guard passes; the 500 ms synchronous
      # burn then crosses the 250 ms send margin at the pre-select re-sample.
      try:
        discard await selectAutocompleteResponse(
          registryWith(synchronousBurn), svc(), interaction(%"n"),
          monotonicMillis() + -2_400'i64, observer)
        return false
      except InteractionExpiredError:
        return true

    check waitFor scenario()
    # A deadline overrun is an expiry, not an application failure.
    check observerFired.load() == 0
