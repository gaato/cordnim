import std/[json, strutils, unittest]

import chronos

import cordnim/[commands, interactions]
import cordnim/rest

func text(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc fakeWebhookTransport(request: RawRequest): Future[TransportResponse]
    {.gcsafe, raises: [].} =
  doAssert request.urlPath.startsWith("/webhooks/200/")
  doAssert request.urlPath.endsWith("/messages/@original")
  doAssert "secret-token" in request.urlPath
  doAssert "finished" in request.body.text()
  let future = newFuture[TransportResponse]("test.webhook.transport")
  future.complete TransportResponse(status: 200)
  future

suite "deferred interaction webhook completion":
  test "uses the interaction token without bot authorization":
    proc scenario(): Future[void] {.async.} =
      let client = newChronosRestClient(fakeWebhookTransport)
      client.start()
      let sink = interactionWebhookCompletion(client)
      await sink(
        %*{"application_id": "200", "token": "secret-token"},
        succeeded("finished")
      )
      await client.stop()
    waitFor scenario()
