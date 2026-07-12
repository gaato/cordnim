## Deterministic scripted implementation of the Gateway transport driver.
##
## A ScriptedGatewayDriver produces a GatewayTransportDriver whose callbacks
## are backed by an in-memory script instead of a WebSocket. A test queues the
## GatewayTransportEvent values that receive should return, along with optional
## end-of-stream, failure, cancellation, and never-completing reactions, and
## observes each client send, graceful close, and abort. Receive scripts can
## model cancellation and a stalled read. Connect, send, and close complete
## immediately, so timing-sensitive tests should supply a custom driver.

import std/[json, options, strutils]

import chronos

import cordnim/gateway/close_policy
import cordnim/gateway/transport

import ./canonical_json
import ./redaction

type
  GatewayReactionKind = enum
    grkEvent ## Return a scripted receive event.
    grkFail ## Fail the receive with a transport error.
    grkCancel ## Cancel the receive, mirroring a torn-down connection.
    grkPending ## Never complete, modelling a stalled read.

  GatewayReaction = object
    case kind: GatewayReactionKind
    of grkEvent:
      event: GatewayTransportEvent
    of grkFail:
      message: string
    of grkCancel, grkPending:
      discard

  GatewaySendExpectation = object
    expectedText: Option[string]
    expectedJson: Option[JsonNode]

  ScriptedGatewayDriver* = ref object ## Mutable script and observation log for a
    ## scripted Gateway driver.
    reactions: seq[GatewayReaction]
    cursor: int
    connectedUrls: seq[string]
    sends: seq[GatewayMessage]
    expectedSends: seq[GatewaySendExpectation]
    sendCursor: int
    sendFailures: seq[string]
    closeCalls: seq[GatewayCloseInfo]
    abortCount: int
    connectShouldFail: bool
    connectFailMessage: string
    pendingReceives: seq[GatewayDriverEventFuture]
    redaction: RedactionConfig
    allowUnexpectedSends: bool

func newScriptedGatewayDriver*(
    redaction = defaultRedaction();
    allowUnexpectedSends = false): ScriptedGatewayDriver =
  ## Creates a driver that rejects sends beyond its queued expectations.
  ##
  ## Set `allowUnexpectedSends` only for observation-only tests that deliberately
  ## do not assert the outbound sequence.
  ScriptedGatewayDriver(
    redaction: redaction.hardenedRedaction(),
    allowUnexpectedSends: allowUnexpectedSends)

func copyBytes(value: openArray[byte]): seq[byte] =
  result = newSeq[byte](value.len)
  for index, item in value:
    result[index] = item

func copyMessage(message: GatewayMessage): GatewayMessage =
  GatewayMessage(kind: message.kind, data: message.data.copyBytes())

func copyEvent(event: GatewayTransportEvent): GatewayTransportEvent =
  case event.kind
  of gatewayMessageReceived:
    messageEvent(event.message.copyMessage())
  of gatewayTransportClosed:
    closeEvent(event.closeInfo)

proc sanitizedMessage(driver: ScriptedGatewayDriver,
                      message: GatewayMessage): GatewayMessage =
  case message.kind
  of gatewayTextMessage:
    let original = try:
        message.text()
      except ValueError:
        ""
    textGatewayMessage(driver.redaction.redactJsonText(original))
  of gatewayBinaryMessage:
    # Opaque or compressed bytes cannot be inspected safely without the full
    # connection decoder state. Preserve the kind, never the bytes.
    binaryGatewayMessage(@[])

proc queueEvent*(driver: ScriptedGatewayDriver,
                 event: GatewayTransportEvent) =
  ## Queues one transport event for the next `receive`.
  driver.reactions.add(GatewayReaction(
    kind: grkEvent, event: event.copyEvent()))

proc queueMessageText*(driver: ScriptedGatewayDriver, value: string) =
  ## Queues one received text message (typically a JSON Gateway payload).
  driver.queueEvent(messageEvent(textGatewayMessage(value)))

proc queueMessageBinary*(driver: ScriptedGatewayDriver, value: seq[byte]) =
  ## Queues one received binary message, such as compressed Gateway data.
  driver.queueEvent(messageEvent(binaryGatewayMessage(value)))

proc queueClose*(driver: ScriptedGatewayDriver, code: GatewayCloseCode,
                 reason = "", clean = true) =
  ## Queues a peer-close event ending the scripted stream.
  driver.queueEvent(closeEvent(GatewayCloseInfo(
    code: code, reason: reason, clean: clean)))

proc queueReceiveFailure*(driver: ScriptedGatewayDriver,
                          message = "scripted gateway receive failure") =
  ## Queues a transport failure for the next `receive`.
  driver.reactions.add(GatewayReaction(kind: grkFail, message: message))

