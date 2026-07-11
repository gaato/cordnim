## Reviewed HMAC-SHA-256 provider for persistent component routes.

import bearssl/[hash, hmac]

import ./routes

proc bearsslHmacSha256*(key, message: openArray[byte]): array[32, byte]
    {.gcsafe, raises: [].} =
  ## Computes HMAC-SHA-256 through BearSSL for `RouteCodec.signer`.
  var keyContext: HmacKeyContext
  var context: HmacContext
  let keyPointer = if key.len == 0: nil else: unsafeAddr key[0]
  hmacKeyInit(keyContext, addr sha256Vtable, keyPointer, csize_t(key.len))
  hmacInit(context, keyContext, csize_t(result.len))
  if message.len > 0:
    hmacUpdate(context, unsafeAddr message[0], csize_t(message.len))
  discard hmacOut(context, addr result[0])

func withBearsslSigner*(codec: sink RouteCodec): RouteCodec =
  ## Returns `codec` configured with the bundled BearSSL HMAC provider.
  result = codec
  result.signer = bearsslHmacSha256
