## Chronos HTTP ingress for Discord interactions.
##
## Signature verification and replay rejection happen before the application
## handler sees body bytes. The server enforces the same body bound while
## streaming at the Chronos HTTP layer.

import std/times

import chronos
import chronos/apps/http/[httptable, httpserver]
import httputils

import cordnim/build_info
import cordnim/rest/chronos_driver
import cordnim/rest/request
import ./verification

type
  InteractionDeliveryCallback* = proc() {.gcsafe, raises: [].}
    ## Records whether Discord's immediate HTTP acknowledgement was delivered.

  InteractionHttpResponse* = object ## Immediate Discord webhook response.
    status*: int ## HTTP status, normally 200.
    contentType*: string ## Response media type.
    body*: seq[byte] ## Serialized interaction response.
    deliveryConfirmed*: InteractionDeliveryCallback
      ## Called after the response write completes successfully.
    deliveryUnknown*: InteractionDeliveryCallback
      ## Called when a started response write has ambiguous delivery.

  InteractionHttpHandler* = proc(body: seq[byte],
                                  receivedAt: MonoMillis):
                                  Future[InteractionHttpResponse]
    {.gcsafe, raises: [].} ## Verified application handler.

  InteractionHttpServer* = ref object ## Owned Chronos interaction listener.
    server: HttpServerRef
    verification: VerificationConfig
    replay: ReplayCache
    endpointPath: string
    handler: InteractionHttpHandler

  DeliveryNotifier = object
    confirmed: InteractionDeliveryCallback
    unknown: InteractionDeliveryCallback
    finished: bool

func jsonInteractionResponse*(body: sink seq[byte],
                              status = 200,
                              deliveryConfirmed: InteractionDeliveryCallback =
                                nil,
                              deliveryUnknown: InteractionDeliveryCallback =
                                nil): InteractionHttpResponse =
  ## Creates a JSON response suitable for Discord's interaction callback.
  InteractionHttpResponse(
    status: status,
    contentType: "application/json",
    body: body,
    deliveryConfirmed: deliveryConfirmed,
    deliveryUnknown: deliveryUnknown
  )

func initDeliveryNotifier(response: InteractionHttpResponse):
    DeliveryNotifier =
  DeliveryNotifier(
    confirmed: response.deliveryConfirmed,
    unknown: response.deliveryUnknown
  )

proc confirm(notifier: var DeliveryNotifier) {.raises: [].} =
  if not notifier.finished:
    notifier.finished = true
    if not notifier.confirmed.isNil:
      notifier.confirmed()

proc markUnknown(notifier: var DeliveryNotifier) {.raises: [].} =
  if not notifier.finished:
    notifier.finished = true
    if not notifier.unknown.isNil:
      notifier.unknown()

proc respond(request: HttpRequestRef, status: HttpCode, body: seq[byte],
             contentType = "text/plain; charset=utf-8"):
             Future[HttpResponseRef] {.
             async: (raises: [CancelledError, HttpWriteError]).} =
  var headers = HttpTable.init()
  headers.add("Content-Type", contentType)
  await request.respond(status, body, headers)

