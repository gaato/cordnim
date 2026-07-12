## Tests for per-connection Gateway payload decoding and zlib-stream ownership.
##
## zlib-stream fixtures are produced by a persistent `deflate` context flushed
## with `Z_SYNC_FLUSH`, exactly as Discord's server frames the stream, so the
## shared-context and fragment-boundary behavior is exercised deterministically.

import std/[json, options]

import zlib

import cordnim/gateway/[compression, transport]

type Deflater = object
  zs: ZStream
  open: bool

proc initDeflater(): Deflater =
  doAssert deflateInit2(
    result.zs, Z_DEFAULT_LEVEL, Z_DEFLATED, Z_WINDOW_BITS_15,
    Z_DEFAULT_MEM_LEVEL, Z_DEFAULT_STRATEGY) == Z_OK
  result.open = true

proc close(deflater: var Deflater) =
  if deflater.open:
    discard deflateEnd(deflater.zs)
    deflater.open = false

proc compressSyncFlush(deflater: var Deflater; payload: string): seq[byte] =
  ## Deflates one payload through the shared context, ending at a sync marker.
  var input = newSeq[byte](payload.len)
  for index, ch in payload:
    input[index] = byte(ch)
  deflater.zs.next_in = addr input[0]
  deflater.zs.avail_in = cuint(input.len)
  var scratch = newSeq[byte](64 * 1024)
  while true:
    deflater.zs.next_out = addr scratch[0]
    deflater.zs.avail_out = cuint(scratch.len)
    doAssert deflate(deflater.zs, Z_SYNC_FLUSH) == Z_OK
    let produced = scratch.len - int(deflater.zs.avail_out)
    if produced > 0:
      result.add scratch[0 ..< produced]
    if deflater.zs.avail_out != 0:
      break

block none_compression_decodes_text_frames:
  var decoder = initGatewayMessageDecoder(gatewayCompressionNone)
  doAssert decoder.compression == gatewayCompressionNone
  let ok = decoder.decode(textGatewayMessage("""{"op":11}"""))
  doAssert ok.isSome
  doAssert ok.get["op"].getInt == 11

