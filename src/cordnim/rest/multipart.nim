## Replayable upload sources and streamed Discord multipart request bodies.
##
## A scheduled request owns source factories rather than live file handles. Each
## transport attempt opens fresh cursors and closes them before the attempt
## finishes, so an eligible retry never reuses a consumed stream.
## Sources with known sizes use an exact multipart `Content-Length`; any unknown
## size selects HTTP chunked transfer encoding. Upload bytes are read in bounded
## chunks and are never assembled into one in-memory multipart document.
##
## A file-backed request can be constructed without opening the file yet:
##
## .. code-block:: nim
##
##   var attachments: AttachmentPlan
##   attachments.add uploadAttachment(
##     "report.txt",
##     fileUploadSource("report.txt"),
##     contentType = "text/plain",
##     description = setValue("Daily report")
##   )
##   let body = initMultipartBody(
##     %*{"content": "Attached"}, attachments)
##
## The HTTP transport opens and closes that source separately for each attempt.

import std/[json, options, os, sets, strutils, sysrand, unicode]

import chronos

import cordnim/core/fields
import cordnim/core/ids

export fields

const
  DefaultUploadChunkBytes* = 64 * 1_024 ## Maximum default source read size.
  DefaultUploadContentType* = "application/octet-stream"
    ## Media type used when the caller has no more specific value.
  MaxMessageAttachments* = 10 ## Maximum attachments accepted by Discord.
  MaxAttachmentTextRunes* = 1_024 ## Maximum filename or description length.

type
  FileCursorOwner = object
    handle: File

proc `=destroy`(owner: FileCursorOwner) =
  if owner.handle != nil:
    close(owner.handle)

proc `=wasMoved`(owner: var FileCursorOwner) =
  owner.handle = nil

proc `=copy`(destination: var FileCursorOwner,
             source: FileCursorOwner) {.error.}

proc `=dup`(source: FileCursorOwner): FileCursorOwner {.error.}

type
  UploadLengthError* = object of ValueError ## A sized source produced a
    ## different byte count from the value declared by its source.

  UploadReadProc* = proc(maxBytes: int): Future[seq[byte]]
    {.closure, gcsafe, raises: [].} ## Reads at most `maxBytes`; empty means EOF.

  UploadCloseProc* = proc(): Future[void]
    {.closure, gcsafe, raises: [].} ## Releases one attempt-local cursor.

  UploadCursor* = ref object ## Attempt-local, forward-only upload reader.
    ## A transport closes each opened cursor exactly once, including after
    ## cancellation or a source error.
    readImpl: UploadReadProc
    closeImpl: UploadCloseProc
    expectedSizeValue: Option[int64]
    consumedValue: int64
    closedValue: bool

  UploadOpenProc* = proc(): Future[UploadCursor]
    {.closure, gcsafe, raises: [].} ## Opens a fresh attempt-local cursor.

  UploadSource* = object ## Copyable source factory stored in scheduled work.
    ## A source marked replayable must open an independent cursor that produces
    ## the same bytes on every attempt while its request remains active.
    size*: Option[int64] ## Exact size, or none for chunked transfer encoding.
    replayable*: bool ## Whether a later attempt may safely reopen this source.
    openImpl: UploadOpenProc

  FileCursorState = ref object
    owner: FileCursorOwner

  AttachmentEditKind* = enum ## Operation applied to one attachment.
    aekKeep, ## Retain an existing attachment unchanged.
    aekUpdate, ## Retain and update existing metadata.
    aekUpload ## Add one streamed attachment.

  AttachmentEdit* = object ## One existing or new attachment operation.
    ##
    ## The supported wire subset is `id`, `filename`, `description`, and
    ## `is_spoiler`. Discord's media-derived `duration_secs`, `waveform`,
    ## `title`, and `is_remix` fields are intentionally not constructed here.
    kind*: AttachmentEditKind ## Operation kind.
    existingId*: AttachmentId ## Existing attachment for keep/update.
    filename*: string ## Header-safe upload filename.
    contentType*: string ## Header-safe upload media type.
    description*: Patch[string] ## Omit, clear, or set the description.
    spoiler*: Patch[bool] ## Omit, clear, or set `is_spoiler`.
    source*: UploadSource ## Reopenable source present for `aekUpload`.

  AttachmentPlan* = object ## Ordered attachment operations for a message edit.
    edits*: seq[AttachmentEdit] ## Existing items first, then new uploads.

  MultipartBody* = object ## Replayable multipart payload retained by a request.
    ## Construction freezes attachment metadata and its corresponding sources;
    ## callers cannot mutate either half independently after initialization.
    boundaryValue: string
    payloadJsonValue: seq[byte]
    attachmentsValue: AttachmentPlan

