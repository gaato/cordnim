## Chronos-backed Discord Gateway transport using Status `websock`.
##
## Cordnim owns lifecycle translation, bounds, and Discord close information;
## `websock` owns RFC 6455 handshake, framing, masking, fragmentation,
## ping/pong, TLS, and UTF-8 validation.

import std/[strutils, uri]

import chronos
import chronicles
import websock/websock

import ./[close_policy, transport]

const defaultGatewayMessageBytes* = 16 * 1024 * 1024 ## Maximum aggregate
  ## bytes accepted across all fragments of one Gateway message.

type WebsockGatewayDriverState = ref object
  session: WSSession
  connectStarted: bool
  receiveLock: AsyncLock
  maxMessageBytes: int
  peerClose: GatewayCloseInfo
  hasPeerClose: bool

proc fail(message: string) {.noinline, noreturn.} =
  raise newException(GatewayTransportError, message)

proc parseTarget(url: string): tuple[
    secure: bool,
    host: string,
    hostName: string,
    path: string,
] =
  var parsed: Uri
  try:
    parsed = parseUri(url)
  except ValueError:
    fail("gateway URL is malformed")

  case parsed.scheme.toLowerAscii()
  of "wss":
    result.secure = true
  of "ws":
    result.secure = false
  else:
    fail("gateway URL scheme must be ws or wss")

  if parsed.hostname.len == 0:
    fail("gateway URL hostname must not be empty")
  if parsed.username.len > 0 or parsed.password.len > 0:
    fail("gateway URL must not contain user information")
  if parsed.anchor.len > 0:
    fail("gateway URL must not contain a fragment")
  if not result.secure and
      parsed.hostname.toLowerAscii() notin ["localhost", "127.0.0.1", "::1"]:
    fail("plain ws gateway URLs are restricted to loopback hosts")

  let port =
    if parsed.port.len > 0:
      try:
        let value = parseUInt(parsed.port)
        if value == 0 or value > uint(high(uint16)):
          fail("gateway URL port is out of range")
        uint16(value)
      except ValueError:
        fail("gateway URL port is invalid")
    elif result.secure:
      443'u16
    else:
      80'u16

  result.hostName = parsed.hostname
  result.host =
    if ':' in parsed.hostname:
      "[" & parsed.hostname & "]:" & $port
    else:
      parsed.hostname & ":" & $port
  result.path = if parsed.path.len == 0: "/" else: parsed.path
  if parsed.query.len > 0:
    result.path.add("?" & parsed.query)

func bytesToString(data: openArray[byte]): string {.raises: [].} =
  result = newString(data.len)
  for index, value in data:
    result[index] = char(value)

proc closeNow(state: WebsockGatewayDriverState) {.gcsafe, raises: [].} =
  if state.isNil or state.session.isNil:
    return
  state.session.readyState = ReadyState.Closed
  state.session.stream.close()

proc releaseHeldLock(lock: AsyncLock) {.gcsafe, raises: [].} =
  if not lock.isNil and lock.locked():
    try:
      lock.release()
    except AsyncLockError:
      discard

proc connectSession(
    state: WebsockGatewayDriverState;
    url: string,
): Future[void] {.
    async: (raises: [CancelledError, GatewayTransportError]).} =
  try:
    if state.connectStarted:
      fail("gateway WebSocket driver has already been used")
    state.connectStarted = true
    let target = parseTarget(url)

    proc rememberClose(
        code: StatusCodes;
        reason: string,
    ): CloseResult {.gcsafe, raises: [].} =
      state.peerClose = GatewayCloseInfo(
        code: GatewayCloseCode(uint16(code)),
        reason: reason,
        clean: true,
      )
      state.hasPeerClose = true
      (code: code, reason: reason)

    # An empty TLS flag set plus the explicit hostName keeps BearSSL
    # certificate-chain, hostname, and SNI verification enabled.
    state.session = await WebSocket.connect(
      host = target.host,
      path = target.path,
      hostName = target.hostName,
      secure = target.secure,
      flags = {},
      onClose = rememberClose,
    )
  except CancelledError:
    state.closeNow()
    raise
  except GatewayTransportError:
    state.closeNow()
    raise
  except CatchableError as exc:
    state.closeNow()
    raise newException(
      GatewayTransportError,
      "gateway WebSocket connection failed: " & exc.msg,
      exc,
    )

