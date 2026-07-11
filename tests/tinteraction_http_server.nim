import std/[strutils, times, unittest]

import chronos
import chronos/apps/http/httpclient

import cordnim/interactions
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
