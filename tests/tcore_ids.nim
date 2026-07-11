import std/[assertions, hashes, tables]

import cordnim/core/ids

block typedRoundTrip:
  let user = parseId[UserKind]("18446744073709551615")
  doAssert user.toUint64 == high(uint64)
  doAssert $user == "18446744073709551615"
  doAssert parseId(UserId, "42") == toId(UserId, 42'u64)
  doAssert toId[GuildKind](7'u64) == parseId[GuildKind]("7")
  doAssert $parseId[UserKind]("00042") == "42"
  doAssert parseId[UserKind]("0").toUint64 == 0'u64

block comparisonsAndHash:
  let low = toId[MessageKind](10'u64)
  let high = toId[MessageKind](11'u64)
  doAssert low < high
  doAssert low <= low
  doAssert cmp(low, high) < 0
  doAssert hash(low) == hash(toId[MessageKind](10'u64))

  var values = initTable[MessageId, string]()
  values[low] = "message"
  doAssert values[low] == "message"

block invalidText:
  for invalid in ["", "-1", "+1", " 1", "1 ", "1_0", "x"]:
    doAssertRaises ValueError:
      discard parseId[UserKind](invalid)

  doAssertRaises ValueError:
    discard parseId[UserKind]("18446744073709551616")

block semanticAliasesAreDistinct:
  doAssert not compiles(block:
    let guild = toId[GuildKind](1'u64)
    let message = toId[MessageKind](1'u64)
    discard guild == message
  )
