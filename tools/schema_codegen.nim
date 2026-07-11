## Deterministic generator for Cordnim's lossless raw Discord API surface.

import std/[algorithm, json, os, strutils, tables]

type
  LockInfo = object
    apiVersion: int
    schemaRevision: string
    sourceRepository: string
    sourceCommit: string
    specRelativePath: string
    specSha256: string
    overlayRelativePath: string
    overlayRevision: int

  Operation = object
    resource: string
    path: string
    httpMethod: string
    operationId: string
    nimName: string
    requestSchema: string
    responseSchema: string
    hasRequestBody: bool
    deprecated: bool

  GeneratedFile = object
    relativePath: string
    content: string

const
  sha256RoundConstants: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32
  ]

func rotateRight(value: uint32, count: int): uint32 =
  (value shr count) or (value shl (32 - count))

func sha256Hex(input: string): string =
  # Keep schema verification self-contained so regeneration never depends on
  # the host's OpenSSL command or platform-specific crypto packages.
  var message = newSeqOfCap[byte](input.len + 72)
  for value in input:
    message.add byte(ord(value))
  message.add 0x80'u8
  while message.len mod 64 != 56:
    message.add 0'u8

  let bitLength = uint64(input.len) * 8'u64
  for shift in countdown(56, 0, 8):
    message.add byte((bitLength shr shift) and 0xff'u64)

  var hash = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32
  ]

  var offset = 0
  while offset < message.len:
    var words: array[64, uint32]
    for index in 0 .. 15:
      let start = offset + index * 4
      words[index] =
        (uint32(message[start]) shl 24) or
        (uint32(message[start + 1]) shl 16) or
        (uint32(message[start + 2]) shl 8) or
        uint32(message[start + 3])
    for index in 16 .. 63:
      let sigma0 = rotateRight(words[index - 15], 7) xor
        rotateRight(words[index - 15], 18) xor
        (words[index - 15] shr 3)
      let sigma1 = rotateRight(words[index - 2], 17) xor
        rotateRight(words[index - 2], 19) xor
        (words[index - 2] shr 10)
      words[index] = words[index - 16] + sigma0 +
        words[index - 7] + sigma1

    var a = hash[0]
    var b = hash[1]
    var c = hash[2]
    var d = hash[3]
    var e = hash[4]
    var f = hash[5]
    var g = hash[6]
    var h = hash[7]

    for index in 0 .. 63:
      let choice = (e and f) xor ((not e) and g)
      let majority = (a and b) xor (a and c) xor (b and c)
      let bigSigma0 = rotateRight(a, 2) xor rotateRight(a, 13) xor
        rotateRight(a, 22)
      let bigSigma1 = rotateRight(e, 6) xor rotateRight(e, 11) xor
        rotateRight(e, 25)
      let temporary1 = h + bigSigma1 + choice +
        sha256RoundConstants[index] + words[index]
      let temporary2 = bigSigma0 + majority

      h = g
      g = f
      f = e
      e = d + temporary1
      d = c
      c = b
      b = a
      a = temporary1 + temporary2

    hash[0] = hash[0] + a
    hash[1] = hash[1] + b
    hash[2] = hash[2] + c
    hash[3] = hash[3] + d
    hash[4] = hash[4] + e
    hash[5] = hash[5] + f
    hash[6] = hash[6] + g
    hash[7] = hash[7] + h
    offset += 64

  for value in hash:
    result.add toHex(value, 8).toLowerAscii

proc fail(message: string) {.noreturn.} =
  quit "schema_codegen: " & message

proc requireObject(node: JsonNode, description: string) =
  if node.isNil or node.kind != JObject:
    fail description & " must be a JSON object"

proc requiredString(node: JsonNode, key: string): string =
  node.requireObject("document")
  if not node.hasKey(key) or node[key].kind != JString:
    fail "missing string field: " & key
  node[key].getStr

proc requiredInt(node: JsonNode, key: string): int =
  node.requireObject("document")
  if not node.hasKey(key) or node[key].kind != JInt:
    fail "missing integer field: " & key
  node[key].getInt

proc sortedKeys(node: JsonNode): seq[string] =
  node.requireObject("value")
  for key, _ in node.fields:
    result.add key
  result.sort

