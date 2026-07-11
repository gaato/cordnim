import std/assertions

import cordnim/core/fields

block discordFieldStates:
  let missing = absent[string]()
  let null = nullValue[string]()
  let actual = present("cordnim")

  doAssert missing.kind == FieldKind.Absent
  doAssert missing.isAbsent
  doAssert null.isNull
  doAssert actual.isPresent
  doAssert actual.get == "cordnim"
  doAssert actual.valueOr("fallback") == "cordnim"
  doAssert missing.valueOr("fallback") == "fallback"

  doAssertRaises ValueError:
    discard missing.get
  doAssertRaises ValueError:
    discard null.get

block defaultFieldIsAbsent:
  let field = DiscordField[int]()
  doAssert field.isAbsent

block patchStates:
  let untouched = leaveUnchanged[string]()
  let cleared = clearValue[string]()
  let updated = setValue("new")

  doAssert untouched.isLeaveUnchanged
  doAssert cleared.isClear
  doAssert updated.isSet
  doAssert updated.get == "new"
  doAssert cleared.valueOr("fallback") == "fallback"

  doAssertRaises ValueError:
    discard untouched.get
  doAssertRaises ValueError:
    discard cleared.get

block defaultPatchLeavesUnchanged:
  let patch = Patch[int]()
  doAssert patch.isLeaveUnchanged
