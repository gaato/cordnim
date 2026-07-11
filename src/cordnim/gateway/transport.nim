## Transport-neutral asynchronous I/O for Discord Gateway connections.
##
## The transport owns connection and WebSocket message lifecycle only. A shard
## supervisor remains responsible for HELLO, heartbeat, IDENTIFY, RESUME, and
## reconnect policy. `GatewayCloseInfo.code` can be passed directly to
## `ShardRuntime.disconnected` after a remote close event.

import std/[options, unicode]

import chronos

import ./close_policy

type
  GatewayTransportError* = object of CatchableError ## Gateway connection,
    ## protocol, or I/O failure.
  GatewayTransportStateError* = object of GatewayTransportError ## Operation
    ## rejected by the current connection lifecycle state.

  GatewayMessageKind* = enum ## WebSocket application-message encoding.
    gatewayTextMessage, ## UTF-8 text message, normally a JSON payload.
    gatewayBinaryMessage ## Binary message, including compressed Gateway data.

  GatewayMessage* = object ## One complete WebSocket application message.
    kind*: GatewayMessageKind ## Text or binary wire opcode.
    data*: seq[byte] ## Complete, unfragmented payload bytes.

  GatewayCloseInfo* = object ## Peer close details retained for reconnect
    ## policy and diagnostics.
    code*: GatewayCloseCode ## Exact Discord or WebSocket close code.
    reason*: string ## UTF-8 close reason supplied by the peer.
    clean*: bool ## True for a valid close frame; false for EOF or I/O loss.

  GatewayTransportEventKind* = enum ## Result of one transport receive.
    gatewayMessageReceived, ## A complete text or binary message arrived.
    gatewayTransportClosed ## The peer closed or the stream ended.

  GatewayTransportEvent* = object ## Message-or-close event from the driver.
    case kind*: GatewayTransportEventKind
    of gatewayMessageReceived:
      message*: GatewayMessage ## Complete application message.
    of gatewayTransportClosed:
      closeInfo*: GatewayCloseInfo ## Exact or synthesized close details.

  GatewayTransportState* = enum ## Observable transport lifecycle.
    gatewayTransportConnecting,
    gatewayTransportOpen,
    gatewayTransportClosing,
    gatewayTransportClosedState

  GatewayDriverVoidFuture* = Future[void].Raising([
    CancelledError,
    GatewayTransportError,
  ]) ## Driver operation that either completes, is cancelled, or fails transport.
  GatewayDriverEventFuture* = Future[GatewayTransportEvent].Raising([
    CancelledError,
    GatewayTransportError,
  ]) ## Driver receive operation returning one complete transport event.

  GatewayDriverConnectProc* = proc(url: string): GatewayDriverVoidFuture {.
    closure, gcsafe, raises: [].} ## Opens the driver-owned connection.
  GatewayDriverSendProc* = proc(
    message: GatewayMessage,
  ): GatewayDriverVoidFuture {.closure, gcsafe, raises: [].} ## Sends one whole
    ## message; cancellation must make delivery outcome non-successful.
  GatewayDriverReceiveProc* = proc(): GatewayDriverEventFuture {.
    closure, gcsafe, raises: [].} ## Reads one message or peer-close event.
  GatewayDriverCloseProc* = proc(
    code: GatewayCloseCode;
    reason: string,
  ): GatewayDriverVoidFuture {.closure, gcsafe, raises: [].} ## Performs a
    ## graceful WebSocket close when no application I/O remains active.
  GatewayDriverAbortProc* = proc() {.closure, gcsafe, raises: [].} ## Releases
    ## the connection immediately without claiming graceful delivery.

  GatewayTransportDriver* = ref object ## Injectable WebSocket driver contract.
    ##
    ## Production code uses the Chronos driver. Tests can inject deterministic
    ## closures without opening sockets or changing global runtime state.
    connectProc: GatewayDriverConnectProc
    sendProc: GatewayDriverSendProc
    receiveProc: GatewayDriverReceiveProc
    closeProc: GatewayDriverCloseProc
    abortProc: GatewayDriverAbortProc

  GatewayTransport* = ref object ## One connected Gateway WebSocket.
    driver: GatewayTransportDriver
    currentState: GatewayTransportState
    peerClose: Option[GatewayCloseInfo]
    activeSends: seq[Future[void]]
    activeReceive: Future[GatewayTransportEvent]
    closeOperation: Future[void]

proc newGatewayTransportDriver*(
    connectProc: GatewayDriverConnectProc;
    sendProc: GatewayDriverSendProc;
    receiveProc: GatewayDriverReceiveProc;
    closeProc: GatewayDriverCloseProc;
    abortProc: GatewayDriverAbortProc,
): GatewayTransportDriver =
  ## Creates a driver from a complete set of lifecycle callbacks.
  ##
  ## Raises `ValueError` rather than allowing a partially initialized driver
  ## to fail during a live Gateway session.
  if connectProc.isNil or sendProc.isNil or receiveProc.isNil or
      closeProc.isNil or abortProc.isNil:
    raise newException(
      ValueError,
      "gateway transport driver callbacks must not be nil",
    )
  GatewayTransportDriver(
    connectProc: connectProc,
    sendProc: sendProc,
    receiveProc: receiveProc,
    closeProc: closeProc,
    abortProc: abortProc,
  )