proc findProjectRoot(start: string): string =
  var candidate = start.absolutePath
  while true:
    if fileExists(candidate / "schemas" / "schema-lock.json"):
      return candidate
    let parent = candidate.parentDir
    if parent == candidate:
      break
    candidate = parent

proc projectRoot(): string =
  result = findProjectRoot(getCurrentDir())
  if result.len == 0:
    result = findProjectRoot(getAppDir())
  if result.len == 0:
    fail "could not find schemas/schema-lock.json"

proc readLock(root: string): LockInfo =
  let node = parseFile(root / "schemas" / "schema-lock.json")
  result.apiVersion = node.requiredInt("apiVersion")
  result.schemaRevision = node.requiredString("schemaRevision")
  result.sourceRepository = node.requiredString("sourceRepository")
  result.sourceCommit = node.requiredString("sourceCommit")
  result.specRelativePath = node.requiredString("standardSpec")
  result.specSha256 = node.requiredString("standardSpecSha256")
  result.overlayRelativePath = node.requiredString("overlay")
  result.overlayRevision = node.requiredInt("overlayRevision")

func nimQuote(value: string): string =
  result = "\""
  for character in value:
    case character
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add character
  result.add '"'

func snakeName(value: string): string =
  var needsSeparator = false
  for character in value:
    if character in {'a'..'z', '0'..'9'}:
      if needsSeparator and result.len > 0 and result[^1] != '_':
        result.add '_'
      result.add character
      needsSeparator = false
    elif character in {'A'..'Z'}:
      if needsSeparator and result.len > 0 and result[^1] != '_':
        result.add '_'
      result.add character.toLowerAscii
      needsSeparator = false
    else:
      needsSeparator = true
  if result.len == 0:
    result = "other"
  if result[0] in {'0'..'9'}:
    result = "resource_" & result

func lowerCamel(value: string): string =
  var capitalizeNext = false
  for character in value:
    if character in {'a'..'z', 'A'..'Z', '0'..'9'}:
      if result.len == 0:
        result.add character.toLowerAscii
      elif capitalizeNext:
        result.add character.toUpperAscii
      else:
        result.add character
      capitalizeNext = false
    else:
      capitalizeNext = true
  if result.len == 0 or result[0] in {'0'..'9'}:
    result = "route" & result

func typeName(value: string): string =
  var capitalizeNext = true
  for character in value:
    if character in {'a'..'z', 'A'..'Z', '0'..'9'}:
      if capitalizeNext:
        result.add character.toUpperAscii
      else:
        result.add character
      capitalizeNext = false
    else:
      capitalizeNext = true
  if result.len == 0 or result[0] in {'0'..'9'}:
    result = "Schema" & result

func referenceName(reference: string): string =
  let separator = reference.rfind('/')
  if separator >= 0:
    reference[separator + 1 .. ^1]
  else:
    reference

proc schemaLabel(schema: JsonNode): string =
  if schema.isNil or schema.kind != JObject:
    return ""
  if schema.hasKey("$ref") and schema["$ref"].kind == JString:
    return referenceName(schema["$ref"].getStr)
  if schema.hasKey("type"):
    let kind = schema["type"]
    if kind.kind == JString:
      if kind.getStr == "array" and schema.hasKey("items"):
        return "seq[" & schemaLabel(schema["items"]) & "]"
      return kind.getStr
    if kind.kind == JArray:
      var alternatives: seq[string]
      for value in kind.items:
        if value.kind == JString:
          if value.getStr == "array" and schema.hasKey("items"):
            alternatives.add "seq[" & schemaLabel(schema["items"]) & "]"
          else:
            alternatives.add value.getStr
      return alternatives.join(" | ")
  for unionKey in ["oneOf", "anyOf", "allOf"]:
    if schema.hasKey(unionKey) and schema[unionKey].kind == JArray:
      var alternatives: seq[string]
      for alternative in schema[unionKey].items:
        let label = schemaLabel(alternative)
        if label.len > 0 and label notin alternatives:
          alternatives.add label
      if alternatives.len > 0:
        return alternatives.join(" | ")
  "inline"