proc readyFuture[T](value: sink T): Future[T] =
  result = newFuture[T]("cordnim.upload.ready")
  result.complete(value)

proc readyVoid(): Future[void] =
  result = newFuture[void]("cordnim.upload.ready-void")
  result.complete()

proc newUploadCursor*(read: UploadReadProc, close: UploadCloseProc = nil,
                      expectedSize = none(int64)): UploadCursor =
  ## Creates an attempt-local cursor from asynchronous read and close hooks.
  if read.isNil:
    raise newException(ValueError, "upload cursor read hook is required")
  if expectedSize.isSome and expectedSize.get() < 0:
    raise newException(ValueError, "upload cursor size must not be negative")
  UploadCursor(
    readImpl: read,
    closeImpl: close,
    expectedSizeValue: expectedSize
  )

proc initUploadSource*(open: UploadOpenProc, replayable: bool,
                       size = none(int64)): UploadSource =
  ## Creates a scheduled upload source from a fresh-cursor factory.
  ##
  ## `open` must return an independent cursor for each call. When `replayable`
  ## is true, every cursor must produce identical bytes. A supplied `size` is
  ## enforced while reading; ending early or producing extra bytes raises
  ## `UploadLengthError`. If opening fails or is cancelled before a cursor is
  ## returned, `open` must release any resources it acquired itself.
  if open.isNil:
    raise newException(ValueError, "upload source open hook is required")
  if size.isSome and size.get() < 0:
    raise newException(ValueError, "upload source size must not be negative")
  UploadSource(size: size, replayable: replayable, openImpl: open)

proc fileUploadSource*(path: string): UploadSource =
  ## Creates a replayable source that reopens `path` for every attempt.
  ##
  ## The default file adapter performs one synchronous, bounded file read per
  ## `readChunk` call. The surrounding HTTP writes remain asynchronous, and the
  ## complete file is never buffered by cordnim. The caller must keep the file
  ## contents unchanged until the request completes; the adapter enforces the
  ## size captured at construction but cannot detect a same-size replacement.
  let expectedSize = getFileSize(path)
  let openCursor: UploadOpenProc = proc(): Future[UploadCursor]
      {.gcsafe, raises: [].} =
    let opened = newFuture[UploadCursor]("cordnim.upload.file.open")
    try:
      var handle: File
      if not open(handle, path, fmRead):
        raise newException(IOError, "cannot open upload source")
      let state = FileCursorState(
        owner: FileCursorOwner(handle: handle)
      )
      let read: UploadReadProc = proc(maxBytes: int): Future[seq[byte]]
          {.gcsafe, raises: [].} =
        let pending = newFuture[seq[byte]]("cordnim.upload.file.read")
        try:
          if state.owner.handle == nil:
            pending.complete(@[])
          else:
            var chunk = newSeq[byte](maxBytes)
            let count = readBuffer(
              state.owner.handle, addr chunk[0], maxBytes)
            chunk.setLen(count)
            pending.complete(chunk)
        except CatchableError as error:
          pending.fail(error)
        pending
      let closeCursor: UploadCloseProc = proc(): Future[void]
          {.gcsafe, raises: [].} =
        if state.owner.handle != nil:
          close(state.owner.handle)
          state.owner.handle = nil
        readyVoid()
      opened.complete(newUploadCursor(
        read, closeCursor, some(expectedSize)))
    except CatchableError as error:
      opened.fail(error)
    opened
  initUploadSource(openCursor, replayable = true, size = some(expectedSize))

