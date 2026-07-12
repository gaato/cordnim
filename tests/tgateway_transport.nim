import std/[assertions, base64, options, strutils]

import chronos
import nimcrypto/[hash, sha]

import cordnim/gateway/[close_policy, transport, websocket_chronos]

type FakeDriverState = ref object
  connectedUrls: seq[string]
  sentMessages: seq[GatewayMessage]
  events: seq[GatewayTransportEvent]
  nextEvent: int
  closeCalls: seq[GatewayCloseInfo]
  abortCalls: int
  failConnect: bool
  cancelReceive: bool
  pendingSend: GatewayDriverVoidFuture
  pendingReceive: GatewayDriverEventFuture

type
  TestWireFrame = object
    opcode: uint8
    payload: seq[byte]

  LocalServerMode = enum
    localRoundTrip,
    localFragmentedThenClose,
    localEmptyClose,
    localForbiddenCloseCode,
    localOversize,
    localInvalidCloseReason,
    localPending

  LocalWebSocketState = ref object
    mode: LocalServerMode
    receivedText: string
    returnedCloseCode: uint16
    returnedCloseReason: string
    failure: string
    done: AsyncEvent

proc readMaskedFrame(client: StreamTransport): Future[TestWireFrame] {.
    async: (raises: [CancelledError, TransportError, ValueError]).} =
  var header: array[2, byte]
  await client.readExactly(addr header[0], header.len)
  result.opcode = header[0] and 0x0F'u8
  if (header[1] and 0x80'u8) == 0:
    raise newException(ValueError, "client test frame was not masked")
  let length = int(header[1] and 0x7F'u8)
  if length >= 126:
    raise newException(ValueError, "test server supports short frames only")
  var mask: array[4, byte]
  await client.readExactly(addr mask[0], mask.len)
  result.payload = newSeq[byte](length)
  if length > 0:
    await client.readExactly(addr result.payload[0], result.payload.len)
    for index in 0..<result.payload.len:
      result.payload[index] = result.payload[index] xor mask[index mod 4]

func unmaskedFrame(
    opcode: uint8;
    payload: openArray[byte];
    fin = true,
): seq[byte] {.raises: [].} =
  doAssert payload.len < 126
  let firstByte = (if fin: 0x80'u8 else: 0'u8) or opcode
  result = @[firstByte, uint8(payload.len)]
  result.add(payload)

func stringBytes(value: string): seq[byte] {.raises: [].} =
  result = newSeq[byte](value.len)
  for index, character in value:
    result[index] = byte(character)

func bytesString(value: openArray[byte]): string {.raises: [].} =
  result = newString(value.len)
  for index, item in value:
    result[index] = char(item)

proc serveWebSocket(
    server: StreamServer;
    client: StreamTransport,
) {.async: (raises: []).} =
  let state = cast[LocalWebSocketState](server.udata)
  try:
    let requestLine = await client.readLine()
    if not requestLine.startsWith("GET /gateway?v=10&encoding=json HTTP/1.1"):
      raise newException(ValueError, "unexpected WebSocket request line")
    var key = ""
    while true:
      let line = await client.readLine()
      if line.len == 0:
        break
      let separator = line.find(':')
      if separator > 0 and
          line[0..<separator].strip().toLowerAscii() == "sec-websocket-key":
        key = line[separator + 1..^1].strip()
    if key.len == 0:
      raise newException(ValueError, "WebSocket key was missing")
    let accept = base64.encode(sha1.digest(
      key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
    ).data)
    let response =
      "HTTP/1.1 101 Switching Protocols\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: Upgrade\r\n" &
      "Sec-WebSocket-Accept: " & accept & "\r\n\r\n"
    discard await client.write(response)

    case state.mode
    of localRoundTrip:
      let clientText = await readMaskedFrame(client)
      if clientText.opcode != 0x1'u8:
        raise newException(ValueError, "client did not send a text frame")
      state.receivedText = clientText.payload.bytesString()

      discard await client.write(unmaskedFrame(
        0x1'u8,
        stringBytes("ser"),
        fin = false,
      ))
      discard await client.write(unmaskedFrame(0x0'u8, stringBytes("ver")))
      discard await client.write(unmaskedFrame(0x2'u8, @[7'u8, 8]))
      var closePayload = @[0x0F'u8, 0xA9] # 4009
      closePayload.add(stringBytes("再開"))
      discard await client.write(unmaskedFrame(0x8'u8, closePayload))

      let closeReply = await readMaskedFrame(client)
      if closeReply.opcode != 0x8'u8 or closeReply.payload.len < 2:
        raise newException(ValueError, "client close reply was malformed")
      state.returnedCloseCode =
        (uint16(closeReply.payload[0]) shl 8) or uint16(closeReply.payload[1])
      if closeReply.payload.len > 2:
        state.returnedCloseReason =
          closeReply.payload.toOpenArray(2, closeReply.payload.high).bytesString()
    of localFragmentedThenClose:
      discard await client.write(unmaskedFrame(
        0x1'u8,
        stringBytes("unfinished"),
        fin = false,
      ))
      var closePayload = @[0x0F'u8, 0xAE] # 4014
      closePayload.add(stringBytes("意図"))
      discard await client.write(unmaskedFrame(0x8'u8, closePayload))

      let closeReply = await readMaskedFrame(client)
      if closeReply.opcode != 0x8'u8 or closeReply.payload.len < 2:
        raise newException(ValueError, "client close reply was malformed")
      state.returnedCloseCode =
        (uint16(closeReply.payload[0]) shl 8) or uint16(closeReply.payload[1])
      if closeReply.payload.len > 2:
        state.returnedCloseReason =
          closeReply.payload.toOpenArray(2, closeReply.payload.high).bytesString()
    of localEmptyClose:
      discard await client.write(unmaskedFrame(0x8'u8, []))
      let closeReply = await readMaskedFrame(client)
      if closeReply.opcode != 0x8'u8 or closeReply.payload.len != 0:
        raise newException(ValueError,
          "client did not echo an empty close payload")
    of localForbiddenCloseCode:
      # 1015 is an application-side TLS sentinel and is forbidden on the wire.
      discard await client.write(unmaskedFrame(
        0x8'u8,
        @[0x03'u8, 0xF7'u8],
      ))
      discard await client.read(1)
    of localOversize:
      discard await client.write(unmaskedFrame(
        0x1'u8,
        stringBytes("123"),
        fin = false,
      ))
      discard await client.write(unmaskedFrame(0x0'u8, stringBytes("45")))
      discard await client.read(1)
    of localInvalidCloseReason:
      discard await client.write(unmaskedFrame(0x2'u8, @[1'u8]))
      discard await client.write(unmaskedFrame(
        0x8'u8,
        @[0x0F'u8, 0xA9, 0xFF],
      ))
      discard await client.read(1)
    of localPending:
      discard await client.read(1)
  except CatchableError as exc:
    state.failure = exc.msg
  finally:
    await client.closeWait()
    state.done.fire()

proc completed(): GatewayDriverVoidFuture {.raises: [].} =
  result = GatewayDriverVoidFuture.init("fake.gateway.completed")
  result.complete()

proc failed(message: string): GatewayDriverVoidFuture {.raises: [].} =
  result = GatewayDriverVoidFuture.init("fake.gateway.failed")
  result.fail(newException(GatewayTransportError, message))

proc cancelledEvent(): GatewayDriverEventFuture {.raises: [].} =
  result = GatewayDriverEventFuture.init("fake.gateway.cancelled")
  result.fail(newException(CancelledError, "test cancellation"))

proc readyEvent(event: GatewayTransportEvent): GatewayDriverEventFuture {.
    raises: [].} =
  result = GatewayDriverEventFuture.init("fake.gateway.event")
  result.complete(event)

proc newFakeDriver(state: FakeDriverState): GatewayTransportDriver =
  proc connectCallback(url: string): GatewayDriverVoidFuture {.
      closure, gcsafe, raises: [].} =
    state.connectedUrls.add(url)
    if state.failConnect:
      failed("injected connect failure")
    else:
      completed()

  proc sendCallback(message: GatewayMessage): GatewayDriverVoidFuture {.
      closure, gcsafe, raises: [].} =
    state.sentMessages.add(message)
    if state.pendingSend.isNil:
      completed()
    else:
      state.pendingSend

  proc receiveCallback(): GatewayDriverEventFuture {.
      closure, gcsafe, raises: [].} =
    if not state.pendingReceive.isNil:
      return state.pendingReceive
    if state.cancelReceive:
      return cancelledEvent()
    if state.nextEvent >= state.events.len:
      result = GatewayDriverEventFuture.init("fake.gateway.empty")
      result.fail(newException(
        GatewayTransportError,
        "fake event queue is empty",
      ))
      return
    result = readyEvent(state.events[state.nextEvent])
    state.nextEvent.inc

  proc closeCallback(
      code: GatewayCloseCode;
      reason: string,
  ): GatewayDriverVoidFuture {.closure, gcsafe, raises: [].} =
    state.closeCalls.add(GatewayCloseInfo(
      code: code,
      reason: reason,
      clean: true,
    ))
    completed()

  proc abortCallback() {.closure, gcsafe, raises: [].} =
    state.abortCalls.inc

  newGatewayTransportDriver(
    connectCallback,
    sendCallback,
    receiveCallback,
    closeCallback,
    abortCallback,
  )

block injected_driver_covers_message_and_remote_close_lifecycle:
  let fake = FakeDriverState(events: @[
    messageEvent(textGatewayMessage("{\"op\":10}")),
    messageEvent(binaryGatewayMessage(@[0x78'u8, 0x9C'u8])),
    closeEvent(GatewayCloseInfo(
      code: GatewayCloseCode(4014),
      reason: "disallowed intents",
      clean: true,
    )),
  ])
  let transport = waitFor connectGatewayTransport(
    "wss://gateway.discord.gg/?v=10&encoding=json",
    newFakeDriver(fake),
  )
  doAssert transport.state == gatewayTransportOpen
  doAssert fake.connectedUrls == @[
    "wss://gateway.discord.gg/?v=10&encoding=json",
  ]

  waitFor transport.sendText("{\"op\":1,\"d\":null}")
  waitFor transport.sendBinary(@[1'u8, 2, 3])
  doAssert fake.sentMessages.len == 2
  doAssert fake.sentMessages[0].kind == gatewayTextMessage
  doAssert fake.sentMessages[0].text() == "{\"op\":1,\"d\":null}"
  doAssert fake.sentMessages[1].kind == gatewayBinaryMessage
  doAssert fake.sentMessages[1].data == @[1'u8, 2, 3]

  let hello = waitFor transport.receive()
  doAssert hello.kind == gatewayMessageReceived
  doAssert hello.message.text() == "{\"op\":10}"
  let compressed = waitFor transport.receive()
  doAssert compressed.message.kind == gatewayBinaryMessage
  doAssert compressed.message.data == @[0x78'u8, 0x9C'u8]

  let closed = waitFor transport.receive()
  doAssert closed.kind == gatewayTransportClosed
  doAssert closed.closeInfo.code.toUint16() == 4014
  doAssert transport.state == gatewayTransportClosedState
  doAssert transport.remoteClose().get().reason == "disallowed intents"
  doAssertRaises GatewayTransportStateError:
    waitFor transport.sendText("after close")

block local_close_is_idempotent_and_preserves_code:
  let fake = FakeDriverState()
  let transport = waitFor connectGatewayTransport(
    "ws://127.0.0.1:8080/gateway",
    newFakeDriver(fake),
  )
  waitFor transport.closeWait(GatewayCloseCode(1000), "shutdown")
  doAssert transport.isClosed
  doAssert fake.closeCalls.len == 1
  doAssert fake.closeCalls[0].code.toUint16() == 1000
  doAssert fake.closeCalls[0].reason == "shutdown"
  doAssert fake.abortCalls == 0
  waitFor transport.closeWait()
  doAssert fake.closeCalls.len == 1

block invalid_local_close_does_not_mutate_open_state:
  let fake = FakeDriverState()
  let transport = waitFor connectGatewayTransport(
    "ws://127.0.0.1:8080/gateway",
    newFakeDriver(fake),
  )
  doAssertRaises ValueError:
    waitFor transport.closeWait(GatewayCloseCode(1006))
  doAssert transport.state == gatewayTransportOpen
  doAssert fake.closeCalls.len == 0
  transport.abort()

block invalid_utf8_does_not_reach_the_driver_or_close_the_transport:
  let fake = FakeDriverState()
  let transport = waitFor connectGatewayTransport(
    "ws://127.0.0.1:8080/gateway",
    newFakeDriver(fake),
  )
  doAssertRaises ValueError:
    waitFor transport.send(GatewayMessage(
      kind: gatewayTextMessage,
      data: @[0xFF'u8],
    ))
  doAssert transport.state == gatewayTransportOpen
  doAssert fake.sentMessages.len == 0

  doAssertRaises ValueError:
    waitFor transport.closeWait(GatewayCloseCode(1000), "\xFF")
  doAssert transport.state == gatewayTransportOpen
  doAssert fake.closeCalls.len == 0
  transport.abort()

block cancellation_aborts_the_driver:
  let fake = FakeDriverState(cancelReceive: true)
  let transport = waitFor connectGatewayTransport(
    "ws://127.0.0.1:8080/gateway",
    newFakeDriver(fake),
  )
  doAssertRaises CancelledError:
    discard waitFor transport.receive()
  doAssert transport.isClosed
  doAssert fake.abortCalls == 1

block close_cancels_and_joins_the_single_active_reader:
  let fake = FakeDriverState(
    pendingReceive: GatewayDriverEventFuture.init("fake.gateway.pending"),
  )
  let transport = waitFor connectGatewayTransport(
    "ws://127.0.0.1:8080/gateway",
    newFakeDriver(fake),
  )
  let receiveFuture = transport.receive()
  doAssert not receiveFuture.finished
  doAssertRaises GatewayTransportStateError:
    discard transport.receive()

  waitFor transport.closeWait()
  doAssert transport.isClosed
  doAssert fake.abortCalls == 1
  doAssert fake.closeCalls.len == 0
  doAssertRaises CancelledError:
    discard waitFor receiveFuture

block close_cancels_and_joins_active_sends_before_aborting:
  let fake = FakeDriverState(
    pendingSend: GatewayDriverVoidFuture.init("fake.gateway.pending-send"),
  )
  let transport = waitFor connectGatewayTransport(
    "ws://127.0.0.1:8080/gateway",
    newFakeDriver(fake),
  )
  let sendFuture = transport.sendText("in flight")
  doAssert not sendFuture.finished

  waitFor transport.closeWait()
  doAssert transport.isClosed
  doAssert fake.abortCalls == 1
  doAssert fake.closeCalls.len == 0
  doAssertRaises CancelledError:
    waitFor sendFuture

block failed_connect_aborts_partial_driver:
  let fake = FakeDriverState(failConnect: true)
  doAssertRaises GatewayTransportError:
    discard waitFor connectGatewayTransport(
      "ws://127.0.0.1:8080/gateway",
      newFakeDriver(fake),
    )
  doAssert fake.abortCalls == 1

block driver_constructor_rejects_missing_callbacks:
  doAssertRaises ValueError:
    discard newGatewayTransportDriver(
      GatewayDriverConnectProc(nil),
      GatewayDriverSendProc(nil),
      GatewayDriverReceiveProc(nil),
      GatewayDriverCloseProc(nil),
      GatewayDriverAbortProc(nil),
    )

block production_driver_rejects_non_websocket_url_without_network_io:
  doAssertRaises GatewayTransportError:
    discard waitFor connectChronosGatewayTransport(
      "https://gateway.discord.gg/?v=10&encoding=json",
    )

block production_driver_rejects_plaintext_non_loopback_without_network_io:
  doAssertRaises GatewayTransportError:
    discard waitFor connectChronosGatewayTransport(
      "ws://gateway.discord.gg/?v=10&encoding=json",
    )

block websock_adapter_preserves_4009_and_utf8_reason:
  let serverState = LocalWebSocketState(
    mode: localRoundTrip,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
  )
  waitFor transport.sendText("client")

  let textEvent = waitFor transport.receive()
  doAssert textEvent.kind == gatewayMessageReceived
  doAssert textEvent.message.text() == "server"
  let binaryEvent = waitFor transport.receive()
  doAssert binaryEvent.message.kind == gatewayBinaryMessage
  doAssert binaryEvent.message.data == @[7'u8, 8]
  let closeEventValue = waitFor transport.receive()
  doAssert closeEventValue.kind == gatewayTransportClosed
  doAssert closeEventValue.closeInfo.code.toUint16() == 4009
  doAssert closeEventValue.closeInfo.reason == "再開"
  doAssert closeEventValue.closeInfo.clean

  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure
  doAssert serverState.receivedText == "client"
  doAssert serverState.returnedCloseCode == 4009
  doAssert serverState.returnedCloseReason == "再開"

block websock_adapter_preserves_close_during_fragmented_text_receive:
  let serverState = LocalWebSocketState(
    mode: localFragmentedThenClose,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
  )
  let closeEventValue = waitFor transport.receive()
  doAssert closeEventValue.kind == gatewayTransportClosed
  doAssert closeEventValue.closeInfo.code.toUint16() == 4014
  doAssert closeEventValue.closeInfo.reason == "意図"
  doAssert closeEventValue.closeInfo.clean

  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure
  doAssert serverState.returnedCloseCode == 4014
  doAssert serverState.returnedCloseReason == "意図"

block websock_adapter_echoes_an_empty_close_without_code_1005:
  let serverState = LocalWebSocketState(
    mode: localEmptyClose,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
  )
  let closeEventValue = waitFor transport.receive()
  doAssert closeEventValue.kind == gatewayTransportClosed
  doAssert closeEventValue.closeInfo.code.toUint16() == 1005
  doAssert closeEventValue.closeInfo.reason.len == 0
  doAssert closeEventValue.closeInfo.clean

  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure

block websock_adapter_rejects_forbidden_close_code_1015:
  let serverState = LocalWebSocketState(
    mode: localForbiddenCloseCode,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
  )
  doAssertRaises GatewayTransportError:
    discard waitFor transport.receive()
  doAssert transport.isClosed

  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure

block websock_adapter_bounds_fragment_aggregate_receive:
  let serverState = LocalWebSocketState(
    mode: localOversize,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
    maxMessageBytes = 4,
  )
  doAssertRaises GatewayTransportError:
    discard waitFor transport.receive()
  doAssert transport.isClosed
  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure

block websock_adapter_validates_close_utf8_after_a_binary_message:
  let serverState = LocalWebSocketState(
    mode: localInvalidCloseReason,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
  )
  let binaryEvent = waitFor transport.receive()
  doAssert binaryEvent.message.kind == gatewayBinaryMessage
  doAssert binaryEvent.message.data == @[1'u8]
  doAssertRaises GatewayTransportError:
    discard waitFor transport.receive()
  doAssert transport.isClosed
  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure

block cancelling_websock_receive_closes_underlying_stream:
  let serverState = LocalWebSocketState(
    mode: localPending,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
  )
  let receiveFuture = transport.receive()
  waitFor sleepAsync(1.milliseconds)
  receiveFuture.cancelSoon()
  doAssertRaises CancelledError:
    discard waitFor receiveFuture
  doAssert transport.isClosed
  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure

block close_wait_owns_and_joins_a_pending_websock_receive:
  let serverState = LocalWebSocketState(
    mode: localPending,
    done: newAsyncEvent(),
  )
  let server = createStreamServer(
    initTAddress("127.0.0.1:0"),
    serveWebSocket,
    {ServerFlags.ReuseAddr},
    udata = serverState,
  )
  server.start()
  let port = uint16(server.localAddress().port)
  let transport = waitFor connectChronosGatewayTransport(
    "ws://127.0.0.1:" & $port & "/gateway?v=10&encoding=json",
  )
  let receiveFuture = transport.receive()
  waitFor sleepAsync(1.milliseconds)
  waitFor transport.closeWait()
  doAssert transport.isClosed
  doAssertRaises CancelledError:
    discard waitFor receiveFuture
  waitFor serverState.done.wait()
  server.stop()
  waitFor server.closeWait()
  doAssert serverState.failure.len == 0, serverState.failure

block message_helpers_keep_text_and_binary_distinct:
  doAssert textGatewayMessage("hello").text() == "hello"
  doAssertRaises ValueError:
    discard binaryGatewayMessage(@[0'u8]).text()