proc contentSchema(container: JsonNode): string =
  if container.isNil or container.kind != JObject:
    return ""
  if container.hasKey("$ref"):
    return schemaLabel(container)
  if not container.hasKey("content") or container["content"].kind != JObject:
    return ""
  let content = container["content"]
  for mediaType in ["application/json", "multipart/form-data"]:
    if content.hasKey(mediaType):
      let media = content[mediaType]
      if media.kind == JObject and media.hasKey("schema"):
        return schemaLabel(media["schema"])
  for mediaType in content.sortedKeys:
    let media = content[mediaType]
    if media.kind == JObject and media.hasKey("schema"):
      return schemaLabel(media["schema"])

proc responseSchema(operation: JsonNode): string =
  if not operation.hasKey("responses") or operation["responses"].kind != JObject:
    return ""
  let responses = operation["responses"]
  for status in responses.sortedKeys:
    if status.len == 3 and status[0] == '2':
      let label = contentSchema(responses[status])
      if label.len > 0:
        return label

func resourceName(path: string): string =
  let start = if path.len > 0 and path[0] == '/': 1 else: 0
  let separator = path.find('/', start)
  let raw = if separator < 0: path[start .. ^1]
    else: path[start ..< separator]
  snakeName(raw)

func methodName(value: string): string =
  case value
  of "get": "httpGet"
  of "post": "httpPost"
  of "put": "httpPut"
  of "patch": "httpPatch"
  of "delete": "httpDelete"
  else: ""

proc collectOperations(spec: JsonNode): seq[Operation] =
  if not spec.hasKey("paths") or spec["paths"].kind != JObject:
    fail "OpenAPI document has no paths object"
  let paths = spec["paths"]
  for path in paths.sortedKeys:
    let pathItem = paths[path]
    for httpMethod in ["get", "post", "put", "patch", "delete"]:
      if not pathItem.hasKey(httpMethod):
        continue
      let operation = pathItem[httpMethod]
      if not operation.hasKey("operationId"):
        fail httpMethod.toUpperAscii & " " & path & " has no operationId"
      let operationId = operation["operationId"].getStr
      let hasBody = operation.hasKey("requestBody")
      let request = if hasBody: contentSchema(operation["requestBody"]) else: ""
      let deprecated = operation.hasKey("deprecated") and
        operation["deprecated"].kind == JBool and operation["deprecated"].getBool
      result.add Operation(
        resource: resourceName(path),
        path: path,
        httpMethod: httpMethod,
        operationId: operationId,
        nimName: lowerCamel(operationId),
        requestSchema: request,
        responseSchema: responseSchema(operation),
        hasRequestBody: hasBody,
        deprecated: deprecated
      )

func schemaCategory(name: string): string =
  if name.startsWith("Application") or name.startsWith("Activities") or
      name.startsWith("Activity") or name.startsWith("Entitlement") or
      name.startsWith("Sku") or name.startsWith("Subscription"):
    "application"
  elif name.startsWith("AuditLog"):
    "audit_log"
  elif name.startsWith("Automod") or name.startsWith("AutoModeration"):
    "automod"
  elif name.startsWith("Channel") or name.startsWith("Thread") or
      name.startsWith("Forum"):
    "channel"
  elif name.startsWith("Command"):
    "command"
  elif name.startsWith("Component") or name.startsWith("ActionRow") or
      name.startsWith("Button") or name.startsWith("TextDisplay") or
      name.startsWith("Section") or name.startsWith("Separator") or
      name.startsWith("Container") or name.startsWith("MediaGallery") or
      name.startsWith("Thumbnail") or name.startsWith("FileComponent") or
      name.startsWith("Label") or name.startsWith("Checkbox") or
      name.startsWith("RadioGroup"):
    "component"
  elif name.startsWith("Emoji"):
    "emoji"
  elif name.startsWith("Gateway"):
    "gateway"
  elif name.startsWith("Guild") or name.startsWith("Ban") or
      name.startsWith("Role") or name.startsWith("WelcomeScreen") or
      name.startsWith("Widget"):
    "guild"
  elif name.startsWith("Integration"):
    "integration"
  elif name.startsWith("Interaction") or name.contains("InteractionCallback"):
    "interaction"
  elif name.startsWith("Invite"):
    "invite"
  elif name.startsWith("Lobby"):
    "lobby"
  elif name.startsWith("Message") or name.startsWith("AllowedMention") or
      name.startsWith("Attachment") or name.startsWith("Embed"):
    "message"
  elif name.startsWith("OAuth2") or name.startsWith("OAuth"):
    "oauth2"
  elif name.startsWith("Poll"):
    "poll"
  elif name.startsWith("Soundboard") or name.startsWith("Sound"):
    "soundboard"
  elif name.startsWith("Stage"):
    "stage_instance"
  elif name.startsWith("Sticker"):
    "sticker"
  elif name.startsWith("User") or name.startsWith("Account"):
    "user"
  elif name.startsWith("Voice"):
    "voice"
  elif name.startsWith("Webhook") or name.startsWith("IncomingWebhook"):
    "webhook"
  else:
    "common"

