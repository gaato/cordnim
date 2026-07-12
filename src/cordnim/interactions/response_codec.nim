## Discord callback encoding for response-capable application contexts.

import std/json

import ./exchange
import ./responder

type
  ResponseCodecError* = object of CatchableError
    ## A context action cannot be represented at the requested boundary.

func validateInitialResponse*(response: ContextResponse) =
  ## Validates callback shape before the exchange consumes response authority.
  case response.action
  of raReply, raUpdateMessage:
    if not response.body.isNil and response.body.kind notin {JNull, JObject}:
      raise newException(ResponseCodecError,
        "interaction message response body must be a JSON object")
  of raDefer, raDeferUpdate:
    discard
  of raAutocomplete:
    if response.body.isNil or response.body.kind != JObject or
        not response.body.hasKey("choices") or
        response.body["choices"].kind != JArray:
      raise newException(ResponseCodecError,
        "interaction autocomplete data must contain a choices array")
  of raModal:
    if response.body.isNil or response.body.kind != JObject:
      raise newException(ResponseCodecError,
        "interaction modal response body must be a JSON object")
  of raEditOriginal, raFollowup:
    raise newException(ResponseCodecError,
      "post-acknowledgement response requires webhook transport")

func messageData(response: ContextResponse): JsonNode =
  if response.body.isNil or response.body.kind == JNull:
    result = newJObject()
  elif response.body.kind == JObject:
    result = response.body.copy()
  else:
    raise newException(ResponseCodecError,
      "interaction message response body must be a JSON object")

  if not result.hasKey("allowed_mentions"):
    result["allowed_mentions"] = %*{"parse": []}
  if response.visibility == vEphemeral:
    let existing =
      if result.hasKey("flags") and result["flags"].kind == JInt:
        result["flags"].getInt()
      else:
        0
    result["flags"] = %(existing or 64)

func initialResponseJson*(response: ContextResponse): JsonNode =
  ## Encodes an initial context action as a Discord interaction callback.
  ##
  ## Post-acknowledgement edits and follow-ups require webhook REST endpoints
  ## and raise `ResponseCodecError` at this boundary.
  response.validateInitialResponse()
  result = newJObject()
  case response.action
  of raReply:
    result["type"] = %4
    result["data"] = response.messageData()
  of raDefer:
    result["type"] = %5
    result["data"] = newJObject()
    if response.visibility == vEphemeral:
      result["data"]["flags"] = %64
  of raDeferUpdate:
    result["type"] = %6
  of raUpdateMessage:
    result["type"] = %7
    result["data"] = response.messageData()
  of raAutocomplete:
    result["type"] = %8
    result["data"] = response.body.copy()
  of raModal:
    result["type"] = %9
    result["data"] = response.body.copy()
  of raEditOriginal, raFollowup:
    discard # Rejected by validateInitialResponse above.
