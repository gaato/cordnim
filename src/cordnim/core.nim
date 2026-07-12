## Public protocol values shared by raw, runtime, and application code.
##
## Import this module for kind-safe snowflakes, arbitrary-width Discord bit
## fields, forward-compatible enums, three-state JSON fields and patches,
## typed errors, and redacted credentials. These values perform no I/O. Wire
## conversion stays explicit so an application cannot mix ID domains or lose
## unknown enum values and flag bits by accident.

import cordnim/core/[bits, errors, fields, ids, open_enums, permissions,
  secrets]

export bits, errors, fields, ids, open_enums, permissions, secrets

runnableExamples:
  let userId = parseId(UserId, "123456789")
  doAssert userId.toUint64 == 123456789'u64

  let decoded = present("display name")
  doAssert decoded.isPresent
  doAssert decoded.get == "display name"

  let description = clearValue[string]()
  doAssert description.isClear