func generatedHeader(lock: LockInfo): string =
  "# Generated by tools/schema_codegen.nim; do not edit by hand.\n" &
    "# Source: " & lock.sourceRepository & " @ " & lock.sourceCommit & "\n" &
    "# Schema revision: " & lock.schemaRevision & "\n\n"

func generatedPreamble(lock: LockInfo; summary: string): string =
  "## " & summary & "\n" &
    "##\n" &
    "## This module is generated from Cordnim's pinned Discord OpenAPI " &
    "snapshot. Update `tools/schema_codegen.nim` or the semantic overlay " &
    "instead of editing generated declarations.\n\n" &
    generatedHeader(lock)

proc addFile(files: var seq[GeneratedFile], path, content: string) =
  var normalized = content
  while normalized.endsWith("\n\n"):
    normalized.setLen(normalized.len - 1)
  files.add GeneratedFile(relativePath: path, content: normalized)

proc generateSchemaInfo(
    files: var seq[GeneratedFile], lock: LockInfo,
    schemaCount, operationCount, overlayRuleCount: int,
    preserveUnknownFields, preserveUnknownEnums, preserveUnknownBits: bool
) =
  var content = generatedPreamble(
    lock,
    "Version and compatibility metadata for the generated raw API.",
  )
  content.add "const\n"
  content.add "  discordApiVersion* = " & $lock.apiVersion &
    " ## Discord REST API version targeted by this snapshot.\n"
  content.add "  discordSchemaRevision* = " & nimQuote(lock.schemaRevision) &
    " ## Cordnim release date assigned to the snapshot.\n"
  content.add "  discordSchemaSourceCommit* = " & nimQuote(lock.sourceCommit) &
    " ## Full commit hash in Discord's specification repository.\n"
  content.add "  discordSchemaSha256* = " & nimQuote(lock.specSha256) &
    " ## SHA-256 digest of the pinned OpenAPI document.\n"
  content.add "  discordOverlayRevision* = " & $lock.overlayRevision &
    " ## Revision of Cordnim's semantic corrections.\n"
  content.add "  discordOverlayRuleCount* = " & $overlayRuleCount &
    " ## Number of explicit semantic correction rules.\n"
  content.add "  discordSchemaCount* = " & $schemaCount &
    " ## Number of component schemas in the snapshot.\n"
  content.add "  discordOperationCount* = " & $operationCount &
    " ## Number of generated stable HTTP operations.\n"
  content.add "  preservesUnknownObjectFields* = " & $preserveUnknownFields &
    " ## Whether raw models round-trip unrecognized object fields.\n"
  content.add "  preservesUnknownEnumValues* = " & $preserveUnknownEnums &
    " ## Whether decoding retains unrecognized enum values.\n"
  content.add "  preservesUnknownFlagBits* = " & $preserveUnknownBits &
    " ## Whether bit fields retain bits unknown to this revision.\n"
  files.addFile("src/cordnim/raw/schema_info.nim", content)

