## Arbitrary-width Discord bit fields with canonical decimal encoding.

import std/[enumutils, hashes, strutils, typetraits]

const
  defaultMaxBitsDigits* = 1024 ## Default input bound for decimal bit fields
                               ## received from Discord.

  halfLimbMask = 0xffff_ffff'u64
  decimalChunkBase = 1_000_000_000'u64
  decimalChunkDigits = 9

type
  DiscordBits*[Domain] = object ## A non-negative arbitrary-width bit field.
                                ##
                                ## The domain parameter prevents mixing
                                ## unrelated Discord flag sets. Storage is
                                ## canonicalized, so unknown high bits survive
                                ## decode and re-encoding.
    limbs: seq[uint64]

iterator declaredMembers[T: enum](enumType: typedesc[T]): T =
  when T is HoleyEnum:
    for value in enumutils.items(enumType):
      yield value
  else:
    for value in enumType:
      yield value

proc normalize[Domain](bits: var DiscordBits[Domain]) =
  while bits.limbs.len > 0 and bits.limbs[^1] == 0'u64:
    bits.limbs.setLen(bits.limbs.len - 1)

proc multiplyByTenAndAdd(limbs: var seq[uint64]; digit: uint64) =
  # Split each limb into 32-bit halves so multiplication never needs uint128,
  # which keeps the implementation portable across Cordnim's Tier 1 targets.
  var carry = digit
  for index in 0..<limbs.len:
    let lowProduct = (limbs[index] and halfLimbMask) * 10'u64 +
      carry
    let highProduct = (limbs[index] shr 32) * 10'u64 +
      (lowProduct shr 32)
    limbs[index] = (highProduct shl 32) or
      (lowProduct and halfLimbMask)
    carry = highProduct shr 32
  if carry != 0'u64:
    limbs.add carry

proc divideByDecimalChunk[Domain](bits: var DiscordBits[Domain]): uint64 =
  # Base 1e9 produces decimal chunks without platform-specific big integers.
  var remainder = 0'u64
  for index in countdown(bits.limbs.high, 0):
    let limb = bits.limbs[index]
    var current = (remainder shl 32) or (limb shr 32)
    let quotientHigh = current div decimalChunkBase
    remainder = current mod decimalChunkBase

    current = (remainder shl 32) or (limb and halfLimbMask)
    let quotientLow = current div decimalChunkBase
    remainder = current mod decimalChunkBase
    bits.limbs[index] = (quotientHigh shl 32) or quotientLow

  bits.normalize()
  remainder

func initDiscordBits*[Domain](): DiscordBits[Domain] =
  ## Returns an empty bit field.
  DiscordBits[Domain]()

proc initDiscordBits*[Domain](low: uint64): DiscordBits[Domain] =
  ## Constructs a bit field from its least-significant 64 bits.
  if low != 0'u64:
    result.limbs.add low

proc initDiscordBits*[Domain](limbs: openArray[uint64]):
    DiscordBits[Domain] =
  ## Constructs a bit field from little-endian limbs and canonicalizes it.
  result.limbs = @limbs
  result.normalize()

proc parseDiscordBits*[Domain](text: string;
    maxDigits: Natural = defaultMaxBitsDigits): DiscordBits[Domain] =
  ## Parses a bounded, unsigned decimal bit field.
  ##
  ## Leading zeroes are accepted; output always uses canonical decimal form.
  if text.len == 0:
    raise newException(ValueError, "Discord bit field must not be empty")
  if text.len > maxDigits:
    raise newException(ValueError, "Discord bit field exceeds digit limit")

  for character in text:
    if character notin {'0'..'9'}:
      raise newException(ValueError,
        "Discord bit field must contain only decimal digits")
    result.limbs.multiplyByTenAndAdd(
      uint64(ord(character) - ord('0')))
  result.normalize()

func isZero*[Domain](bits: DiscordBits[Domain]): bool {.inline.} =
  ## Returns whether no bit is set.
  bits.limbs.len == 0

func lowUint64*[Domain](bits: DiscordBits[Domain]): uint64 {.inline.} =
  ## Returns the low limb, truncating any higher bits.
  if bits.limbs.len == 0:
    0'u64
  else:
    bits.limbs[0]

proc toUint64*[Domain](bits: DiscordBits[Domain]): uint64 =
  ## Returns the exact value or raises `ValueError` if it does not fit.
  if bits.limbs.len > 1:
    raise newException(ValueError, "Discord bit field exceeds uint64")
  bits.lowUint64

func toLimbs*[Domain](bits: DiscordBits[Domain]): seq[uint64] =
  ## Returns a copy of the canonical little-endian limbs.
  bits.limbs

