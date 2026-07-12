## Deterministic byte and nonce source for tests that must avoid real entropy.
##
## Production code that would otherwise read cryptographic randomness or a nonce
## generator can take bytes from a `FixedEntropy` instead. The source hands out
## a scripted byte sequence in order, tracks how much remains, and fails loudly
## on exhaustion so a test can never silently fall back to real randomness.

type
  EntropyExhaustedError* = object of CatchableError ## Raised when more bytes are
    ## requested than the fixed source was primed with.

  FixedEntropy* = object ## Ordered, replayable byte source with an explicit
    ## cursor and remaining count.
    bytes: seq[byte] ## Complete scripted byte reservoir.
    cursor: int ## Index of the next byte to hand out.

func initFixedEntropy*(bytes: sink seq[byte]): FixedEntropy =
  ## Creates a source that hands out `bytes` in order.
  FixedEntropy(bytes: bytes, cursor: 0)

func fixedEntropyFromString*(value: string): FixedEntropy =
  ## Creates a source from the raw bytes of `value` for readable fixtures.
  var data = newSeq[byte](value.len)
  for index, character in value:
    data[index] = byte(character)
  FixedEntropy(bytes: data, cursor: 0)

func repeatingEntropy*(pattern: openArray[byte], total: int): FixedEntropy =
  ## Creates a source of `total` bytes cycling through a non-empty pattern.
  if pattern.len == 0:
    raise newException(ValueError, "entropy pattern must not be empty")
  if total < 0:
    raise newException(ValueError, "entropy length must not be negative")
  var data = newSeq[byte](total)
  for index in 0 ..< total:
    data[index] = pattern[index mod pattern.len]
  FixedEntropy(bytes: data, cursor: 0)

func remaining*(entropy: FixedEntropy): int =
  ## Returns the number of bytes still available from the source.
  entropy.bytes.len - entropy.cursor

func consumed*(entropy: FixedEntropy): int =
  ## Returns the number of bytes already handed out.
  entropy.cursor

func isExhausted*(entropy: FixedEntropy): bool =
  ## Reports whether no bytes remain.
  entropy.cursor >= entropy.bytes.len

proc nextByte*(entropy: var FixedEntropy): byte =
  ## Returns the next byte, raising `EntropyExhaustedError` when depleted.
  if entropy.cursor >= entropy.bytes.len:
    raise newException(EntropyExhaustedError,
      "fixed entropy source is exhausted")
  result = entropy.bytes[entropy.cursor]
  inc entropy.cursor

proc nextBytes*(entropy: var FixedEntropy, count: int): seq[byte] =
  ## Returns the next `count` bytes, raising before handing out a short read.
  ##
  ## Exhaustion is checked before any byte is consumed so a failed request never
  ## advances the cursor and leaves the source in a partially drained state.
  if count < 0:
    raise newException(ValueError, "requested byte count must not be negative")
  if count > entropy.remaining:
    raise newException(EntropyExhaustedError,
      "fixed entropy source has " & $entropy.remaining &
      " bytes but " & $count & " were requested")
  result = entropy.bytes[entropy.cursor ..< entropy.cursor + count]
  entropy.cursor += count

proc nextHex*(entropy: var FixedEntropy, byteCount: int): string =
  ## Returns `byteCount` bytes rendered as a lowercase hex nonce string.
  const digits = "0123456789abcdef"
  let raw = entropy.nextBytes(byteCount)
  result = newStringOfCap(raw.len * 2)
  for value in raw:
    result.add(digits[int(value shr 4)])
    result.add(digits[int(value and 0x0F)])

proc assertRemaining*(entropy: FixedEntropy, expected: int) =
  ## Asserts that exactly `expected` bytes remain unused.
  if entropy.remaining != expected:
    raise newException(AssertionDefect,
      "expected " & $expected & " entropy bytes remaining, found " &
      $entropy.remaining)

proc assertExhausted*(entropy: FixedEntropy) =
  ## Asserts that the source has handed out every byte it was primed with.
  if not entropy.isExhausted:
    raise newException(AssertionDefect,
      "expected entropy source to be exhausted, " & $entropy.remaining &
      " bytes remain")