proc memoryUploadSource*(data: sink seq[byte]): UploadSource =
  ## Creates a replayable source retaining `data` for every transport attempt.
  ##
  ## This is intended for small generated values. Use `fileUploadSource` or a
  ## custom `UploadSource` when retaining the entire value is undesirable.
  let retained = data
  let openCursor: UploadOpenProc = proc(): Future[UploadCursor]
      {.gcsafe, raises: [].} =
    var offset = 0
    let read: UploadReadProc = proc(maxBytes: int): Future[seq[byte]]
        {.gcsafe, raises: [].} =
      let count = min(maxBytes, retained.len - offset)
      var chunk: seq[byte]
      if count > 0:
        chunk = retained[offset..<offset + count]
        offset += count
      readyFuture(chunk)
    readyFuture(UploadCursor(
      readImpl: read,
      expectedSizeValue: some(int64(retained.len))))
  initUploadSource(
    openCursor, replayable = true, size = some(int64(retained.len)))

proc openCursor*(source: UploadSource): Future[UploadCursor] {.async.} =
  ## Opens and validates one fresh cursor for a transport attempt.
  ##
  ## Callers that open a cursor directly must close it, normally from a
  ## `finally` block. The built-in HTTP transport performs this cleanup under
  ## `noCancel`.
  if source.openImpl.isNil:
    raise newException(ValueError, "upload source is not initialized")
  let cursor = await source.openImpl()
  if cursor.isNil or cursor.readImpl.isNil or cursor.closedValue:
    raise newException(ValueError, "upload source returned an invalid cursor")
  if source.size.isSome:
    cursor.expectedSizeValue = source.size
  return cursor

proc readChunk*(cursor: UploadCursor,
                maxBytes = DefaultUploadChunkBytes): Future[seq[byte]] {.
                async.} =
  ## Reads one bounded chunk and enforces a declared source size.
  ##
  ## An empty result is EOF. The source is rejected if it returns more than
  ## `maxBytes`, exceeds its declared size, or reaches EOF before that size.
  if cursor.isNil or cursor.closedValue:
    raise newException(ValueError, "upload cursor is closed")
  if maxBytes <= 0:
    raise newException(ValueError, "upload chunk size must be positive")
  let chunk = await cursor.readImpl(maxBytes)
  if chunk.len > maxBytes:
    raise newException(ValueError, "upload source exceeded the chunk limit")
  let chunkLength = int64(chunk.len)
  if cursor.consumedValue > high(int64) - chunkLength:
    raise newException(UploadLengthError, "upload byte count overflow")
  let nextConsumed = cursor.consumedValue + chunkLength
  if cursor.expectedSizeValue.isSome and
      nextConsumed > cursor.expectedSizeValue.get():
    raise newException(UploadLengthError,
      "upload source exceeded its declared size")
  cursor.consumedValue = nextConsumed
  if chunk.len == 0 and cursor.expectedSizeValue.isSome and
      cursor.consumedValue != cursor.expectedSizeValue.get():
    raise newException(UploadLengthError,
      "upload source ended before its declared size")
  return chunk

proc close*(cursor: UploadCursor): Future[void] =
  ## Closes a cursor once. Repeated calls do not invoke its close hook again.
  if cursor.isNil or cursor.closedValue:
    return readyVoid()
  cursor.closedValue = true
  if cursor.closeImpl.isNil:
    readyVoid()
  else:
    cursor.closeImpl()

func consumed*(cursor: UploadCursor): int64 =
  ## Returns bytes accepted from the source during this attempt.
  if cursor.isNil: 0 else: cursor.consumedValue

func expectedSize*(cursor: UploadCursor): Option[int64] =
  ## Returns the exact size enforced by this cursor, when known.
  if cursor.isNil: none(int64) else: cursor.expectedSizeValue

func isClosed*(cursor: UploadCursor): bool =
  ## Reports whether cursor cleanup has begun or completed.
  cursor.isNil or cursor.closedValue

func validQuotedHeaderValue(value: string; allowEmpty: bool): bool =
  if value.len == 0:
    return allowEmpty
  for character in value:
    let ordinal = ord(character)
    if ordinal < 0x20 or ordinal > 0x7e or character in {'"', '\\'}:
      return false
  true

func validAttachmentText(value: string): bool =
  value.validateUtf8() < 0 and value.runeLen <= MaxAttachmentTextRunes

func validAttachmentFilename(value: string): bool =
  value.validAttachmentText() and
    value.validQuotedHeaderValue(allowEmpty = false)