proc queueReceiveCancellation*(driver: ScriptedGatewayDriver) =
  ## Queues a cancelled `receive`, mirroring a torn-down connection.
  driver.reactions.add(GatewayReaction(kind: grkCancel))

proc queueReceivePending*(driver: ScriptedGatewayDriver) =
  ## Queues a `receive` that never completes, modelling a stalled read.
  driver.reactions.add(GatewayReaction(kind: grkPending))

proc expectSendText*(driver: ScriptedGatewayDriver, value: string) =
  ## Requires the next observed send to be this exact text message.
  driver.expectedSends.add(GatewaySendExpectation(
    expectedText: some(value)))

proc expectSendJson*(driver: ScriptedGatewayDriver, document: JsonNode) =
  ## Requires the next observed send to be value-equal JSON text.
  driver.expectedSends.add(GatewaySendExpectation(
    expectedJson: some(document.copy())))

proc failConnect*(driver: ScriptedGatewayDriver,
                  message = "scripted gateway connect failure") =
  ## Configures the next connection attempt to fail.
  driver.connectShouldFail = true
  driver.connectFailMessage = message

proc completedVoid(): GatewayDriverVoidFuture {.raises: [].} =
  result = GatewayDriverVoidFuture.init("cordnim.testing.gateway.void")
  result.complete()

proc failedVoid(message: string): GatewayDriverVoidFuture {.raises: [].} =
  result = GatewayDriverVoidFuture.init("cordnim.testing.gateway.void")
  result.fail(newException(GatewayTransportError, message))

proc readyEventFuture(event: GatewayTransportEvent):
                      GatewayDriverEventFuture {.raises: [].} =
  result = GatewayDriverEventFuture.init("cordnim.testing.gateway.event")
  result.complete(event)

proc failedEventFuture(message: string):
                       GatewayDriverEventFuture {.raises: [].} =
  result = GatewayDriverEventFuture.init("cordnim.testing.gateway.event")
  result.fail(newException(GatewayTransportError, message))

proc cancelledEventFuture(): GatewayDriverEventFuture {.raises: [].} =
  result = GatewayDriverEventFuture.init("cordnim.testing.gateway.cancel")
  result.cancelSoon()

proc pendingEventFuture(): GatewayDriverEventFuture {.raises: [].} =
  GatewayDriverEventFuture.init("cordnim.testing.gateway.pending")

proc matchSend(expectation: GatewaySendExpectation,
               message: GatewayMessage): string {.raises: [].} =
  if expectation.expectedText.isSome:
    if message.kind != gatewayTextMessage:
      return "expected a text send but observed a binary message"
    try:
      if message.text() != expectation.expectedText.get():
        return "text send did not match the expected message"
    except ValueError:
      return "text send could not be decoded"
  if expectation.expectedJson.isSome:
    if message.kind != gatewayTextMessage:
      return "expected a JSON text send but observed a binary message"
    var parsed: JsonNode
    try:
      parsed = parseJson(message.text())
    except CatchableError:
      return "JSON send was not valid JSON text"
    let path = jsonMismatchPath(expectation.expectedJson.get(), parsed)
    if path.len != 0:
      return "JSON send mismatch at " & path
  ""

proc asDriver*(driver: ScriptedGatewayDriver): GatewayTransportDriver =
  ## Returns the `GatewayTransportDriver` backed by this scripted driver.
  ##
  ## Pass the result to `connectGatewayTransport` to drive real transport code
  ## against the queued script while recording every send, close, and abort.
  if driver.isNil:
    raise newException(ValueError, "scripted Gateway driver is required")
  proc connectCallback(url: string): GatewayDriverVoidFuture {.
      closure, gcsafe, raises: [].} =
    driver.connectedUrls.add(driver.redaction.redactUrl(url))
    if driver.connectShouldFail:
      driver.connectShouldFail = false
      let message = driver.connectFailMessage
      driver.connectFailMessage.setLen(0)
      failedVoid(message)
    else:
      completedVoid()

  proc sendCallback(message: GatewayMessage): GatewayDriverVoidFuture {.
      closure, gcsafe, raises: [].} =
    if driver.sendCursor < driver.expectedSends.len:
      let expectation = driver.expectedSends[driver.sendCursor]
      driver.expectedSends[driver.sendCursor] = GatewaySendExpectation()
      inc driver.sendCursor
      let mismatch = matchSend(expectation, message)
      if mismatch.len != 0:
        driver.sendFailures.add(mismatch)
    elif not driver.allowUnexpectedSends:
      driver.sendFailures.add("unexpected Gateway send")
    driver.sends.add(driver.sanitizedMessage(message))
    completedVoid()

  proc receiveCallback(): GatewayDriverEventFuture {.
      closure, gcsafe, raises: [].} =
    if driver.cursor >= driver.reactions.len:
      return failedEventFuture("no more scripted gateway events")
    var reaction: GatewayReaction
    case driver.reactions[driver.cursor].kind
    of grkEvent:
      reaction = GatewayReaction(
        kind: grkEvent,
        event: driver.reactions[driver.cursor].event.copyEvent())
    of grkFail:
      reaction = GatewayReaction(
        kind: grkFail,
        message: driver.reactions[driver.cursor].message)
    of grkCancel:
      reaction = GatewayReaction(kind: grkCancel)
    of grkPending:
      reaction = GatewayReaction(kind: grkPending)
    driver.reactions[driver.cursor] = GatewayReaction(kind: grkCancel)
    inc driver.cursor
    case reaction.kind
    of grkEvent:
      readyEventFuture(reaction.event)
    of grkFail:
      failedEventFuture(reaction.message)
    of grkCancel:
      cancelledEventFuture()
    of grkPending:
      let pending = pendingEventFuture()
      driver.pendingReceives.add(pending)
      pending

  proc closeCallback(code: GatewayCloseCode; reason: string):
                     GatewayDriverVoidFuture {.closure, gcsafe, raises: [].} =
    driver.closeCalls.add(GatewayCloseInfo(
      code: code,
      reason: if reason.len == 0: "" else: redactedSecret,
      clean: true))
    completedVoid()

  proc abortCallback() {.closure, gcsafe, raises: [].} =
    inc driver.abortCount
    for pending in driver.pendingReceives:
      if not pending.finished:
        pending.cancelSoon()

  newGatewayTransportDriver(
    connectCallback,
    sendCallback,
    receiveCallback,
    closeCallback,
    abortCallback,
  )