func textGatewayMessage*(value: string): GatewayMessage {.raises: [].} =
  ## Copies a string into a text WebSocket message.
  result.kind = gatewayTextMessage
  result.data = newSeq[byte](value.len)
  for index, character in value:
    result.data[index] = byte(character)

func binaryGatewayMessage*(value: sink seq[byte]): GatewayMessage {.
    raises: [].} =
  ## Moves or copies bytes into a binary WebSocket message.
  GatewayMessage(kind: gatewayBinaryMessage, data: value)

func text*(message: GatewayMessage): string =
  ## Returns text payload bytes as a string.
  ##
  ## Raises `ValueError` for a binary message. UTF-8 validation belongs to the
  ## WebSocket driver that accepted the text frame.
  if message.kind != gatewayTextMessage:
    raise newException(ValueError, "gateway message is binary")
  result = newString(message.data.len)
  for index, value in message.data:
    result[index] = char(value)

func hasValidUtf8(message: GatewayMessage): bool =
  if message.kind != gatewayTextMessage:
    return true
  message.text().validateUtf8() == -1

func messageEvent*(message: sink GatewayMessage): GatewayTransportEvent {.
    raises: [].} =
  ## Creates a received-message event for driver implementations.
  GatewayTransportEvent(
    kind: gatewayMessageReceived,
    message: message,
  )

func closeEvent*(closeInfo: sink GatewayCloseInfo): GatewayTransportEvent {.
    raises: [].} =
  ## Creates a peer-close event for driver implementations.
  GatewayTransportEvent(
    kind: gatewayTransportClosed,
    closeInfo: closeInfo,
  )

func state*(transport: GatewayTransport): GatewayTransportState {.
    inline, raises: [].} =
  ## Returns the current connection lifecycle state.
  transport.currentState

func remoteClose*(transport: GatewayTransport): Option[GatewayCloseInfo] {.
    inline, raises: [].} =
  ## Returns peer close details after a close event.
  transport.peerClose

func isClosed*(transport: GatewayTransport): bool {.inline, raises: [].} =
  ## Tests whether no more transport operations are permitted.
  transport.currentState == gatewayTransportClosedState

proc abort*(transport: GatewayTransport) {.raises: [].} =
  ## Immediately closes resources without sending a WebSocket close frame.
  ##
  ## This is the cancellation and exceptional-I/O cleanup path. It is
  ## idempotent so callers may use it in `finally` blocks.
  if transport.isNil or transport.currentState == gatewayTransportClosedState:
    return
  transport.currentState = gatewayTransportClosedState
  for pending in transport.activeSends:
    if not pending.finished:
      pending.cancelSoon()
  if not transport.activeReceive.isNil and
      not transport.activeReceive.finished:
    transport.activeReceive.cancelSoon()
  transport.driver.abortProc()

proc connectGatewayTransport*(
    url: string;
    driver: GatewayTransportDriver,
): Future[GatewayTransport] {.async.} =
  ## Connects one injected WebSocket driver to `url`.
  ##
  ## Cancellation aborts the partially opened driver before propagating
  ## `CancelledError`. Other backend failures are wrapped in
  ## `GatewayTransportError` without exposing connection credentials.
  if url.len == 0:
    raise newException(ValueError, "gateway URL must not be empty")
  if driver.isNil:
    raise newException(ValueError, "gateway transport driver must not be nil")

  let transport = GatewayTransport(
    driver: driver,
    currentState: gatewayTransportConnecting,
  )
  try:
    await driver.connectProc(url)
    transport.currentState = gatewayTransportOpen
    return transport
  except CancelledError:
    transport.abort()
    raise
  except GatewayTransportError as exc:
    transport.abort()
    raise newException(
      GatewayTransportError,
      "gateway transport connection failed: " & exc.msg,
      exc,
    )

proc requireOpen(transport: GatewayTransport) =
  if transport.isNil or transport.currentState != gatewayTransportOpen:
    raise newException(
      GatewayTransportStateError,
      "gateway transport is not open",
    )

proc sendOwned(
    transport: GatewayTransport;
    message: sink GatewayMessage,
): Future[void] {.async.} =
  try:
    await transport.driver.sendProc(message)
  except CancelledError:
    transport.abort()
    raise
  except GatewayTransportError as exc:
    transport.abort()
    raise newException(
      GatewayTransportError,
      "gateway transport send failed: " & exc.msg,
      exc,
    )

proc reapSends(transport: GatewayTransport) {.raises: [].} =
  var active: seq[Future[void]]
  for pending in transport.activeSends:
    if not pending.finished:
      active.add pending
  transport.activeSends = move active