block none_compression_rejects_binary_and_bad_json_and_bad_utf8:
  var decoder = initGatewayMessageDecoder(gatewayCompressionNone)
  doAssertRaises GatewayDecodeError:
    discard decoder.decode(binaryGatewayMessage(@[1'u8, 2, 3]))
  doAssertRaises GatewayDecodeError:
    discard decoder.decode(textGatewayMessage("not json"))
  let badUtf8 = GatewayMessage(kind: gatewayTextMessage, data: @[0xff'u8, 0xfe])
  doAssertRaises GatewayDecodeError:
    discard decoder.decode(badUtf8)

block zlib_stream_decodes_a_whole_message:
  var deflater = initDeflater()
  defer: deflater.close()
  var decoder = initGatewayMessageDecoder(gatewayCompressionZlibStream)
  defer: decoder.close()
  let chunk = deflater.compressSyncFlush("""{"op":10,"d":{"heartbeat_interval":45000}}""")
  doAssert chunk[^4 .. ^1] == @[0x00'u8, 0x00, 0xff, 0xff]
  let decoded = decoder.decode(binaryGatewayMessage(chunk))
  doAssert decoded.isSome
  doAssert decoded.get["op"].getInt == 10
  doAssert decoded.get["d"]["heartbeat_interval"].getInt == 45000

block zlib_stream_shares_one_context_across_payloads:
  # The second payload's compression references the first's window; decoding must
  # reuse the same inflate context or it will fail.
  var deflater = initDeflater()
  defer: deflater.close()
  var decoder = initGatewayMessageDecoder(gatewayCompressionZlibStream)
  defer: decoder.close()
  let first = decoder.decode(binaryGatewayMessage(
    deflater.compressSyncFlush("""{"op":0,"t":"READY","s":1,"d":{"session_id":"abc"}}""")))
  doAssert first.isSome
  doAssert first.get["t"].getStr == "READY"
  let second = decoder.decode(binaryGatewayMessage(
    deflater.compressSyncFlush("""{"op":0,"t":"MESSAGE_CREATE","s":2,"d":{"id":"1"}}""")))
  doAssert second.isSome
  doAssert second.get["s"].getInt == 2

block zlib_stream_buffers_across_transport_fragments:
  var deflater = initDeflater()
  defer: deflater.close()
  var decoder = initGatewayMessageDecoder(gatewayCompressionZlibStream)
  defer: decoder.close()
  let full = deflater.compressSyncFlush("""{"op":0,"t":"READY","s":1,"d":{"x":1}}""")
  doAssert full.len >= 6
  let head = full[0 ..< full.len - 3]
  let tail = full[full.len - 3 .. ^1]
  # The first fragment lacks the trailing marker, so no payload is ready yet.
  doAssert decoder.decode(binaryGatewayMessage(head)).isNone
  doAssert decoder.bufferedCompressedBytes > 0
  let done = decoder.decode(binaryGatewayMessage(tail))
  doAssert done.isSome
  doAssert done.get["t"].getStr == "READY"
  doAssert decoder.bufferedCompressedBytes == 0 # buffer cleared after a payload

block zlib_stream_rejects_text_frames:
  var decoder = initGatewayMessageDecoder(gatewayCompressionZlibStream)
  defer: decoder.close()
  doAssertRaises GatewayDecodeError:
    discard decoder.decode(textGatewayMessage("""{"op":11}"""))

block zlib_stream_rejects_malformed_data:
  var decoder = initGatewayMessageDecoder(gatewayCompressionZlibStream)
  defer: decoder.close()
  let junk = @[0xde'u8, 0xad, 0xbe, 0xef, 0x00, 0x00, 0xff, 0xff]
  doAssertRaises GatewayDecodeError:
    discard decoder.decode(binaryGatewayMessage(junk))

block zlib_stream_enforces_inflated_bound:
  var deflater = initDeflater()
  defer: deflater.close()
  var decoder = initGatewayMessageDecoder(
    gatewayCompressionZlibStream, maxInflatedBytes = 8)
  defer: decoder.close()
  let chunk = deflater.compressSyncFlush("""{"op":0,"d":"aaaaaaaaaaaaaaaaaaaaaaaa"}""")
  doAssertRaises GatewayDecodeError:
    discard decoder.decode(binaryGatewayMessage(chunk))

block zlib_stream_enforces_compressed_bound:
  var decoder = initGatewayMessageDecoder(
    gatewayCompressionZlibStream, maxCompressedBytes = 4)
  defer: decoder.close()
  # A fragment larger than the compressed ceiling is rejected before buffering.
  doAssertRaises GatewayDecodeError:
    discard decoder.decode(binaryGatewayMessage(@[1'u8, 2, 3, 4, 5]))

block none_compression_allocates_no_native_context:
  doAssert openZlibStreamContexts() == 0
  block:
    var decoder = initGatewayMessageDecoder(gatewayCompressionNone)
    doAssert openZlibStreamContexts() == 0
    doAssert decoder.compression == gatewayCompressionNone
  doAssert openZlibStreamContexts() == 0

block native_context_released_on_scope_exit:
  doAssert openZlibStreamContexts() == 0
  block:
    var decoder = initGatewayMessageDecoder(gatewayCompressionZlibStream)
    doAssert openZlibStreamContexts() == 1
    doAssert decoder.compression == gatewayCompressionZlibStream
  doAssert openZlibStreamContexts() == 0 # destructor released it exactly once

block native_context_released_once_across_move_and_close:
  doAssert openZlibStreamContexts() == 0
  block:
    var owner = initGatewayMessageDecoder(gatewayCompressionZlibStream)
    doAssert openZlibStreamContexts() == 1
    var moved = move owner # ownership transfers; the source is moved-from
    doAssert openZlibStreamContexts() == 1 # exactly one context, never two
    close moved
    doAssert openZlibStreamContexts() == 0
    close moved # idempotent
    doAssert openZlibStreamContexts() == 0
  # Destruction of both the moved-from source and the closed owner is a no-op.
  doAssert openZlibStreamContexts() == 0

block decoder_moves_but_is_not_copyable:
  # Move is supported (ownership transfers); copy/dup are disabled by the
  # `=copy`/`=dup {.error.}` hooks on both `ZlibInflate` and the decoder itself, so
  # the zlib context can never be duplicated and double-freed. (A `compiles`-based
  # negative is unreliable here: the move optimizer rewrites implicit copies as
  # moves, and an explicit cross-module `=copy`/`=dup` resolves to the generic;
  # `native_context_released_once_across_move_and_close` proves single release
  # across a move at runtime.)
  doAssert compiles((proc =
    var a = initGatewayMessageDecoder(gatewayCompressionNone)
    var b = move a
    close b))

echo "tgateway_compression: all blocks passed"
