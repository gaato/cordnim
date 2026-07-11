## Binary Voice Gateway message framing for DAVE payloads.

import std/options

import ./protocol

type VoiceBinaryMessage* = object ## Decoded binary Voice Gateway message.
  sequence*: Option[uint16] ## Server sequence, absent for client messages.
  opcode*: VoiceOpcode ## Opcode carried by the binary frame.
  payload*: seq[byte] ## Message bytes after the framing header.

proc parseServerBinary*(data: openArray[byte]): VoiceBinaryMessage =
  ## Decodes a server frame containing a big-endian sequence and opcode.
  ##
  ## Raises `ValueError` when `data` is shorter than the three-byte header.
  if data.len < 3:
    raise newException(
      ValueError,
      "server voice binary message must contain sequence and opcode",
    )
  # Voice Gateway v8 sends the sequence in network byte order.
  let sequence = (uint16(data[0]) shl 8) or uint16(data[1])
  VoiceBinaryMessage(
    sequence: some(sequence),
    opcode: VoiceOpcode(data[2]),
    payload: @data[3..<data.len],
  )

proc encodeClientBinary*(
    opcode: VoiceOpcode;
    payload: openArray[byte],
): seq[byte] =
  ## Encodes a client frame as one opcode byte followed by `payload`.
  ##
  ## Raises `ValueError` when `opcode` is not a binary Voice Gateway opcode.
  if not opcode.isBinary:
    raise newException(
      ValueError,
      "voice opcode is not defined as a binary opcode",
    )
  result = newSeqOfCap[byte](payload.len + 1)
  result.add(opcode.toUint8)
  result.add(payload)