func isTokenCharacter(character: char): bool =
  character in {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&',
    '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}

func validContentType*(value: string): bool =
  ## Accepts one simple `type/subtype` value safe for a MIME part header.
  let separator = value.find('/')
  if separator <= 0 or separator != value.rfind('/') or
      separator == value.high:
    return false
  for index, character in value:
    if index != separator and not character.isTokenCharacter():
      return false
  true

func validBoundary*(value: string): bool =
  ## Checks the subset accepted by Chronos before its assertion boundary.
  if value.len == 0 or value.len > 70:
    return false
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '\'', '(', ')',
        '+', ',', '-', '.', '/', ':', '=', '?', '_'}:
      return false
  true

func keepAttachment*(existingId: AttachmentId): AttachmentEdit =
  ## Retains one existing attachment.
  AttachmentEdit(kind: aekKeep, existingId: existingId)

proc updateAttachment*(existingId: AttachmentId,
                       description = leaveUnchanged[string](),
                       spoiler = leaveUnchanged[bool]()): AttachmentEdit =
  ## Retains an attachment and patches supported nullable metadata.
  if description.isSet and not description.get().validAttachmentText():
    raise newException(ValueError,
      "attachment description exceeds Discord's text limit")
  AttachmentEdit(
    kind: aekUpdate,
    existingId: existingId,
    description: description,
    spoiler: spoiler
  )

proc uploadAttachment*(filename: string, source: UploadSource,
                       contentType = DefaultUploadContentType,
                       description = leaveUnchanged[string](),
                       spoiler = leaveUnchanged[bool]()): AttachmentEdit =
  ## Adds a source-backed upload with three-state nullable metadata.
  if not filename.validAttachmentFilename():
    raise newException(ValueError, "upload filename is not header-safe")
  if not contentType.validContentType():
    raise newException(ValueError, "upload content type is not header-safe")
  if source.openImpl.isNil:
    raise newException(ValueError, "upload source is not initialized")
  if description.isSet and not description.get().validAttachmentText():
    raise newException(ValueError,
      "attachment description exceeds Discord's text limit")
  AttachmentEdit(
    kind: aekUpload,
    filename: filename,
    contentType: contentType,
    description: description,
    spoiler: spoiler,
    source: source
  )

proc add*(plan: var AttachmentPlan, edit: sink AttachmentEdit) =
  ## Adds one attachment edit.
  plan.edits.add edit

proc validate*(plan: AttachmentPlan): seq[string] =
  ## Returns all ordering, identity, source, and header problems.
  if plan.edits.len > MaxMessageAttachments:
    result.add "attachment count exceeds Discord's limit"
  var existingIds = initHashSet[AttachmentId]()
  var sawUpload = false
  for index, edit in plan.edits:
    case edit.kind
    of aekKeep, aekUpdate:
      if sawUpload:
        result.add $index & ": existing attachments must precede uploads"
      if edit.existingId.toUint64() == 0:
        result.add $index & ": existing attachment ID is zero"
      elif edit.existingId in existingIds:
        result.add $index & ": duplicate existing attachment ID"
      else:
        existingIds.incl edit.existingId
    of aekUpload:
      sawUpload = true
      if not edit.filename.validAttachmentFilename():
        result.add $index & ": upload filename is not header-safe"
      if not edit.contentType.validContentType():
        result.add $index & ": upload content type is not header-safe"
      if edit.source.openImpl.isNil:
        result.add $index & ": upload source is not initialized"
      if edit.source.size.isSome and edit.source.size.get() < 0:
        result.add $index & ": upload source size is negative"
    if edit.description.isSet and
        not edit.description.get().validAttachmentText():
      result.add $index & ": attachment description exceeds text limit"

func replayable*(plan: AttachmentPlan): bool =
  ## Reports whether every upload can be reopened for another attempt.
  for edit in plan.edits:
    if edit.kind == aekUpload and not edit.source.replayable:
      return false
  true

proc attachmentsJson*(plan: AttachmentPlan): JsonNode =
  ## Produces Discord attachment metadata without opening upload sources.
  result = newJArray()
  var uploadIndex = 0
  for edit in plan.edits:
    let item = newJObject()
    case edit.kind
    of aekKeep, aekUpdate:
      item["id"] = %($edit.existingId)
    of aekUpload:
      item["id"] = %uploadIndex
      item["filename"] = %edit.filename
      inc uploadIndex
    case edit.description.kind
    of PatchKind.LeaveUnchanged:
      discard
    of PatchKind.ClearValue:
      item["description"] = newJNull()
    of PatchKind.SetValue:
      item["description"] = %edit.description.value
    case edit.spoiler.kind
    of PatchKind.LeaveUnchanged:
      discard
    of PatchKind.ClearValue:
      item["is_spoiler"] = newJNull()
    of PatchKind.SetValue:
      item["is_spoiler"] = %edit.spoiler.value
    result.add item

