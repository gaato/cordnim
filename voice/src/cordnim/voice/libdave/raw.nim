## Thin dynamic binding to Discord's official libdave C API.
##
## This module never implements DAVE cryptography. Build with
## `-d:cordnimVoiceLibdave` to expose the imported functions. Without that
## define, data types remain available for documentation and state-only tests,
## and no native library is loaded.

const
  libdaveApiRevision* = "v1.1.1/cpp" ## Upstream C API revision mapped by this module.
  libdaveHeaderSha256* = "dd61a62386ae4cc65110ee787e809d3383059c9b01383d378d6d63c711020859" ## SHA-256 of the mapped upstream header.

  defaultLibdaveLibrary =
    when defined(windows): "libdave.dll"
    elif defined(macosx): "libdave.dylib"
    else: "libdave.so"

  libdaveLibrary* {.strdefine.} = defaultLibdaveLibrary ## Dynamic library name or path used by imported functions.
  libdaveBindingsEnabled* = defined(cordnimVoiceLibdave) ## Whether native function declarations are enabled.

type
  DAVESessionHandleObj {.incompleteStruct.} = object
  DAVECommitResultHandleObj {.incompleteStruct.} = object
  DAVEWelcomeResultHandleObj {.incompleteStruct.} = object
  DAVEKeyRatchetHandleObj {.incompleteStruct.} = object
  DAVEEncryptorHandleObj {.incompleteStruct.} = object
  DAVEDecryptorHandleObj {.incompleteStruct.} = object

  DAVESessionHandle* = ptr DAVESessionHandleObj ## Opaque session released by `daveSessionDestroy`.
  DAVECommitResultHandle* = ptr DAVECommitResultHandleObj ## Opaque commit result released by `daveCommitResultDestroy`.
  DAVEWelcomeResultHandle* = ptr DAVEWelcomeResultHandleObj ## Opaque welcome result released by `daveWelcomeResultDestroy`.
  DAVEKeyRatchetHandle* = ptr DAVEKeyRatchetHandleObj ## Opaque key ratchet released by `daveKeyRatchetDestroy`.
  DAVEEncryptorHandle* = ptr DAVEEncryptorHandleObj ## Opaque encryptor released by `daveEncryptorDestroy`.
  DAVEDecryptorHandle* = ptr DAVEDecryptorHandleObj ## Opaque decryptor released by `daveDecryptorDestroy`.

  DAVECodec* {.size: sizeof(cint).} = enum ## Media codec identifier with C `int` layout.
    daveCodecUnknown = 0,                    ## Unspecified or unsupported codec.
    daveCodecOpus = 1,                       ## Opus audio codec.
    daveCodecVp8 = 2,                        ## VP8 video codec.
    daveCodecVp9 = 3,                        ## VP9 video codec.
    daveCodecH264 = 4,                       ## H.264 video codec.
    daveCodecH265 = 5,                       ## H.265 video codec.
    daveCodecAv1 = 6                         ## AV1 video codec.

  DAVEMediaType* {.size: sizeof(cint).} = enum ## Protected media category with C `int` layout.
    daveMediaTypeAudio = 0,                       ## Audio media frame.
    daveMediaTypeVideo = 1                        ## Video media frame.

  DAVEEncryptorResultCode* {.size: sizeof(cint).} = enum ## Frame encryption outcome with C `int` layout.
    daveEncryptorSuccess = 0,                           ## Frame encryption succeeded.
    daveEncryptorEncryptionFailure = 1,                 ## Cryptographic encryption failed.
    daveEncryptorMissingKeyRatchet = 2,                 ## No key ratchet was available.
    daveEncryptorMissingCryptor = 3,                    ## No cryptor was available for the frame.
    daveEncryptorTooManyAttempts = 4                    ## Retry limit was exhausted.

  DAVEDecryptorResultCode* {.size: sizeof(cint).} = enum ## Frame decryption outcome with C `int` layout.
    daveDecryptorSuccess = 0,                           ## Frame decryption succeeded.
    daveDecryptorDecryptionFailure = 1,                 ## Cryptographic decryption failed.
    daveDecryptorMissingKeyRatchet = 2,                 ## No key ratchet was available.
    daveDecryptorInvalidNonce = 3,                      ## Frame nonce was invalid.
    daveDecryptorMissingCryptor = 4                     ## No cryptor was available for the frame.

  DAVELoggingSeverity* {.size: sizeof(cint).} = enum ## Native log severity with C `int` layout.
    daveLoggingVerbose = 0,                         ## Verbose diagnostic message.
    daveLoggingInfo = 1,                            ## Informational message.
    daveLoggingWarning = 2,                         ## Warning message.
    daveLoggingError = 3,                           ## Error message.
    daveLoggingNone = 4                             ## Logging is disabled.

  DAVEMLSFailureCallback* = proc(
    source, reason: cstring;
    userData: pointer,
  ) {.cdecl.}
    ## Receives an MLS failure source and diagnostic reason.

  DAVEPairwiseFingerprintCallback* = proc(
    fingerprint: ptr uint8;
    length: csize_t;
    userData: pointer,
  ) {.cdecl.}
    ## Receives one pairwise fingerprint as a borrowed byte range.

  DAVEEncryptorProtocolVersionChangedCallback* = proc(
    userData: pointer,
  ) {.cdecl.}
    ## Reports that an encryptor's active protocol version changed.

  DAVELogSinkCallback* = proc(
    severity: DAVELoggingSeverity;
    fileName: cstring;
    line: cint;
    message: cstring,
  ) {.cdecl.}
    ## Receives one native libdave log record.

  DAVEEncryptorStats* {.bycopy.} = object ## C-compatible cumulative encryptor counters.
    passthroughCount*: uint64 ## Frames emitted without encryption.
    encryptSuccessCount*: uint64 ## Frames encrypted successfully.
    encryptFailureCount*: uint64 ## Frames whose encryption failed.
    encryptDuration*: uint64 ## Cumulative encryption duration reported by libdave.
    encryptAttempts*: uint64 ## Total encryption attempts.
    encryptMaxAttempts*: uint64 ## Maximum encryption attempts reported for one frame.
    encryptMissingKeyCount*: uint64 ## Attempts made without a usable key.

  DAVEDecryptorStats* {.bycopy.} = object ## C-compatible cumulative decryptor counters.
    passthroughCount*: uint64 ## Frames accepted without decryption.
    decryptSuccessCount*: uint64 ## Frames decrypted successfully.
    decryptFailureCount*: uint64 ## Frames whose decryption failed.
    decryptDuration*: uint64 ## Cumulative decryption duration reported by libdave.
    decryptAttempts*: uint64 ## Total decryption attempts.
    decryptMissingKeyCount*: uint64 ## Attempts made without a usable key.
    decryptInvalidNonceCount*: uint64 ## Frames rejected for an invalid nonce.

