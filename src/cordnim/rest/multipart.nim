## Move-only upload streams and attachment edit plans.
##
## This module keeps file bodies out of the JSON model and lets the transport
## pull bounded chunks while constructing multipart payloads.

import std/[json, options, os, sets]

import cordnim/core/ids

type
  UploadStream* = object ## Move-only owner of a readable upload file.
    handle: File
    path: string
    size*: int64 ## File size observed when the stream was opened.
    consumed*: int64 ## Bytes returned by `readChunk`.

  AttachmentEditKind* = enum ## Operation applied to one attachment.
    aekKeep, ## Retain an existing attachment unchanged.
    aekUpdate, ## Retain and update existing metadata.
    aekUpload ## Add one streamed attachment.

  AttachmentEdit* = object ## One existing or new attachment operation.
    kind*: AttachmentEditKind ## Operation kind.
    existingId*: AttachmentId ## Existing attachment snowflake for keep/update.
    filename*: string ## Upload filename for new attachments.
    description*: Option[string] ## Accessible attachment description.
    spoiler*: Option[bool] ## Optional spoiler metadata update.
    upload*: UploadStream ## Stream present only for `aekUpload`.

  AttachmentPlan* = object ## Ordered attachment operations for a message edit.
    edits*: seq[AttachmentEdit] ## Existing items first, then new uploads.

proc `=destroy`*(stream: UploadStream) =
  ## Closes an owned file when its stream leaves scope.
  if stream.handle != nil:
    close(stream.handle)

proc `=wasMoved`*(stream: var UploadStream) =
  ## Clears ownership after a sink move.
  stream.handle = nil
  stream.path.setLen(0)
  stream.size = 0
  stream.consumed = 0

proc `=copy`*(destination: var UploadStream,
              source: UploadStream) {.error.}
  ## Upload streams cannot be copied because they own a file cursor.

proc `=dup`*(source: UploadStream): UploadStream {.error.}
  ## Upload streams cannot be duplicated implicitly.

proc openUploadStream*(path: string): UploadStream =
  ## Opens `path` for bounded streaming.
  ##
  ## Raises `IOError` when the file cannot be opened.
  var file: File
  if not open(file, path, fmRead):
    raise newException(IOError, "cannot open upload: " & path)
  result.handle = file
  result.path = path
  result.size = getFileSize(path)

func isOpen*(stream: UploadStream): bool =
  ## Reports whether the stream still owns an open file.
  stream.handle != nil

proc close*(stream: var UploadStream) =
  ## Closes the stream early. Calling it more than once is harmless.
  if stream.handle != nil:
    close(stream.handle)
    stream.handle = nil

proc readChunk*(stream: var UploadStream, maxBytes = 64 * 1_024): seq[byte] =
  ## Reads at most `maxBytes` without buffering the remaining upload.
  if maxBytes <= 0:
    raise newException(ValueError, "upload chunk size must be positive")
  if stream.handle == nil:
    return @[]
  result = newSeq[byte](maxBytes)
  let count = readBuffer(stream.handle, addr result[0], maxBytes)
  result.setLen(count)
  stream.consumed += count

func keepAttachment*(existingId: AttachmentId): AttachmentEdit =
  ## Retains one existing attachment.
  AttachmentEdit(kind: aekKeep, existingId: existingId)

func updateAttachment*(existingId: AttachmentId,
                       description = none(string),
                       spoiler = none(bool)): AttachmentEdit =
  ## Retains an attachment and changes supported metadata.
  AttachmentEdit(
    kind: aekUpdate,
    existingId: existingId,
    description: description,
    spoiler: spoiler
  )

proc uploadAttachment*(filename: string, stream: sink UploadStream,
                       description = none(string),
                       spoiler = none(bool)): AttachmentEdit =
  ## Moves a stream into a new attachment edit.
  AttachmentEdit(
    kind: aekUpload,
    filename: filename,
    description: description,
    spoiler: spoiler,
    upload: stream
  )

proc add*(plan: var AttachmentPlan, edit: sink AttachmentEdit) =
  ## Adds an attachment edit while preserving its stream ownership.
  plan.edits.add move edit

proc validate*(plan: var AttachmentPlan): seq[string] =
  ## Returns all duplicate, empty, and stream-state problems.
  var existingIds = initHashSet[AttachmentId]()
  var filenames = initHashSet[string]()
  var sawUpload = false
  for index in 0..<plan.edits.len:
    let edit {.cursor.} = plan.edits[index]
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
      if edit.filename.len == 0:
        result.add $index & ": upload filename is empty"
      elif edit.filename in filenames:
        result.add $index & ": duplicate upload filename"
      else:
        filenames.incl edit.filename
      if not edit.upload.isOpen:
        result.add $index & ": upload stream is closed"

proc attachmentsJson*(plan: var AttachmentPlan): JsonNode =
  ## Produces Discord's attachment metadata array without reading file bodies.
  result = newJArray()
  var uploadIndex = 0
  for index in 0..<plan.edits.len:
    let edit {.cursor.} = plan.edits[index]
    let item = newJObject()
    case edit.kind
    of aekKeep, aekUpdate:
      item["id"] = %($edit.existingId)
    of aekUpload:
      item["id"] = %($uploadIndex)
      item["filename"] = %edit.filename
      inc uploadIndex
    if edit.description.isSome:
      item["description"] = %edit.description.get()
    if edit.spoiler.isSome:
      item["spoiler"] = %edit.spoiler.get()
    result.add item
