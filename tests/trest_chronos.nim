import std/unittest

import chronos

import cordnim/rest

proc fakeTransport(request: RawRequest): Future[TransportResponse]
    {.gcsafe, raises: [].} =
  let future = newFuture[TransportResponse]("fake.transport")
  future.complete TransportResponse(status: 200, body: request.body)
  future

proc makeRequest(path: string): RawRequest =
  RawRequest(
    route: routeKey(hmGet, path),
    urlPath: path,
    body: @[byte 1, 2, 3],
    meta: RequestMeta(
      priority: rpNormal,
      retryPolicy: defaultRetryPolicy(),
      idempotency: idSafe
    )
  )

suite "Chronos REST driver":
  test "executes scheduled requests and owns shutdown":
    proc scenario(): Future[TransportResponse] {.async.} =
      let client = newChronosRestClient(fakeTransport)
      client.start()
      let response = await client.submit(makeRequest("/gateway"))
      await client.stop()
      return response
    let response = waitFor scenario()
    check response.status == 200
    check response.body == @[byte 1, 2, 3]

  test "stopped clients fail instead of leaking a future":
    proc scenario(): Future[bool] {.async.} =
      let client = newChronosRestClient(fakeTransport)
      try:
        discard await client.submit(makeRequest("/gateway"))
        return false
      except CatchableError:
        return true
    check waitFor scenario()