proc generateModels(
    files: var seq[GeneratedFile], lock: LockInfo, schemas: JsonNode
) =
  var categories = initOrderedTable[string, seq[string]]()
  let schemaNames = schemas.sortedKeys
  for schemaName in schemaNames:
    let category = schemaCategory(schemaName)
    categories.mgetOrPut(category, @[]).add schemaName

  var categoryNames: seq[string]
  for category in categories.keys:
    categoryNames.add category
  categoryNames.sort

  for category in categoryNames:
    var content = generatedPreamble(
      lock,
      "Lossless raw Discord models in the `" & category & "` schema group.",
    )
    content.add "import std/json\n\n"
    content.add "type\n"
    for schemaName in categories[category]:
      let nimName = typeName(schemaName)
      content.add "  " & nimName & "* = object ## Lossless raw representation " &
        "of OpenAPI schema `" & schemaName & "`.\n"
      content.add "    raw*: JsonNode ## Complete JSON payload, including " &
        "fields unknown to this schema revision.\n\n"
    files.addFile("src/cordnim/raw/models/" & category & ".nim", content)

  var index = generatedPreamble(
    lock,
    "Complete index of stable raw Discord OpenAPI models.",
  )
  index.add "import ./model\n"
  for category in categoryNames:
    index.add "import ./models/" & category & "\n"
  index.add "\nexport model\n"
  for category in categoryNames:
    index.add "export " & category & "\n"
  index.add "\nconst schemaNames*: array[" & $schemaNames.len & ", string] = [\n"
  for schemaName in schemaNames:
    index.add "  " & nimQuote(schemaName) & ",\n"
  index.add "] ## Canonical OpenAPI component names available in this snapshot.\n"
  files.addFile("src/cordnim/raw/models.nim", index)

proc generateRoutes(
    files: var seq[GeneratedFile], lock: LockInfo,
    operations: seq[Operation]
) =
  var resources = initOrderedTable[string, seq[Operation]]()
  for operation in operations:
    resources.mgetOrPut(operation.resource, @[]).add operation

  var resourceNames: seq[string]
  for resource in resources.keys:
    resourceNames.add resource
  resourceNames.sort

  for resource in resourceNames:
    var content = generatedPreamble(
      lock,
      "Stable raw Discord HTTP routes in the `" & resource & "` resource group.",
    )
    content.add "import ../route\n\n"
    content.add "const\n"
    for operation in resources[resource]:
      content.add "  " & operation.nimName & "* = RawRoute(\n"
      content.add "    httpMethod: " & methodName(operation.httpMethod) & ",\n"
      content.add "    pathTemplate: " & nimQuote(operation.path) & ",\n"
      content.add "    operationId: " & nimQuote(operation.operationId) & ",\n"
      content.add "    requestSchema: " & nimQuote(operation.requestSchema) & ",\n"
      content.add "    responseSchema: " & nimQuote(operation.responseSchema) & ",\n"
      content.add "    hasRequestBody: " & $operation.hasRequestBody & ",\n"
      content.add "    deprecated: " & $operation.deprecated & "\n"
      content.add "  ) ## Route metadata for `" &
        operation.httpMethod.toUpperAscii & " " & operation.path & "` " &
        "(`" & operation.operationId & "`).\n"
    let inventoryName = lowerCamel(resource) & "Routes"
    content.add "  " & inventoryName & "*: array[" &
      $resources[resource].len & ", RawRoute] = [\n"
    for operation in resources[resource]:
      content.add "    " & operation.nimName & ",\n"
    content.add "  ] ## All generated routes in this resource group.\n"
    files.addFile("src/cordnim/raw/routes/" & resource & ".nim", content)

  var index = generatedPreamble(
    lock,
    "Complete registry of stable raw Discord HTTP routes.",
  )
  index.add "import std/options\n\n"
  index.add "import ./route\n"
  for resource in resourceNames:
    index.add "import ./routes/" & resource & "\n"
  index.add "\nexport route\n"
  for resource in resourceNames:
    index.add "export " & resource & "\n"
  index.add "\nconst allRoutes*: array[" & $operations.len & ", RawRoute] = [\n"
  for operation in operations:
    index.add "  " & operation.nimName & ",\n"
  index.add "] ## Every HTTP operation in the pinned stable schema.\n\n"
  index.add "func findRoute*(operationId: string): Option[RawRoute] =\n"
  index.add "  ## Looks up generated route metadata by its OpenAPI operation ID.\n"
  index.add "  for route in allRoutes:\n"
  index.add "    if route.operationId == operationId:\n"
  index.add "      return some(route)\n"
  index.add "  none(RawRoute)\n"
  files.addFile("src/cordnim/raw/routes.nim", index)