func containsAll*[Domain](actual, required: DiscordBits[Domain]): bool =
  ## Reports whether every bit in `required` is present in `actual`.
  ##
  ## This compares every arbitrary-width limb, so future Discord bits above 63
  ## participate instead of being truncated to a machine integer.
  for index, requiredLimb in required.limbs:
    let actualLimb =
      if index < actual.limbs.len: actual.limbs[index] else: 0'u64
    if (actualLimb and requiredLimb) != requiredLimb:
      return false
  true

func missingBits*[Domain](actual, required: DiscordBits[Domain]):
    DiscordBits[Domain] =
  ## Returns the required bits absent from `actual`.
  result.limbs = newSeq[uint64](required.limbs.len)
  for index, requiredLimb in required.limbs:
    let actualLimb =
      if index < actual.limbs.len: actual.limbs[index] else: 0'u64
    result.limbs[index] = requiredLimb and not actualLimb
  result.normalize()

func containsBit*[Domain](bits: DiscordBits[Domain];
    position: Natural): bool =
  ## Tests an arbitrary bit position, including positions above 63.
  let limbIndex = position div 64
  limbIndex < bits.limbs.len and
    (bits.limbs[limbIndex] and (1'u64 shl (position mod 64))) != 0'u64

proc inclBit*[Domain](bits: var DiscordBits[Domain]; position: Natural) =
  ## Sets an arbitrary bit position, growing storage when necessary.
  let limbIndex = position div 64
  if bits.limbs.len <= limbIndex:
    bits.limbs.setLen(limbIndex + 1)
  bits.limbs[limbIndex] = bits.limbs[limbIndex] or
    (1'u64 shl (position mod 64))

proc exclBit*[Domain](bits: var DiscordBits[Domain]; position: Natural) =
  ## Clears an arbitrary bit position and restores canonical storage.
  let limbIndex = position div 64
  if limbIndex < bits.limbs.len:
    bits.limbs[limbIndex] = bits.limbs[limbIndex] and
      not (1'u64 shl (position mod 64))
    bits.normalize()

func contains*[Domain: enum](bits: DiscordBits[Domain];
    value: Domain): bool =
  ## Tests the bit whose position is the enum member's ordinal.
  let position = ord(value)
  position >= 0 and bits.containsBit(position)

proc incl*[Domain: enum](bits: var DiscordBits[Domain];
    value: Domain) =
  ## Includes the bit whose position is the enum member's ordinal.
  let position = ord(value)
  if position < 0:
    raise newException(ValueError,
      "Discord bit enum ordinals must be non-negative")
  bits.inclBit(position)

proc excl*[Domain: enum](bits: var DiscordBits[Domain];
    value: Domain) =
  ## Excludes the bit whose position is the enum member's ordinal.
  let position = ord(value)
  if position >= 0:
    bits.exclBit(position)

proc initDiscordBits*[Domain: enum](values: openArray[Domain]):
    DiscordBits[Domain] =
  ## Constructs a bit field from known enum members.
  for value in values:
    result.incl(value)

proc unknownBits*[Domain: enum](bits: DiscordBits[Domain]):
    DiscordBits[Domain] =
  ## Returns bits that do not correspond to a declared enum member.
  result = bits
  for value in declaredMembers(Domain):
    result.excl(value)

proc knownBits*[Domain: enum](bits: DiscordBits[Domain]):
    DiscordBits[Domain] =
  ## Returns only bits that correspond to declared enum members.
  for value in declaredMembers(Domain):
    if bits.contains(value):
      result.incl(value)

proc toDecimal*[Domain](bits: DiscordBits[Domain]): string =
  ## Returns the canonical unsigned decimal representation.
  if bits.isZero:
    return "0"

  var quotient = bits
  var chunks: seq[uint32]
  while not quotient.isZero:
    chunks.add(uint32(quotient.divideByDecimalChunk()))

  result = $chunks[^1]
  if chunks.len > 1:
    for index in countdown(chunks.high - 1, 0):
      let chunk = $chunks[index]
      result.add(repeat('0', decimalChunkDigits - chunk.len))
      result.add chunk

func `==`*[Domain](left, right: DiscordBits[Domain]): bool {.inline.} =
  ## Compares canonical values within the same flag domain.
  left.limbs == right.limbs

func hash*[Domain](bits: DiscordBits[Domain]): Hash =
  ## Hashes every limb so high, unknown bits participate in the key.
  var value: Hash = 0
  for limb in bits.limbs:
    value = value !& hash(limb)
  !$value

proc `$`*[Domain](bits: DiscordBits[Domain]): string =
  ## Formats the value in Discord's decimal wire representation.
  bits.toDecimal