proc process(server: InteractionHttpServer,
             fence: RequestFence): Future[HttpResponseRef] {.
             async: (raises: [CancelledError]).} =
  if fence.isErr:
    return defaultResponse()
  let request = fence.get()
  # Discord's acknowledgement budget starts before body decoding, signature
  # verification, and application dispatch. Preserve the earliest monotonic
  # instant available to the Chronos callback so those costs count correctly.
  let receivedAt = monotonicMillis()
  if request.meth != MethodPost or request.uri.path != server.endpointPath:
    try:
      return await request.respond(Http404, @[])
    except HttpWriteError:
      return defaultResponse()

  let body =
    try:
      await request.getBody()
    except HttpProtocolError:
      try:
        return await request.respond(Http413, @[])
      except HttpWriteError:
        return defaultResponse()
    except HttpTransportError:
      return defaultResponse()

  let signature = request.headers.getString("X-Signature-Ed25519")
  let timestamp = request.headers.getString("X-Signature-Timestamp")
  let verified = server.verification.verifyInteractionRequest(
    server.replay, signature, timestamp, body, getTime().toUnix()
  )
  if verified.kind != ivValid:
    try:
      return await request.respond(Http401, @[])
    except HttpWriteError:
      return defaultResponse()

  let response =
    try:
      await server.handler(body, receivedAt)
    except CancelledError:
      raise
    except CatchableError:
      # Request bodies and tokens are deliberately absent from this generic
      # error response. Observability adapters receive only correlation
      # metadata.
      try:
        return await request.respond(Http500, @[])
      except HttpWriteError:
        return defaultResponse()

  let responseCode = response.status.toHttpCode()
  if responseCode.isNone:
    # Request bodies and tokens are deliberately absent from this generic error
    # response. Observability adapters receive only correlation metadata.
    try:
      return await request.respond(Http500, @[])
    except HttpWriteError:
      return defaultResponse()

  var delivery = initDeliveryNotifier(response)
  try:
    let sent = await request.respond(
      responseCode.get(), response.body, response.contentType
    )
    delivery.confirm()
    return sent
  except CancelledError:
    delivery.markUnknown()
    raise
  except HttpWriteError:
    delivery.markUnknown()
    return defaultResponse()

proc newInteractionHttpServer*(bindAddress: TransportAddress,
                               verification: VerificationConfig,
                               handler: InteractionHttpHandler,
                               endpointPath = "/interactions",
                               replayMaxEntries = DefaultReplayCacheEntries):
                               InteractionHttpServer =
  ## Binds a stopped HTTP interaction server.
  ##
  ## Raises `ValueError` for unsafe configuration or a bind failure. Call
  ## `start` only after all application routes and services are ready.
  ## `replayMaxEntries` should cover peak accepted requests across the complete
  ## signature timestamp window; a full cache deliberately fails closed.
  if verification.verifier.isNil:
    raise newException(ValueError, "interaction signature verifier is required")
  if verification.maxBodyBytes <= 0:
    raise newException(ValueError, "interaction body limit must be positive")
  if replayMaxEntries <= 0:
    raise newException(ValueError,
      "interaction replay cache capacity must be positive")
  if handler.isNil:
    raise newException(ValueError, "interaction HTTP handler is required")
  if endpointPath.len == 0 or endpointPath[0] != '/':
    raise newException(ValueError,
      "interaction endpoint must be an absolute path")

  result = InteractionHttpServer(
    verification: verification,
    replay: initReplayCache(replayMaxEntries),
    endpointPath: endpointPath,
    handler: handler
  )
  let state = result
  proc callback(fence: RequestFence): Future[HttpResponseRef] {.
      async: (raises: [CancelledError]).} =
    await state.process(fence)
  let built = HttpServerRef.new(
    bindAddress,
    callback,
    serverIdent = CordnimServerIdent,
    maxRequestBodySize = verification.maxBodyBytes
  )
  if built.isErr:
    raise newException(ValueError, "cannot bind interaction HTTP server: " &
      $built.error)
  result.server = built.get()

proc start*(server: InteractionHttpServer) =
  ## Starts accepting verified Discord interaction requests.
  server.server.start()

proc join*(server: InteractionHttpServer): Future[void] {.
           async: (raises: [CancelledError, ValueError]).} =
  ## Waits until the interaction listener is closed.
  if server.isNil or server.server.isNil:
    raise newException(ValueError, "interaction HTTP server is not initialized")
  await server.server.join()

proc close*(server: InteractionHttpServer): Future[void] {.
            async: (raises: []).} =
  ## Stops accepting, cancels connection tasks, and closes the listener.
  if not server.isNil and not server.server.isNil:
    await server.server.closeWait()

func localAddress*(server: InteractionHttpServer): TransportAddress =
  ## Returns the bound address, including an OS-assigned port.
  server.server.instance.localAddress()
