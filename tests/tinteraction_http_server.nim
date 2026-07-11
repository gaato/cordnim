import std/[atomics, strutils, times, unittest]

when defined(posix):
  import std/posix

import chronos
import chronos/apps/http/httpclient

import cordnim/interactions/[http_server, verification]
import cordnim/rest/request

proc acceptingVerifier(publicKey, signature, message: openArray[byte]): bool
    {.gcsafe, raises: [].} =
  publicKey.len == 32 and signature.len == 64 and message.len > 0

proc immediateHandler(body: seq[byte],
                      receivedAt: MonoMillis): Future[InteractionHttpResponse]
                      {.gcsafe, raises: [].} =
  discard body
  discard receivedAt
  let future = newFuture[InteractionHttpResponse]("test.interaction.handler")
  future.complete jsonInteractionResponse(@[byte '{', byte '}'])
  future

suite "Chronos interaction HTTP ingress":
  test "rejects a disabled replay cache before binding":
    expect ValueError:
      discard newInteractionHttpServer(
        initTAddress("127.0.0.1:0"),
        VerificationConfig(
          allowedSkewSeconds: 300,
          maxBodyBytes: 1_024,
          verifier: acceptingVerifier
        ),
        immediateHandler,
        replayMaxEntries = 0
      )

  test "verifies before dispatch and rejects a replay":
    proc scenario(): Future[tuple[first, second: int]] {.async.} =
      let server = newInteractionHttpServer(
        initTAddress("127.0.0.1:0"),
        VerificationConfig(
          allowedSkewSeconds: 300,
          maxBodyBytes: 1_024,
          verifier: acceptingVerifier
        ),
        immediateHandler
      )
      server.start()
      let session = HttpSessionRef.new({HttpClientFlag.Http11Pipeline})
      let timestamp = $getTime().toUnix()
      let headers = [
        ("Content-Type", "application/json"),
        ("X-Signature-Ed25519", repeat('a', 128)),
        ("X-Signature-Timestamp", timestamp)
      ]
      let url = "http://" & $server.localAddress & "/interactions"

      let firstRequest = HttpClientRequestRef.new(
        session, url, MethodPost,
        headers = headers,
        body = @[byte '{', byte '}']
      ).get()
      let firstResponse = await firstRequest.fetch()
      await firstRequest.closeWait()

      let secondRequest = HttpClientRequestRef.new(
        session, url, MethodPost,
        headers = headers,
        body = @[byte '{', byte '}']
      ).get()
      let secondResponse = await secondRequest.fetch()
      await secondRequest.closeWait()

      await session.closeWait()
      await server.close()
      return (firstResponse.status, secondResponse.status)

    let statuses = waitFor scenario()
    check statuses.first == 200
    check statuses.second == 401

  test "confirms a successful acknowledgement exactly once":
    var confirmed, unknown: Atomic[int]
    confirmed.store(0)
    unknown.store(0)

    proc recordConfirmed() {.gcsafe, raises: [].} =
      confirmed.store(confirmed.load() + 1)

    proc recordUnknown() {.gcsafe, raises: [].} =
      unknown.store(unknown.load() + 1)

    proc receiptHandler(body: seq[byte], receivedAt: MonoMillis):
        Future[InteractionHttpResponse] {.gcsafe, raises: [].} =
      discard body
      discard receivedAt
      result = newFuture[InteractionHttpResponse](
        "test.interaction.receipt-handler")
      result.complete jsonInteractionResponse(
        @[byte '{', byte '}'],
        deliveryConfirmed = recordConfirmed,
        deliveryUnknown = recordUnknown
      )

    proc scenario(): Future[tuple[status, confirmed, unknown: int]] {.async.} =
      let server = newInteractionHttpServer(
        initTAddress("127.0.0.1:0"),
        VerificationConfig(
          allowedSkewSeconds: 300,
          maxBodyBytes: 1_024,
          verifier: acceptingVerifier
        ),
        receiptHandler
      )
      server.start()
      let session = HttpSessionRef.new({HttpClientFlag.Http11Pipeline})
      let headers = [
        ("Content-Type", "application/json"),
        ("X-Signature-Ed25519", repeat('a', 128)),
        ("X-Signature-Timestamp", $getTime().toUnix())
      ]
      let request = HttpClientRequestRef.new(
        session,
        "http://" & $server.localAddress & "/interactions",
        MethodPost,
        headers = headers,
        body = @[byte '{', byte '}']
      ).get()
      let response = await request.fetch()
      await request.closeWait()

      await session.closeWait()
      await server.close()
      return (response.status, confirmed.load(), unknown.load())

    let receipt = waitFor scenario()
    check receipt.status == 200
    check receipt.confirmed == 1
    check receipt.unknown == 0

  when defined(posix):
    test "marks reset acknowledgement delivery unknown exactly once":
      var confirmed, unknown: Atomic[int]
      confirmed.store(0)
      unknown.store(0)

      proc recordConfirmed() {.gcsafe, raises: [].} =
        confirmed.store(confirmed.load() + 1)

      proc recordUnknown() {.gcsafe, raises: [].} =
        unknown.store(unknown.load() + 1)

      proc scenario(): Future[tuple[confirmed, unknown: int]] {.async.} =
        let handlerEntered = newFuture[void](
          "test.interaction.reset-handler-entered")
        let handlerResponse = newFuture[InteractionHttpResponse](
          "test.interaction.reset-handler-response")

        proc delayedHandler(body: seq[byte], receivedAt: MonoMillis):
            Future[InteractionHttpResponse] {.gcsafe, raises: [].} =
          discard body
          discard receivedAt
          if not handlerEntered.finished:
            handlerEntered.complete()
          handlerResponse

        let server = newInteractionHttpServer(
          initTAddress("127.0.0.1:0"),
          VerificationConfig(
            allowedSkewSeconds: 300,
            maxBodyBytes: 1_024,
            verifier: acceptingVerifier
          ),
          delayedHandler
        )
        server.start()
        var transport: StreamTransport
        try:
          transport = await connect(server.localAddress)
          let body = "{}"
          let request =
            "POST /interactions HTTP/1.1\r\n" &
            "Host: localhost\r\n" &
            "Content-Type: application/json\r\n" &
            "X-Signature-Ed25519: " & repeat('a', 128) & "\r\n" &
            "X-Signature-Timestamp: " & $getTime().toUnix() & "\r\n" &
            "Content-Length: " & $body.len & "\r\n\r\n" & body
          let written = await transport.write(request)
          doAssert written == request.len
          await handlerEntered

          var linger = posix.TLinger(l_onoff: 1, l_linger: 0)
          let optionResult = posix.setsockopt(
            cast[posix.SocketHandle](transport.fd),
            posix.SOL_SOCKET,
            posix.SO_LINGER,
            addr linger,
            posix.SockLen(sizeof(linger))
          )
          doAssert optionResult == 0
          await transport.closeWait()
          await sleepAsync(chronos.milliseconds(10))

          handlerResponse.complete jsonInteractionResponse(
            @[byte '{', byte '}'],
            deliveryConfirmed = recordConfirmed,
            deliveryUnknown = recordUnknown
          )
          var attempts = 0
          while unknown.load() == 0 and attempts < 100:
            await sleepAsync(chronos.milliseconds(5))
            inc attempts
          await sleepAsync(chronos.milliseconds(10))
          return (confirmed.load(), unknown.load())
        finally:
          if not transport.isNil:
            await transport.closeWait()
          await server.close()

      let receipt = waitFor scenario()
      check receipt.confirmed == 0
      check receipt.unknown == 1
