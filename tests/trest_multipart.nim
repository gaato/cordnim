import std/[json, options, os, unittest]

import cordnim/rest
import cordnim/core/ids

suite "streamed attachments":
  test "upload streams are consumed in bounded chunks":
    let path = getTempDir() / "cordnim-upload-stream.txt"
    writeFile(path, "abcdefghij")
    var stream = openUploadStream(path)
    check stream.isOpen
    check stream.readChunk(4) == @[byte 'a', byte 'b', byte 'c', byte 'd']
    check stream.consumed == 4
    stream.close()
    check not stream.isOpen

  test "attachment metadata preserves keep update and upload semantics":
    let path = getTempDir() / "cordnim-upload-plan.txt"
    writeFile(path, "payload")
    var plan: AttachmentPlan
    plan.add keepAttachment(toId(AttachmentId, 100))
    plan.add updateAttachment(
      toId(AttachmentId, 101),
      description = some("diagram"), spoiler = some(true)
    )
    plan.add uploadAttachment("report.txt", openUploadStream(path))
    check plan.validate().len == 0
    let metadata = plan.attachmentsJson()
    check metadata.len == 3
    check metadata[1]["description"].getStr() == "diagram"
    check metadata[2]["id"].getStr() == "0"

  static:
    doAssert not compiles(block:
      var first: UploadStream
      var second = dup(first)
      discard second
    )
