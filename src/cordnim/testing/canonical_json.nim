## Order-independent JSON comparison with path-oriented mismatch diagnostics.
##
## Discord serializers and JSON libraries do not agree on object key order, so a
## naive string comparison of two structurally identical documents fails. These
## helpers compare by value: object membership ignores key order, while arrays
## remain order-sensitive because Discord array positions are significant. When
## two documents differ, the reported path points at the exact divergence.

import std/[algorithm, json]

proc canonicalize*(node: JsonNode): JsonNode {.raises: [].} =
  ## Returns a deep copy of `node` with every object's keys sorted.
  ##
  ## The result serializes identically for any two value-equal documents, which
  ## makes it a stable key for cassettes and snapshot comparisons.
  if node.isNil:
    return newJNull()
  case node.kind
  of JObject:
    result = newJObject()
    var keys: seq[string]
    for key in node.keys:
      keys.add(key)
    keys.sort()
    for key in keys:
      result[key] = canonicalize(node{key})
  of JArray:
    result = newJArray()
    for value in node:
      result.add(canonicalize(value))
  else:
    result = node.copy()

proc canonicalText*(node: JsonNode): string =
  ## Returns the canonical, key-sorted serialization of `node`.
  $canonicalize(node)

func kindName(node: JsonNode): string =
  if node.isNil: "null" else: $node.kind

proc jsonMismatch*(expected, actual: JsonNode, path = "$"): string {.
    raises: [].} =
  ## Returns the first structural difference between two documents, or "".
  ##
  ## The path uses `$` for the document root, `.name` for object fields, and
  ## `[index]` for array elements, e.g. `$.data.options[0].value`.
  let expectedNil = expected.isNil or expected.kind == JNull
  let actualNil = actual.isNil or actual.kind == JNull
  if expectedNil and actualNil:
    return ""
  if expected.isNil or actual.isNil or expected.kind != actual.kind:
    return path & ": expected " & expected.kindName & ", got " & actual.kindName
  case expected.kind
  of JObject:
    for key, value in expected:
      if not actual.hasKey(key):
        return path & "." & key & ": missing in actual"
      let nested = jsonMismatch(value, actual{key}, path & "." & key)
      if nested.len != 0:
        return nested
    for key in actual.keys:
      if not expected.hasKey(key):
        return path & "." & key & ": unexpected in actual"
    return ""
  of JArray:
    if expected.elems.len != actual.elems.len:
      return path & ": expected " & $expected.elems.len & " elements, got " &
        $actual.elems.len
    for index in 0 ..< expected.elems.len:
      let nested = jsonMismatch(expected.elems[index], actual.elems[index],
        path & "[" & $index & "]")
      if nested.len != 0:
        return nested
    return ""
  of JString:
    if expected.getStr() != actual.getStr():
      return path & ": expected \"" & expected.getStr() & "\", got \"" &
        actual.getStr() & "\""
    return ""
  of JInt:
    if expected.getBiggestInt() != actual.getBiggestInt():
      return path & ": expected " & $expected.getBiggestInt() & ", got " &
        $actual.getBiggestInt()
    return ""
  of JFloat:
    if expected.getFloat() != actual.getFloat():
      return path & ": expected " & $expected.getFloat() & ", got " &
        $actual.getFloat()
    return ""
  of JBool:
    if expected.getBool() != actual.getBool():
      return path & ": expected " & $expected.getBool() & ", got " &
        $actual.getBool()
    return ""
  of JNull:
    return ""

proc jsonMismatchPath*(expected, actual: JsonNode, path = "$"): string {.
    raises: [].} =
  ## Returns only the first mismatching path, or an empty string when equal.
  ##
  ## Unlike jsonMismatch, this helper never renders either value and is safe for
  ## credential-bearing documents and transport diagnostics.
  let expectedNil = expected.isNil or expected.kind == JNull
  let actualNil = actual.isNil or actual.kind == JNull
  if expectedNil and actualNil:
    return ""
  if expected.isNil or actual.isNil or expected.kind != actual.kind:
    return path
  case expected.kind
  of JObject:
    for key, value in expected:
      if not actual.hasKey(key):
        return path & "." & key
      let nested = jsonMismatchPath(value, actual{key}, path & "." & key)
      if nested.len != 0:
        return nested
    for key in actual.keys:
      if not expected.hasKey(key):
        return path & "." & key
  of JArray:
    if expected.elems.len != actual.elems.len:
      return path
    for index in 0 ..< expected.elems.len:
      let nested = jsonMismatchPath(expected.elems[index], actual.elems[index],
        path & "[" & $index & "]")
      if nested.len != 0:
        return nested
  of JString:
    if expected.getStr() != actual.getStr():
      return path
  of JInt:
    if expected.getBiggestInt() != actual.getBiggestInt():
      return path
  of JFloat:
    if expected.getFloat() != actual.getFloat():
      return path
  of JBool:
    if expected.getBool() != actual.getBool():
      return path
  of JNull:
    discard
  ""

proc jsonEquiv*(expected, actual: JsonNode): bool =
  ## Reports whether two documents are equal ignoring object key order.
  jsonMismatch(expected, actual).len == 0

proc assertJsonEquiv*(expected, actual: JsonNode) =
  ## Raises `AssertionDefect` with the mismatch path when documents differ.
  ## The detailed diagnostic includes primitive values; redact secret-bearing
  ## documents first, or use jsonMismatchPath for a value-free diagnostic.
  let mismatch = jsonMismatch(expected, actual)
  if mismatch.len != 0:
    raise newException(AssertionDefect, "JSON mismatch at " & mismatch)

proc assertJsonEquiv*(expected: JsonNode, actualText: string) =
  ## Parses `actualText` and asserts value-equality with `expected`.
  var parsed: JsonNode
  try:
    parsed = parseJson(actualText)
  except CatchableError as error:
    raise newException(AssertionDefect,
      "actual value is not valid JSON: " & error.msg)
  assertJsonEquiv(expected, parsed)