func connectedUrls*(driver: ScriptedGatewayDriver): seq[string] =
  ## Returns an owned, redacted copy of connected URLs, in order.
  for url in driver.connectedUrls:
    result.add(url)

func sentMessages*(driver: ScriptedGatewayDriver): seq[GatewayMessage] =
  ## Returns owned, redacted copies of every client send, in order.
  for message in driver.sends:
    result.add(message.copyMessage())

func closeCalls*(driver: ScriptedGatewayDriver): seq[GatewayCloseInfo] =
  ## Returns owned, redacted copies of every graceful close request.
  for closeInfo in driver.closeCalls:
    result.add(closeInfo)

func abortCount*(driver: ScriptedGatewayDriver): int =
  ## Returns the number of immediate aborts requested by the transport.
  driver.abortCount

func pendingEventCount*(driver: ScriptedGatewayDriver): int =
  ## Returns the number of scripted reactions not yet consumed.
  driver.reactions.len - driver.cursor

func sendFailures*(driver: ScriptedGatewayDriver): seq[string] =
  ## Returns an owned copy of secret-safe send mismatch diagnostics.
  for failure in driver.sendFailures:
    result.add(failure)

func unfinishedReceiveCount*(driver: ScriptedGatewayDriver): int =
  ## Returns scripted driver futures still waiting for cancellation or completion.
  for pending in driver.pendingReceives:
    if not pending.finished:
      inc result

func unmetSendExpectations*(driver: ScriptedGatewayDriver): int =
  ## Returns the number of queued send expectations never matched by a send.
  driver.expectedSends.len - driver.sendCursor

func satisfied*(driver: ScriptedGatewayDriver): bool =
  ## Reports that all reactions and send expectations were consumed cleanly.
  driver.pendingEventCount == 0 and driver.unmetSendExpectations == 0 and
    driver.sendFailures.len == 0 and driver.unfinishedReceiveCount == 0

proc assertNoPendingEvents*(driver: ScriptedGatewayDriver) =
  ## Asserts that every queued reaction was consumed by a receive.
  if driver.pendingEventCount != 0:
    raise newException(AssertionDefect,
      $driver.pendingEventCount & " scripted gateway events were never consumed")

proc assertSendsMatched*(driver: ScriptedGatewayDriver) =
  ## Asserts that all send expectations were met without a mismatch.
  if driver.sendFailures.len != 0:
    raise newException(AssertionDefect,
      "scripted gateway send mismatches: " & driver.sendFailures.join("; "))
  if driver.unmetSendExpectations != 0:
    raise newException(AssertionDefect,
      $driver.unmetSendExpectations &
      " scripted gateway send expectations were never met")

proc assertNoPendingOperations*(driver: ScriptedGatewayDriver) =
  ## Asserts that no never-completing receive future remains live.
  if driver.unfinishedReceiveCount != 0:
    raise newException(AssertionDefect,
      $driver.unfinishedReceiveCount &
      " scripted gateway receive operations remain unfinished")

proc assertSatisfied*(driver: ScriptedGatewayDriver) =
  ## Asserts that no reaction or send expectation was left outstanding.
  driver.assertSendsMatched()
  driver.assertNoPendingEvents()
  driver.assertNoPendingOperations()
