import std/[json, options, strutils, unittest]

import chronos

import cordnim/core/errors
import cordnim/rest

proc forbiddenTransport(request: RawRequest): Future[TransportResponse]
    {.gcsafe, raises: [].} =
  let future = newFuture[TransportResponse]("test.checked.forbidden")
  let serialized = $(%*{"code": 50_013, "message": "Missing Permissions"})
  var body = newSeq[byte](serialized.len)
  for index, value in serialized:
    body[index] = byte(ord(value))
  future.complete TransportResponse(
    status: 403,
    headers: @[("X-RateLimit-Bucket", "bucket-a")],
    body: body
  )
  future

func testRequest(): RawRequest =
  RawRequest(
    route: routeKey(hmPost, "/webhooks/{webhook_id}/{webhook_token}",
      "webhook_id=10"),
    urlPath: "/webhooks/10/credential-value",
    meta: defaultRequestMeta()
  )

suite "checked REST errors":
  test "maps Discord failures without exposing a token-bearing path":
    proc scenario(): Future[ref DiscordError] {.async.} =
      let client = newChronosRestClient(forbiddenTransport)
      client.start()
      try:
        discard await client.submitChecked(testRequest())
      except DiscordError as error:
        await client.stop()
        return error
      await client.stop()
      return nil

    let error = waitFor scenario()
    check error of PermissionError
    check error.metadata.status == some(403)
    check error.metadata.discordCode == some(50_013'i64)
    check error.metadata.bucket == some("bucket-a")
    check "credential-value" notin error.msg
    check "credential-value" notin error.metadata.route.get()

  test "attempt captures Discord errors in one Result layer":
    proc scenario(): Future[RestAttempt[TransportResponse]] {.async.} =
      let client = newChronosRestClient(forbiddenTransport)
      client.start()
      let captured = await attempt(client,
        client.submitChecked(testRequest()))
      await client.stop()
      return captured

    let captured = waitFor scenario()
    check captured.isErr
    check captured.error() of PermissionError
