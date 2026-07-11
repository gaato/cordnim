## Minimal libsodium declarations required for Discord Ed25519 verification.
##
## No cryptographic operation is implemented in Nim. Symbols are linked only
## when `-d:cordnimSodium` enables the public adapter.

when defined(windows):
  const DefaultSodiumLibrary = "libsodium.dll"
elif defined(macosx):
  const DefaultSodiumLibrary = "libsodium.dylib"
else:
  const DefaultSodiumLibrary = "libsodium.so(|.26|.23)"

const sodiumLibrary* {.strdefine.} = DefaultSodiumLibrary ## Library override.

proc sodiumInit*(): cint
  {.cdecl, importc: "sodium_init", dynlib: sodiumLibrary, raises: [].}
  ## Initializes libsodium and returns a negative value on failure.

proc cryptoSignVerifyDetached*(signature: ptr uint8, message: ptr uint8,
                               messageLength: culonglong,
                               publicKey: ptr uint8): cint
  {.cdecl, importc: "crypto_sign_verify_detached", dynlib: sodiumLibrary,
    raises: [].}
  ## Verifies one detached Ed25519 signature.