proc sendMessage(
    state: WebsockGatewayDriverState;
    message: GatewayMessage,
): Future[void] {.
    async: (raises: [CancelledError, GatewayTransportError]).} =
  try:
    if state.session.isNil or state.session.readyState != ReadyState.Open:
      fail("gateway WebSocket is not open")
    case message.kind
    of gatewayTextMessage:
      await state.session.send(message.data.bytesToString())
    of gatewayBinaryMessage:
      await state.session.send(message.data, Opcode.Binary)
  except CancelledError:
    state.closeNow()
    raise
  except GatewayTransportError:
    state.closeNow()
    raise
  except CatchableError as exc:
    state.closeNow()
    raise newException(
      GatewayTransportError,
      "gateway WebSocket send failed: " & exc.msg,
      exc,
    )

proc receiveEvent(
    state: WebsockGatewayDriverState,
): Future[GatewayTransportEvent] {.
    async: (raises: [CancelledError, GatewayTransportError]).} =
  var acquired = false
  try:
    if state.session.isNil or state.session.readyState != ReadyState.Open:
      fail("gateway WebSocket is not open")
    await state.receiveLock.acquire()
    acquired = true
    let payload = await state.session.recvMsg(state.maxMessageBytes)
    let binary = state.session.binary
    if binary:
      return messageEvent(binaryGatewayMessage(payload))
    return messageEvent(textGatewayMessage(payload.bytesToString()))
  except CancelledError:
    state.closeNow()
    raise
  except WSClosedError:
    state.closeNow()
    if state.hasPeerClose:
      return closeEvent(state.peerClose)
    return closeEvent(GatewayCloseInfo(
      code: GatewayCloseCode(1006),
      reason: "connection ended without a close frame",
      clean: false,
    ))
  except GatewayTransportError:
    state.closeNow()
    raise
  except CatchableError as exc:
    state.closeNow()
    raise newException(
      GatewayTransportError,
      "gateway WebSocket receive failed: " & exc.msg,
      exc,
    )
  finally:
    if acquired:
      state.receiveLock.releaseHeldLock()

proc closeSession(
    state: WebsockGatewayDriverState;
    code: GatewayCloseCode;
    reason: string,
): Future[void] {.
    async: (raises: [CancelledError, GatewayTransportError]).} =
  if state.session.isNil or state.session.readyState != ReadyState.Open:
    state.closeNow()
    return
  try:
    await state.session.close(StatusCodes(code.toUint16()), reason)
  except CancelledError:
    state.closeNow()
    raise
  except CatchableError as exc:
    state.closeNow()
    raise newException(
      GatewayTransportError,
      "gateway WebSocket close failed: " & exc.msg,
      exc,
    )

proc newChronosGatewayDriver*(
    maxMessageBytes = defaultGatewayMessageBytes,
): GatewayTransportDriver =
  ## Creates a one-connection `websock` driver on Chronos.
  ##
  ## `recvMsg` enforces `maxMessageBytes` across all fragments. `websock`
  ## serializes sends, while the adapter serializes receive calls with an
  ## async lock. An active receive must finish before the close handshake,
  ## because both operations read from the WebSocket stream.
  if maxMessageBytes <= 0:
    raise newException(ValueError, "gateway message limit must be positive")
  let state = WebsockGatewayDriverState(
    receiveLock: newAsyncLock(),
    maxMessageBytes: maxMessageBytes,
  )

  proc connectCallback(url: string): GatewayDriverVoidFuture {.
      closure, gcsafe, raises: [].} =
    state.connectSession(url)

  proc sendCallback(message: GatewayMessage): GatewayDriverVoidFuture {.
      closure, gcsafe, raises: [].} =
    state.sendMessage(message)

  proc receiveCallback(): GatewayDriverEventFuture {.
      closure, gcsafe, raises: [].} =
    state.receiveEvent()

  proc closeCallback(
      code: GatewayCloseCode;
      reason: string,
  ): GatewayDriverVoidFuture {.closure, gcsafe, raises: [].} =
    state.closeSession(code, reason)

  proc abortCallback() {.closure, gcsafe, raises: [].} =
    state.closeNow()

  newGatewayTransportDriver(
    connectCallback,
    sendCallback,
    receiveCallback,
    closeCallback,
    abortCallback,
  )

proc connectChronosGatewayTransport*(
    url: string;
    maxMessageBytes = defaultGatewayMessageBytes,
): Future[GatewayTransport] =
  ## Connects `url` with a fresh Status `websock`/Chronos driver.
  connectGatewayTransport(url, newChronosGatewayDriver(maxMessageBytes))
