import std/[json, options, os, strutils, unittest]

import chronos

import cordnim/core/ids
import cordnim/rest

type
  CursorState = ref object
    reads: int
    closes: int

func bytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for index, character in value:
    result[index] = byte(ord(character))

func text(value: openArray[byte]): string =
  result = newString(value.len)
  for index, item in value:
    result[index] = char(item)

proc completed[T](value: sink T): Future[T] =
  result = newFuture[T]("test.rest.multipart.completed")
  result.complete(value)

proc completedVoid(): Future[void] =
  result = newFuture[void]("test.rest.multipart.completed-void")
  result.complete()

proc shortSizedSource(state: CursorState): UploadSource =
  let open: UploadOpenProc = proc(): Future[UploadCursor]
      {.gcsafe, raises: [].} =
    let read: UploadReadProc = proc(maxBytes: int): Future[seq[byte]]
        {.gcsafe, raises: [].} =
      discard maxBytes
      inc state.reads
      if state.reads == 1:
        completed(bytes("abc"))
      else:
        completed(newSeq[byte]())
    let close: UploadCloseProc = proc(): Future[void]
        {.gcsafe, raises: [].} =
      inc state.closes
      completedVoid()
    let opened = newFuture[UploadCursor]("test.rest.multipart.open")
    try:
      opened.complete(newUploadCursor(read, close))
    except CatchableError as error:
      opened.fail(error)
    opened
  initUploadSource(open, replayable = true, size = some(4'i64))

suite "replayable multipart uploads":
  test "multipart construction freezes metadata and upload selection":
    var plan: AttachmentPlan
    plan.add uploadAttachment(
      "first.txt", memoryUploadSource(bytes("first")))
    var payload = %*{"content": "before"}
    let body = initMultipartBody(
      payload, plan, boundary = "cordnim-frozen")

    payload["content"] = %"after"
    plan.add uploadAttachment(
      "second.txt", memoryUploadSource(bytes("second")))

    let frozen = parseJson(body.payloadJson.text())
    check frozen["content"].getStr() == "before"
    check frozen["attachments"].len == 1
    var uploadCount = 0
    for upload in body.uploads():
      discard upload
      inc uploadCount
    check uploadCount == 1

  test "multipart internals cannot be replaced through accessors":
    static:
      doAssert not compiles((block:
        var plan: AttachmentPlan
        var body = initMultipartBody(
          %*{}, plan, boundary = "cordnim-static")
        body.boundary = "changed"))
      doAssert not compiles((block:
        var plan: AttachmentPlan
        var body = initMultipartBody(
          %*{}, plan, boundary = "cordnim-static")
        body.payloadJson = @[byte 1]))
      doAssert not compiles((block:
        var plan: AttachmentPlan
        var body = initMultipartBody(
          %*{}, plan, boundary = "cordnim-static")
        body.payloadJson[0] = byte 1))

  test "file sources reopen fresh cursors and read bounded chunks":
    let path = getTempDir() / "cordnim-upload-source.txt"
    writeFile(path, "abcdefghij")
    defer:
      removeFile(path)

    let source = fileUploadSource(path)
    check source.replayable
    check source.size == some(10'i64)

    let first = waitFor source.openCursor()
    check waitFor(first.readChunk(4)) == bytes("abcd")
    check waitFor(first.readChunk(4)) == bytes("efgh")
    check first.consumed == 8
    waitFor first.close()
    check first.isClosed

    let second = waitFor source.openCursor()
    check waitFor(second.readChunk(4)) == bytes("abcd")
    waitFor second.close()

  test "zero-byte sources are valid and reach EOF":
    let source = memoryUploadSource(newSeq[byte]())
    check source.size == some(0'i64)
    let cursor = waitFor source.openCursor()
    check waitFor(cursor.readChunk()).len == 0
    check cursor.consumed == 0
    waitFor cursor.close()

  test "declared length mismatches are catchable and close is idempotent":
    let state = CursorState()
    let cursor = waitFor shortSizedSource(state).openCursor()
    check waitFor(cursor.readChunk()) == bytes("abc")
    expect UploadLengthError:
      discard waitFor cursor.readChunk()
    waitFor cursor.close()
    waitFor cursor.close()
    check state.closes == 1

  test "attachment metadata preserves keep update and upload semantics":
    var plan: AttachmentPlan
    plan.add keepAttachment(toId(AttachmentId, 100))
    plan.add updateAttachment(
      toId(AttachmentId, 101),
      description = setValue("diagram"), spoiler = setValue(true)
    )
    plan.add uploadAttachment(
      "report.txt", memoryUploadSource(bytes("payload")),
      contentType = "text/plain",
      spoiler = setValue(true)
    )
    check plan.validate().len == 0
    let metadata = plan.attachmentsJson()
    check metadata.len == 3
    check metadata[1]["description"].getStr() == "diagram"
    check metadata[0]["id"].kind == JString
    check metadata[0]["id"].getStr() == "100"
    check metadata[2]["id"].kind == JInt
    check metadata[2]["id"].getInt() == 0
    check metadata[2]["filename"].getStr() == "report.txt"
    check metadata[1]["is_spoiler"].getBool()
    check metadata[2]["is_spoiler"].getBool()
    check not metadata[1].hasKey("spoiler")
    check not metadata[2].hasKey("spoiler")

  test "attachment patches preserve omit clear and set":
    var plan: AttachmentPlan
    plan.add updateAttachment(
      toId(AttachmentId, 102),
      description = clearValue[string](),
      spoiler = clearValue[bool]()
    )
    plan.add updateAttachment(toId(AttachmentId, 103))
    let metadata = plan.attachmentsJson()
    check metadata[0]["description"].kind == JNull
    check metadata[0]["is_spoiler"].kind == JNull
    check not metadata[1].hasKey("description")
    check not metadata[1].hasKey("is_spoiler")

  test "duplicate upload filenames remain index-addressable":
    let source = memoryUploadSource(bytes("payload"))
    var plan: AttachmentPlan
    plan.add uploadAttachment("same.txt", source)
    plan.add uploadAttachment("same.txt", source)
    check plan.validate().len == 0
    let metadata = plan.attachmentsJson()
    check metadata[0]["id"].getInt() == 0
    check metadata[1]["id"].getInt() == 1
    check metadata[0]["filename"].getStr() == "same.txt"
    check metadata[1]["filename"].getStr() == "same.txt"

  test "unsafe filenames and content types fail before Chronos assertions":
    let source = memoryUploadSource(bytes("payload"))
    for filename in ["", "line\rbreak", "line\nbreak", "nul\0byte",
                     "path\\name.txt", "quote\"name.txt"]:
      expect ValueError:
        discard uploadAttachment(filename, source)
    for contentType in ["", "text", "text/plain; charset=utf-8",
                        "text/plain\r\nX-Evil: yes", "text/pla\\in"]:
      expect ValueError:
        discard uploadAttachment(
          "safe.txt", source, contentType = contentType)

  test "attachment count and text limits use Discord boundaries":
    let source = memoryUploadSource(bytes("payload"))

    var ten: AttachmentPlan
    for index in 0..<MaxMessageAttachments:
      ten.add uploadAttachment($index & ".txt", source)
    check ten.validate().len == 0
    discard initMultipartBody(%*{}, ten, boundary = "cordnim-ten")

    var eleven: AttachmentPlan
    for index in 0..MaxMessageAttachments:
      eleven.add uploadAttachment($index & ".txt", source)
    check eleven.validate().len > 0
    expect ValueError:
      discard initMultipartBody(
        %*{}, eleven, boundary = "cordnim-eleven")

    discard uploadAttachment(repeat("a", MaxAttachmentTextRunes), source)
    expect ValueError:
      discard uploadAttachment(
        repeat("a", MaxAttachmentTextRunes + 1), source)

    let maximumDescription = repeat("あ", MaxAttachmentTextRunes)
    discard updateAttachment(
      toId(AttachmentId, 200), description = setValue(maximumDescription))
    expect ValueError:
      discard updateAttachment(
        toId(AttachmentId, 200),
        description = setValue(maximumDescription & "あ"))

  test "known and unknown source sizes control multipart length":
    var knownPlan: AttachmentPlan
    knownPlan.add uploadAttachment(
      "known.bin", memoryUploadSource(bytes("data")))
    let known = initMultipartBody(
      %*{"content": "hello"}, knownPlan, boundary = "cordnim-known")
    check known.contentLength().isSome

    let open: UploadOpenProc = proc(): Future[UploadCursor]
        {.gcsafe, raises: [].} =
      let read: UploadReadProc = proc(maxBytes: int): Future[seq[byte]]
          {.gcsafe, raises: [].} =
        discard maxBytes
        completed(newSeq[byte]())
      let opened = newFuture[UploadCursor]("test.rest.multipart.open-unknown")
      try:
        opened.complete(newUploadCursor(read))
      except CatchableError as error:
        opened.fail(error)
      opened
    var unknownPlan: AttachmentPlan
    unknownPlan.add uploadAttachment(
      "unknown.bin", initUploadSource(open, replayable = true))
    let unknown = initMultipartBody(
      %*{}, unknownPlan, boundary = "cordnim-unknown")
    check unknown.contentLength().isNone