proc newBoundary(): string =
  result = "cordnim-"
  for value in urandom(16):
    result.add toHex(value, 2).toLowerAscii()

proc initMultipartBody*(payload: JsonNode, attachments: sink AttachmentPlan,
                        boundary = ""): MultipartBody =
  ## Builds a stable multipart body and inserts Discord attachment metadata.
  if payload.isNil or payload.kind != JObject:
    raise newException(ValueError, "multipart payload_json must be an object")
  let problems = attachments.validate()
  if problems.len != 0:
    raise newException(ValueError, problems.join("; "))
  let selectedBoundary = if boundary.len == 0: newBoundary() else: boundary
  if not selectedBoundary.validBoundary():
    raise newException(ValueError, "multipart boundary is invalid")

  let document = payload.copy()
  document["attachments"] = attachments.attachmentsJson()
  let encoded = $document
  result.boundaryValue = selectedBoundary
  result.payloadJsonValue = newSeq[byte](encoded.len)
  for index, character in encoded:
    result.payloadJsonValue[index] = byte(ord(character))
  result.attachmentsValue = attachments

func boundary*(body: MultipartBody): lent string =
  ## Returns the stable boundary selected during multipart construction.
  body.boundaryValue

func payloadJson*(body: MultipartBody): lent seq[byte] =
  ## Borrows the frozen encoded `payload_json` part for transport writes.
  body.payloadJsonValue

iterator uploads*(body: MultipartBody): AttachmentEdit =
  ## Yields the frozen upload operations in Discord file-index order.
  for edit in body.attachmentsValue.edits:
    if edit.kind == aekUpload:
      yield edit

proc validate*(body: MultipartBody): seq[string] =
  ## Returns body-level validation problems before Chronos assertions run.
  if not body.boundaryValue.validBoundary():
    result.add "multipart boundary is invalid"
  if body.payloadJsonValue.len == 0:
    result.add "multipart payload_json is empty"
  result.add body.attachmentsValue.validate()

func replayable*(body: MultipartBody): bool =
  ## Reports whether every upload source can be reopened.
  body.attachmentsValue.replayable()

func partPrefixLength(boundary, name, filename, contentType: string): int64 =
  result = int64(boundary.len + 2)
  result += int64("Content-Disposition: form-data; name=\"\"".len + name.len)
  if filename.len != 0:
    result += int64("; filename=\"\"".len + filename.len)
  result += 2 # Content-Disposition CRLF.
  result += int64("Content-Type: \r\n".len + contentType.len)
  result += 2 # Empty line after part headers.

func checkedAdd(total: var int64, value: int64): bool =
  if value < 0 or total > high(int64) - value:
    return false
  total += value
  true

func contentLength*(body: MultipartBody): Option[int64] =
  ## Computes exact multipart framing length when every source has a size.
  var total = 2'i64 # Initial `--` before the first boundary.
  let payloadPrefix = partPrefixLength(
    body.boundaryValue, "payload_json", "", "application/json")
  if not total.checkedAdd(payloadPrefix) or
      not total.checkedAdd(int64(body.payloadJsonValue.len)) or
      not total.checkedAdd(4): # `\r\n--` after the part.
    return none(int64)

  var uploadIndex = 0
  for edit in body.attachmentsValue.edits:
    if edit.kind == aekUpload:
      if edit.source.size.isNone:
        return none(int64)
      let prefix = partPrefixLength(
        body.boundaryValue,
        "files[" & $uploadIndex & "]",
        edit.filename,
        edit.contentType
      )
      if not total.checkedAdd(prefix) or
          not total.checkedAdd(edit.source.size.get()) or
          not total.checkedAdd(4):
        return none(int64)
      inc uploadIndex

  if not total.checkedAdd(int64(body.boundaryValue.len + 4)):
    return none(int64)
  some(total)
