## Per-connection Gateway payload decoding: plain JSON or shared-context
## `zlib-stream` transport compression.
##
## Discord's `zlib-stream` transport compression is one continuous zlib stream
## for the life of a connection: every message is inflated through the *same*
## inflate context, whose sliding-window dictionary carries across messages, and
## a logical payload ends at the 4-byte `00 00 ff ff` `Z_SYNC_FLUSH` marker. A
## payload may therefore span several WebSocket messages, so compressed bytes are
## buffered until the marker is seen and only then inflated.
##
## Ownership: zlib retains the address of the `ZStream` passed to
## `inflateInit2`, so the native state lives in an address-stable private heap
## owner. Moving `GatewayMessageDecoder` moves only that owner reference. The
## decoder remains explicitly non-copyable, and the owner's `=destroy` releases
## zlib exactly once. `openZlibStreamContexts` lets tests prove release on scope
## exit, decoder moves, and explicit close.
##
## Safety bounds are separate for the two buffers: the compressed accumulator and
## the inflated output each have an independent ceiling, so neither an oversized
## fragment stream nor a decompression bomb can grow memory without limit.

import std/[json, options, unicode]

import zlib

import ./transport

type
  GatewayDecodeError* = object of CatchableError ## A Gateway message could not be
    ## decoded: wrong frame shape, a malformed or oversized zlib stream, invalid
    ## UTF-8, or invalid JSON. The message names the rule only; it never contains
    ## payload bytes, so a decode failure cannot leak event content or a token.

  GatewayCompression* = enum ## Transport compression negotiated for a connection.
    gatewayCompressionNone, ## Plain UTF-8 JSON text frames.
    gatewayCompressionZlibStream ## One shared zlib stream across binary frames.

  ZlibInflateState = object ## Address-stable native zlib inflate state.
    zs: ZStream
    open: bool ## Whether `zs` holds an initialized context awaiting `inflateEnd`.

  ZlibInflate = ref ZlibInflateState ## Heap owner whose address survives moves.

  GatewayMessageDecoder* = object ## Per-connection decoder state.
    ## Move-only because it owns a `ZlibInflate`; the compiler-generated destructor
    ## releases the inflate context and frees the compressed buffer together.
    compression: GatewayCompression
    inflate: ZlibInflate
    compressed: seq[byte] ## Bytes buffered until the next sync marker.
    maxCompressedBytes: int
    maxInflatedBytes: int

const
  defaultMaxCompressedBytes* = 16 * 1024 * 1024 ## 16 MiB compressed ceiling.
  defaultMaxInflatedBytes* = 64 * 1024 * 1024 ## 64 MiB inflated ceiling.
  inflateScratchBytes = 32 * 1024 ## Per-call inflate output scratch size.
  syncMarker = [0x00'u8, 0x00'u8, 0xff'u8, 0xff'u8]

var activeZlibContexts {.threadvar.}: int
  ## Count of live native inflate contexts on this thread; leak-detection aid.

proc openZlibStreamContexts*(): int {.raises: [].} =
  ## Returns the number of initialized-but-unreleased zlib contexts.
  ##
  ## Exposed for tests: it must return to its prior value after a decoder is
  ## destroyed, moved-from, or closed, proving release happens exactly once.
  activeZlibContexts

proc releaseInflate(ctx: var ZlibInflateState) {.raises: [].} =
  ## Releases the native context once; safe to call repeatedly.
  if ctx.open:
    discard inflateEnd(ctx.zs)
    ctx.open = false
    dec activeZlibContexts

proc `=destroy`(ctx: var ZlibInflateState) =
  releaseInflate(ctx)

# Copying the private ref would create two decoders that mutate and close the
# same inflate stream. Disable copy and dup so ownership can only move.
proc `=copy`(
    dst: var GatewayMessageDecoder; src: GatewayMessageDecoder) {.error:
  "a gateway message decoder owns a zlib context and is move-only".}

proc `=dup`(src: GatewayMessageDecoder): GatewayMessageDecoder {.error:
  "a gateway message decoder owns a zlib context and is move-only".}

func compression*(decoder: GatewayMessageDecoder): GatewayCompression {.
    inline, raises: [].} =
  ## Returns the compression mode this decoder was created for.
  decoder.compression

func bufferedCompressedBytes*(decoder: GatewayMessageDecoder): int {.
    inline, raises: [].} =
  ## Returns bytes buffered while awaiting the next sync marker.
  decoder.compressed.len

proc initGatewayMessageDecoder*(
    compression: GatewayCompression;
    maxCompressedBytes: Positive = defaultMaxCompressedBytes;
    maxInflatedBytes: Positive = defaultMaxInflatedBytes,
): GatewayMessageDecoder {.raises: [GatewayDecodeError].} =
  ## Creates a decoder, initializing a zlib context for `zlib-stream`.
  ##
  ## Raises `GatewayDecodeError` if the native inflate context cannot start.
  result = GatewayMessageDecoder(
    compression: compression,
    maxCompressedBytes: int(maxCompressedBytes),
    maxInflatedBytes: int(maxInflatedBytes),
  )
  if compression == gatewayCompressionZlibStream:
    new(result.inflate)
    # Window bits 15 selects the zlib wrapper Discord uses (not raw deflate).
    if inflateInit2(result.inflate.zs, Z_WINDOW_BITS_15) != Z_OK:
      raise newException(
        GatewayDecodeError, "could not initialize zlib inflate context")
    result.inflate.open = true
    inc activeZlibContexts

