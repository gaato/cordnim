## Optional reviewed Ed25519 provider backed by libsodium.

import ./verification

when defined(cordnimSodium):
  import ./sodium/raw

const sodiumVerifierEnabled* = defined(cordnimSodium)
  ## True when this build can load the configured libsodium library.

proc sodiumEd25519Verifier*(publicKey, signature,
                            message: openArray[byte]): bool
                            {.gcsafe, raises: [].} =
  ## Verifies a Discord request signature through libsodium.
  ##
  ## Builds without `-d:cordnimSodium` fail closed and return `false`. This lets
  ## webhook-disabled applications avoid a native dependency without silently
  ## accepting unsigned requests.
  when defined(cordnimSodium):
    if publicKey.len != 32 or signature.len != 64 or message.len == 0:
      return false
    if sodiumInit() < 0:
      return false
    cryptoSignVerifyDetached(
      cast[ptr uint8](unsafeAddr signature[0]),
      cast[ptr uint8](unsafeAddr message[0]),
      culonglong(message.len),
      cast[ptr uint8](unsafeAddr publicKey[0])
    ) == 0
  else:
    false

proc sodiumVerificationConfig*(publicKey: array[32, byte],
                               allowedSkewSeconds = 300'i64,
                               maxBodyBytes = 1_048_576): VerificationConfig =
  ## Creates a fail-closed HTTP interaction verification configuration.
  VerificationConfig(
    publicKey: publicKey,
    allowedSkewSeconds: allowedSkewSeconds,
    maxBodyBytes: maxBodyBytes,
    verifier: sodiumEd25519Verifier
  )