when defined(cordnimVoiceLibdave):
  {.push callconv: cdecl, dynlib: libdaveLibrary.}

  proc daveMaxSupportedProtocolVersion*(): uint16
    {.importc: "daveMaxSupportedProtocolVersion".}
    ## Returns the highest DAVE protocol version supported by libdave.
  proc daveFree*(data: pointer)
    {.importc: "daveFree".}
    ## Releases a buffer allocated and returned by libdave.

  proc daveSessionCreate*(
      context: pointer;
      authSessionId: cstring;
      callback: DAVEMLSFailureCallback;
      userData: pointer,
  ): DAVESessionHandle {.importc: "daveSessionCreate".}
    ## Creates an opaque MLS session and installs its failure callback.
  proc daveSessionDestroy*(session: DAVESessionHandle)
    {.importc: "daveSessionDestroy".}
    ## Destroys `session` and releases its native resources.
  proc daveSessionInit*(
      session: DAVESessionHandle;
      version: uint16;
      groupId: uint64;
      selfUserId: cstring,
  ) {.importc: "daveSessionInit".}
    ## Initializes `session` for a protocol version, MLS group, and local user.
  proc daveSessionReset*(session: DAVESessionHandle)
    {.importc: "daveSessionReset".}
    ## Clears negotiated MLS state while retaining the session handle.
  proc daveSessionSetProtocolVersion*(session: DAVESessionHandle; version: uint16)
    {.importc: "daveSessionSetProtocolVersion".}
    ## Selects the DAVE protocol version used by `session`.
  proc daveSessionGetProtocolVersion*(session: DAVESessionHandle): uint16
    {.importc: "daveSessionGetProtocolVersion".}
    ## Returns the DAVE protocol version currently selected by `session`.
  proc daveSessionGetLastEpochAuthenticator*(
      session: DAVESessionHandle;
      authenticator: ptr ptr uint8;
      length: ptr csize_t,
  ) {.importc: "daveSessionGetLastEpochAuthenticator".}
    ## Writes the latest MLS epoch authenticator and its byte length.
  proc daveSessionSetExternalSender*(
      session: DAVESessionHandle;
      externalSender: ptr uint8;
      length: csize_t,
  ) {.importc: "daveSessionSetExternalSender".}
    ## Installs a serialized MLS external sender package into `session`.
  proc daveSessionProcessProposals*(
      session: DAVESessionHandle;
      proposals: ptr uint8;
      length: csize_t;
      recognizedUserIds: ptr cstring;
      recognizedUserIdsLength: csize_t;
      commitWelcomeBytes: ptr ptr uint8;
      commitWelcomeBytesLength: ptr csize_t,
  ) {.importc: "daveSessionProcessProposals".}
    ## Processes MLS proposals and writes any generated commit-welcome payload.
  proc daveSessionProcessCommit*(
      session: DAVESessionHandle;
      commit: ptr uint8;
      length: csize_t,
  ): DAVECommitResultHandle {.importc: "daveSessionProcessCommit".}
    ## Processes an MLS commit and returns an inspectable result handle.
  proc daveSessionProcessWelcome*(
      session: DAVESessionHandle;
      welcome: ptr uint8;
      length: csize_t;
      recognizedUserIds: ptr cstring;
      recognizedUserIdsLength: csize_t,
  ): DAVEWelcomeResultHandle {.importc: "daveSessionProcessWelcome".}
    ## Processes an MLS welcome for the recognized roster and returns its result.
  proc daveSessionGetMarshalledKeyPackage*(
      session: DAVESessionHandle;
      keyPackage: ptr ptr uint8;
      length: ptr csize_t,
  ) {.importc: "daveSessionGetMarshalledKeyPackage".}
    ## Writes the session's serialized MLS key package and its byte length.
  proc daveSessionGetKeyRatchet*(
      session: DAVESessionHandle;
      userId: cstring,
  ): DAVEKeyRatchetHandle {.importc: "daveSessionGetKeyRatchet".}
    ## Returns the key ratchet for `userId` as an owned opaque handle.
  proc daveSessionGetPairwiseFingerprint*(
      session: DAVESessionHandle;
      version: uint16;
      userId: cstring;
      callback: DAVEPairwiseFingerprintCallback;
      userData: pointer,
  ) {.importc: "daveSessionGetPairwiseFingerprint".}
    ## Computes a pairwise fingerprint and delivers it through `callback`.

  proc daveKeyRatchetDestroy*(keyRatchet: DAVEKeyRatchetHandle)
    {.importc: "daveKeyRatchetDestroy".}
    ## Destroys `keyRatchet` and releases its native resources.

  proc daveCommitResultIsFailed*(handle: DAVECommitResultHandle): bool
    {.importc: "daveCommitResultIsFailed".}
    ## Reports whether processing the commit failed.
  proc daveCommitResultIsIgnored*(handle: DAVECommitResultHandle): bool
    {.importc: "daveCommitResultIsIgnored".}
    ## Reports whether processing ignored the commit without applying it.
  proc daveCommitResultGetRosterMemberIds*(
      handle: DAVECommitResultHandle;
      rosterIds: ptr ptr uint64;
      rosterIdsLength: ptr csize_t,
  ) {.importc: "daveCommitResultGetRosterMemberIds".}
    ## Writes the roster member IDs associated with a commit result.
  proc daveCommitResultGetRosterMemberSignature*(
      handle: DAVECommitResultHandle;
      rosterId: uint64;
      signature: ptr ptr uint8;
      signatureLength: ptr csize_t,
  ) {.importc: "daveCommitResultGetRosterMemberSignature".}
    ## Writes the commit signature associated with `rosterId`.
  proc daveCommitResultDestroy*(handle: DAVECommitResultHandle)
    {.importc: "daveCommitResultDestroy".}
    ## Destroys `handle` and releases its native result resources.

  proc daveWelcomeResultGetRosterMemberIds*(
      handle: DAVEWelcomeResultHandle;
      rosterIds: ptr ptr uint64;
      rosterIdsLength: ptr csize_t,
  ) {.importc: "daveWelcomeResultGetRosterMemberIds".}
    ## Writes the roster member IDs associated with a welcome result.
  proc daveWelcomeResultGetRosterMemberSignature*(
      handle: DAVEWelcomeResultHandle;
      rosterId: uint64;
      signature: ptr ptr uint8;
      signatureLength: ptr csize_t,
  ) {.importc: "daveWelcomeResultGetRosterMemberSignature".}
    ## Writes the welcome signature associated with `rosterId`.
  proc daveWelcomeResultDestroy*(handle: DAVEWelcomeResultHandle)
    {.importc: "daveWelcomeResultDestroy".}
    ## Destroys `handle` and releases its native result resources.

  proc daveEncryptorCreate*(): DAVEEncryptorHandle
    {.importc: "daveEncryptorCreate".}
    ## Creates an opaque media encryptor.
  proc daveEncryptorDestroy*(encryptor: DAVEEncryptorHandle)
    {.importc: "daveEncryptorDestroy".}
    ## Destroys `encryptor` and releases its native resources.
  proc daveEncryptorSetKeyRatchet*(
      encryptor: DAVEEncryptorHandle;
      keyRatchet: DAVEKeyRatchetHandle,
  ) {.importc: "daveEncryptorSetKeyRatchet".}
    ## Assigns a key ratchet to `encryptor`.
  proc daveEncryptorSetPassthroughMode*(
      encryptor: DAVEEncryptorHandle;
      passthroughMode: bool,
  ) {.importc: "daveEncryptorSetPassthroughMode".}
    ## Enables or disables unencrypted passthrough for `encryptor`.
  proc daveEncryptorAssignSsrcToCodec*(
      encryptor: DAVEEncryptorHandle;
      ssrc: uint32;
      codecType: DAVECodec,
  ) {.importc: "daveEncryptorAssignSsrcToCodec".}
    ## Associates an RTP synchronization source with its media codec.
  proc daveEncryptorGetProtocolVersion*(encryptor: DAVEEncryptorHandle): uint16
    {.importc: "daveEncryptorGetProtocolVersion".}
    ## Returns the protocol version currently used by `encryptor`.
  proc daveEncryptorGetMaxCiphertextByteSize*(
      encryptor: DAVEEncryptorHandle;
      mediaType: DAVEMediaType;
      frameSize: csize_t,
  ): csize_t {.importc: "daveEncryptorGetMaxCiphertextByteSize".}
    ## Returns the required output capacity for encrypting a frame of `frameSize`.
  proc daveEncryptorHasKeyRatchet*(encryptor: DAVEEncryptorHandle): bool
    {.importc: "daveEncryptorHasKeyRatchet".}
    ## Reports whether `encryptor` has an assigned key ratchet.
  proc daveEncryptorIsPassthroughMode*(encryptor: DAVEEncryptorHandle): bool
    {.importc: "daveEncryptorIsPassthroughMode".}
    ## Reports whether `encryptor` currently passes frames through unencrypted.
  proc daveEncryptorEncrypt*(
      encryptor: DAVEEncryptorHandle;
      mediaType: DAVEMediaType;
      ssrc: uint32;
      frame: ptr uint8;
      frameLength: csize_t;
      encryptedFrame: ptr uint8;
      encryptedFrameCapacity: csize_t;
      bytesWritten: ptr csize_t,
  ): DAVEEncryptorResultCode {.importc: "daveEncryptorEncrypt".}
    ## Encrypts one media frame into caller-owned storage and writes its length.
  proc daveEncryptorSetProtocolVersionChangedCallback*(
      encryptor: DAVEEncryptorHandle;
      callback: DAVEEncryptorProtocolVersionChangedCallback;
      userData: pointer,
  ) {.importc: "daveEncryptorSetProtocolVersionChangedCallback".}
    ## Installs the callback invoked when the encryptor's protocol version changes.
  proc daveEncryptorGetStats*(
      encryptor: DAVEEncryptorHandle;
      mediaType: DAVEMediaType;
      stats: ptr DAVEEncryptorStats,
  ) {.importc: "daveEncryptorGetStats".}
    ## Writes cumulative encryptor statistics for `mediaType`.

  proc daveDecryptorCreate*(): DAVEDecryptorHandle
    {.importc: "daveDecryptorCreate".}
    ## Creates an opaque media decryptor.
  proc daveDecryptorDestroy*(decryptor: DAVEDecryptorHandle)
    {.importc: "daveDecryptorDestroy".}
    ## Destroys `decryptor` and releases its native resources.
  proc daveDecryptorTransitionToKeyRatchet*(
      decryptor: DAVEDecryptorHandle;
      keyRatchet: DAVEKeyRatchetHandle,
  ) {.importc: "daveDecryptorTransitionToKeyRatchet".}
    ## Transitions `decryptor` to an assigned key ratchet.
  proc daveDecryptorTransitionToPassthroughMode*(
      decryptor: DAVEDecryptorHandle;
      passthroughMode: bool,
  ) {.importc: "daveDecryptorTransitionToPassthroughMode".}
    ## Transitions `decryptor` into or out of unencrypted passthrough mode.
  proc daveDecryptorDecrypt*(
      decryptor: DAVEDecryptorHandle;
      mediaType: DAVEMediaType;
      encryptedFrame: ptr uint8;
      encryptedFrameLength: csize_t;
      frame: ptr uint8;
      frameCapacity: csize_t;
      bytesWritten: ptr csize_t,
  ): DAVEDecryptorResultCode {.importc: "daveDecryptorDecrypt".}
    ## Decrypts one media frame into caller-owned storage and writes its length.
  proc daveDecryptorGetMaxPlaintextByteSize*(
      decryptor: DAVEDecryptorHandle;
      mediaType: DAVEMediaType;
      encryptedFrameSize: csize_t,
  ): csize_t {.importc: "daveDecryptorGetMaxPlaintextByteSize".}
    ## Returns the required output capacity for a ciphertext of the given size.
  proc daveDecryptorGetStats*(
      decryptor: DAVEDecryptorHandle;
      mediaType: DAVEMediaType;
      stats: ptr DAVEDecryptorStats,
  ) {.importc: "daveDecryptorGetStats".}
    ## Writes cumulative decryptor statistics for `mediaType`.

  proc daveSetLogSinkCallback*(callback: DAVELogSinkCallback)
    {.importc: "daveSetLogSinkCallback".}
    ## Installs the process-wide native log sink callback.

  {.pop.}
