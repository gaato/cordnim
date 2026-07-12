## Bridge from generated lossless raw requests into the REST runtime.

import std/json

import cordnim/raw/request as raw_request
import cordnim/raw/route as raw_route
import ./request as runtime_request

func runtimeMethod(httpMethod: raw_route.HttpMethod):
                   runtime_request.HttpMethod =
  case httpMethod
  of httpGet: hmGet
  of httpPost: hmPost
  of httpPut: hmPut
  of httpPatch: hmPatch
  of httpDelete: hmDelete

func toRuntimeRequest*(raw: raw_request.RawRequest,
                       meta = runtime_request.defaultRequestMeta(),
                       authRequirement = runtime_request.darConfigured):
                       runtime_request.RawRequest =
  ## Converts a generated request without hiding or logging sensitive values.
  ##
  ## Until Discord supplies a bucket ID, requests sharing a route template use
  ## one conservative bucket. Rendered paths never enter scheduler diagnostics
  ## because webhook tokens can be path parameters.
  result = runtime_request.RawRequest(
    route: runtime_request.routeKey(raw.route.httpMethod.runtimeMethod,
      raw.route.pathTemplate, raw.majorParameter),
    urlPath: raw.renderedPath(),
    authRequirement: authRequirement,
    meta: meta
  )
  for header in raw.headers:
    result.headers.add((header.name, header.value))
  if not raw.body.isNil:
    let serialized = $raw.body
    var encoded = newSeq[byte](serialized.len)
    for index, value in serialized:
      encoded[index] = byte(ord(value))
    result.body = runtime_request.jsonBody(encoded)