proc send*(
    transport: GatewayTransport;
    message: sink GatewayMessage,
): Future[void] =
  ## Sends one complete text or binary WebSocket message.
  ##
  ## The transport retains every in-flight send until it finishes. A concurrent
  ## close cancels and joins those sends, then aborts the connection instead of
  ## allowing a queued or fragmented message to report false success.
  transport.requireOpen()
  if not message.hasValidUtf8:
    raise newException(ValueError, "gateway text message is not valid UTF-8")
  transport.reapSends()
  result = transport.sendOwned(message)
  transport.activeSends.add result

proc sendText*(transport: GatewayTransport; value: string): Future[void] =
  ## Sends one text WebSocket message.
  transport.send(textGatewayMessage(value))

proc sendBinary*(
    transport: GatewayTransport;
    value: sink seq[byte],
): Future[void] =
  ## Sends one binary WebSocket message.
  transport.send(binaryGatewayMessage(value))

proc receiveOwned(
    transport: GatewayTransport,
): Future[GatewayTransportEvent] {.async.} =
  ##
  try:
    let event = await transport.driver.receiveProc()
    if event.kind == gatewayTransportClosed:
      transport.peerClose = some(event.closeInfo)
      transport.currentState = gatewayTransportClosedState
    return event
  except CancelledError:
    transport.abort()
    raise
  except GatewayTransportError as exc:
    transport.abort()
    raise newException(
      GatewayTransportError,
      "gateway transport receive failed: " & exc.msg,
      exc,
    )
  finally:
    transport.activeReceive = nil

proc receive*(
    transport: GatewayTransport,
): Future[GatewayTransportEvent] =
  ## Receives one complete message or peer-close event.
  ##
  ## A close event moves the transport to `gatewayTransportClosedState` and
  ## retains the exact close information in `remoteClose`. Only one receive may
  ## be active because WebSocket framing has one stream-reader owner.
  transport.requireOpen()
  if not transport.activeReceive.isNil and
      not transport.activeReceive.finished:
    raise newException(
      GatewayTransportStateError,
      "a gateway receive operation is already active",
    )
  result = transport.receiveOwned()
  transport.activeReceive = result

func isSendableCloseCode(code: GatewayCloseCode): bool {.raises: [].} =
  let value = code.toUint16()
  value in 1000'u16..4999'u16 and
    value notin [1004'u16, 1005'u16, 1006'u16, 1015'u16] and
    value notin 1016'u16..2999'u16

proc closeOwned(
    transport: GatewayTransport;
    code: GatewayCloseCode;
    reason: string,
): Future[void] {.async.} =
  transport.currentState = gatewayTransportClosing
  transport.reapSends()
  if transport.activeSends.len > 0:
    # A WebSocket close racing a queued or fragmented send makes delivery
    # ambiguous. Cancel all transport-owned sends; their cancellation path
    # aborts the stream, so no send can complete successfully after close.
    let pending = move transport.activeSends
    await cancelAndWait(pending)
    if transport.currentState == gatewayTransportClosedState:
      return
  if not transport.activeReceive.isNil and
      not transport.activeReceive.finished:
    # `websock.close` reads the peer's close reply. Cancel and join the existing
    # reader first; drivers that cannot preserve a graceful handshake on read
    # cancellation abort the connection rather than starting a second reader.
    let pending = transport.activeReceive
    await pending.cancelAndWait()
    if transport.currentState == gatewayTransportClosedState:
      return
  try:
    await transport.driver.closeProc(code, reason)
    transport.currentState = gatewayTransportClosedState
  except CancelledError:
    transport.abort()
    raise
  except GatewayTransportError as exc:
    transport.abort()
    raise newException(
      GatewayTransportError,
      "gateway transport close failed: " & exc.msg,
      exc,
    )

proc closeWait*(
    transport: GatewayTransport;
    code = GatewayCloseCode(1000);
    reason = "",
): Future[void] =
  ## Sends a close frame and releases all connection resources.
  ##
  ## Close reasons are limited to 123 bytes so the complete RFC 6455 control
  ## payload fits in 125 bytes. Concurrent calls share one close operation. If
  ## a send or receive is active, it is cancelled and joined first; the driver
  ## aborts instead of claiming a graceful close across ambiguous I/O.
  if transport.isNil or transport.currentState == gatewayTransportClosedState:
    result = newFuture[void]("cordnim.gateway.already-closed")
    result.complete()
    return
  if not code.isSendableCloseCode:
    raise newException(ValueError, "invalid WebSocket close code")
  if reason.len > 123:
    raise newException(ValueError, "WebSocket close reason exceeds 123 bytes")
  if reason.validateUtf8() != -1:
    raise newException(ValueError, "WebSocket close reason is not valid UTF-8")
  if not transport.closeOperation.isNil:
    return transport.closeOperation
  transport.closeOperation = transport.closeOwned(code, reason)
  transport.closeOperation