proc close*(decoder: var GatewayMessageDecoder) {.raises: [].} =
  ## Releases the zlib context and drops buffered bytes. Idempotent.
  if not decoder.inflate.isNil:
    releaseInflate(decoder.inflate[])
  decoder.compressed.setLen(0)

func endsWithSyncMarker(buffer: seq[byte]): bool {.raises: [].} =
  buffer.len >= syncMarker.len and
    buffer[^4] == syncMarker[0] and buffer[^3] == syncMarker[1] and
    buffer[^2] == syncMarker[2] and buffer[^1] == syncMarker[3]

proc bytesToString(data: openArray[byte]): string {.raises: [].} =
  result = newString(data.len)
  for index, value in data:
    result[index] = char(value)

proc parseValidJson(data: openArray[byte]): JsonNode {.
    raises: [GatewayDecodeError].} =
  ## Validates UTF-8 then parses JSON, never echoing the payload on failure.
  let text = bytesToString(data)
  if text.validateUtf8() != -1:
    raise newException(GatewayDecodeError, "gateway payload is not valid UTF-8")
  try:
    result = parseJson(text)
  except CatchableError:
    raise newException(GatewayDecodeError, "gateway payload is not valid JSON")

proc inflateComplete(
    ctx: ZlibInflate; input: var seq[byte]; maxOut: int): seq[byte] {.
    raises: [GatewayDecodeError].} =
  ## Inflates one marker-terminated chunk through the shared context.
  ##
  ## All input must be consumed at the sync boundary; leftover bytes are trailing
  ## garbage and a hard error. Output is capped at `maxOut`.
  if ctx.isNil or not ctx.open:
    raise newException(GatewayDecodeError, "zlib inflate context is closed")
  var scratch = newSeq[byte](inflateScratchBytes)
  ctx.zs.next_in = addr input[0]
  ctx.zs.avail_in = cuint(input.len)
  while true:
    ctx.zs.next_out = addr scratch[0]
    ctx.zs.avail_out = cuint(scratch.len)
    let availInBefore = ctx.zs.avail_in
    let status = inflate(ctx.zs, Z_SYNC_FLUSH)
    let produced = scratch.len - int(ctx.zs.avail_out)
    let consumed = int(availInBefore) - int(ctx.zs.avail_in)
    if produced > 0:
      if result.len + produced > maxOut:
        raise newException(
          GatewayDecodeError, "inflated gateway payload exceeded its bound")
      let start = result.len
      result.setLen(start + produced)
      copyMem(addr result[start], addr scratch[0], produced)
    case status
    of Z_OK, Z_BUF_ERROR:
      # Terminate at the sync boundary. Output room left over means all pending
      # output was flushed; otherwise loop only if this call made forward
      # progress. The explicit no-progress guard bounds the loop unconditionally,
      # so a misbehaving inflate can never spin: every iteration either breaks,
      # consumes input, or produces output, and output is capped by `maxOut`.
      if ctx.zs.avail_out != 0 or (produced == 0 and consumed == 0):
        break
    else:
      # Z_STREAM_END, Z_NEED_DICT, or any negative code is malformed/unsupported.
      raise newException(GatewayDecodeError, "malformed zlib-stream frame")
  if ctx.zs.avail_in != 0:
    raise newException(
      GatewayDecodeError, "trailing bytes after a zlib sync boundary")

proc decode*(
    decoder: var GatewayMessageDecoder;
    message: GatewayMessage,
): Option[JsonNode] {.raises: [GatewayDecodeError].} =
  ## Decodes one transport message into a complete Gateway payload.
  ##
  ## Returns `some(node)` for a complete payload and `none` when more transport
  ## messages are required to finish a buffered `zlib-stream` payload. Raises
  ## `GatewayDecodeError` for an unexpected frame kind, an oversized or malformed
  ## stream, invalid UTF-8, or invalid JSON.
  case decoder.compression
  of gatewayCompressionNone:
    if message.kind != gatewayTextMessage:
      raise newException(
        GatewayDecodeError, "expected a text frame on an uncompressed connection")
    some(parseValidJson(message.data))
  of gatewayCompressionZlibStream:
    if message.kind != gatewayBinaryMessage:
      raise newException(
        GatewayDecodeError, "expected a binary frame on a zlib-stream connection")
    if decoder.compressed.len + message.data.len > decoder.maxCompressedBytes:
      raise newException(
        GatewayDecodeError, "compressed gateway buffer exceeded its bound")
    decoder.compressed.add message.data
    if not endsWithSyncMarker(decoder.compressed):
      return none(JsonNode) # a fragment; await more transport messages
    let inflated = inflateComplete(
      decoder.inflate, decoder.compressed, decoder.maxInflatedBytes)
    decoder.compressed.setLen(0)
    some(parseValidJson(inflated))