proc generateRouteInventory(
    files: var seq[GeneratedFile], lock: LockInfo,
    operations: openArray[Operation]
) =
  var content = "# Generated by tools/schema_codegen.nim; do not edit by hand.\n"
  content.add "# source_commit\t" & lock.sourceCommit & "\n"
  content.add "method\tpath\toperation_id\trequest_schema\tresponse_schema\n"
  for operation in operations:
    let requestSchema =
      if operation.requestSchema.len == 0: "-" else: operation.requestSchema
    let responseSchema =
      if operation.responseSchema.len == 0: "-" else: operation.responseSchema
    content.add operation.httpMethod.toUpperAscii & "\t"
    content.add operation.path & "\t"
    content.add operation.operationId & "\t"
    content.add requestSchema & "\t"
    content.add responseSchema & "\n"
  files.addFile("schemas/stable-routes.tsv", content)

proc generate(root: string): seq[GeneratedFile] =
  let lock = readLock(root)
  let specPath = root / "schemas" / lock.specRelativePath
  let overlayPath = root / "schemas" / lock.overlayRelativePath
  if not fileExists(specPath):
    fail "missing pinned spec: " & specPath
  if not fileExists(overlayPath):
    fail "missing semantic overlay: " & overlayPath

  let specText = readFile(specPath)
  let actualDigest = sha256Hex(specText)
  if actualDigest != lock.specSha256:
    fail "pinned spec SHA-256 mismatch: expected " & lock.specSha256 &
      ", got " & actualDigest

  let spec = parseJson(specText)
  let overlay = parseFile(overlayPath)
  if not overlay.hasKey("revision") or
      overlay["revision"].getInt != lock.overlayRevision:
    fail "semantic overlay revision does not match schema lock"
  if not spec.hasKey("info") or
      spec["info"].requiredString("version") != $lock.apiVersion:
    fail "OpenAPI info.version does not match schema lock"
  if not spec.hasKey("components") or
      not spec["components"].hasKey("schemas"):
    fail "OpenAPI document has no component schemas"

  let operations = collectOperations(spec)
  let schemas = spec["components"]["schemas"]
  let rules = if overlay.hasKey("rules") and overlay["rules"].kind == JArray:
    overlay["rules"].len else: 0
  let constraints = if overlay.hasKey("constraints"):
    overlay["constraints"] else: newJObject()
  let preserveFields = constraints.hasKey("preserveUnknownObjectFields") and
    constraints["preserveUnknownObjectFields"].getBool
  let preserveEnums = constraints.hasKey("preserveUnknownEnumValues") and
    constraints["preserveUnknownEnumValues"].getBool
  let preserveBits = constraints.hasKey("preserveUnknownFlagBits") and
    constraints["preserveUnknownFlagBits"].getBool

  result.generateSchemaInfo(
    lock, schemas.len, operations.len, rules,
    preserveFields, preserveEnums, preserveBits
  )
  result.generateModels(lock, schemas)
  result.generateRoutes(lock, operations)
  result.generateRouteInventory(lock, operations)
  result.sort(proc(left, right: GeneratedFile): int =
    cmp(left.relativePath, right.relativePath))

proc applyGeneratedFiles(
    root: string, files: openArray[GeneratedFile], checkOnly: bool
) =
  var drift: seq[string]
  for generated in files:
    let path = root / generated.relativePath
    let current = if fileExists(path): readFile(path) else: ""
    if current == generated.content:
      continue
    if checkOnly:
      drift.add generated.relativePath
    else:
      createDir(path.parentDir)
      writeFile(path, generated.content)
      echo "generated ", generated.relativePath

  if drift.len > 0:
    for path in drift:
      stderr.writeLine "generated file differs: ", path
    quit "schema_codegen: generated files are stale"
  if checkOnly:
    echo "schema_codegen: generated files are current"

when isMainModule:
  let root = projectRoot()
  let checkOnly = "--check" in commandLineParams()
  let files = generate(root)
  applyGeneratedFiles(root, files, checkOnly)
