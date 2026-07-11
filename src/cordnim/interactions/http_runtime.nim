## Owned webhook-only application runtime.
##
## This factory wires the high-level app to verified Chronos HTTP ingress and
## an unauthenticated interaction-webhook REST client. Hybrid applications add
## an independent Gateway-event owner through a larger composite runtime; this
## focused factory rejects that shape instead of silently omitting it.

import chronos

import cordnim/app
import cordnim/rest
import ./[http_server, router, verification, webhook_completion]

type InteractionHttpRuntime*[S] = ref object ## Resources owned by one
                                               ## webhook-only app.
    appValue: DiscordApp[S]
    routerValue: CommandRouter[S]
    serverValue: InteractionHttpServer
    webhookTransport: DiscordHttpTransport
    webhookClient: ChronosRestClient

proc newInteractionHttpRuntime*[S](
    app: DiscordApp[S];
    bindAddress: TransportAddress;
    verification: VerificationConfig;
    endpointPath = "/interactions";
    discordApiBaseUrl = DiscordApiBaseUrl;
    maxResponseBodyBytes = 16 * 1_024 * 1_024;
): InteractionHttpRuntime[S] =
  ## Binds and attaches the complete webhook-only transport lifecycle.
  if app.isNil:
    raise newException(ValueError, "HTTP runtime requires an application")
  if app.config.appMode != webhookOnly:
    raise newException(ValueError,
      "webhook-only runtime requires HTTP ingress without Gateway events")
  if app.hasLifecycle or app.lifecycleState != alsReady:
    raise newException(AppLifecycleError,
      "application transport lifecycle is already configured or started")

  let httpTransport = newWebhookHttpTransport(
    discordApiBaseUrl, maxResponseBodyBytes)
  let restClient = newChronosRestClient(httpTransport.asRestTransport())

  let commandRouter = newCommandRouter(
    app,
    completionSink = interactionWebhookCompletion(restClient),
    postAckSink = interactionWebhookPostAckSink(restClient))
  let interactionServer = newInteractionHttpServer(
    bindAddress,
    verification,
    commandRouter.asHttpHandler(),
    endpointPath)

  result = InteractionHttpRuntime[S](
    appValue: app,
    routerValue: commandRouter,
    serverValue: interactionServer,
    webhookTransport: httpTransport,
    webhookClient: restClient)
  let runtime = result

  proc startRuntime(): Future[void] {.
      closure, gcsafe, raises: [].} =
    proc startOwned(): Future[void] {.async.} =
      runtime.webhookClient.start()
      runtime.serverValue.start()
    {.cast(gcsafe).}:
      return startOwned()

  proc waitRuntime(): Future[void] {.
      closure, gcsafe, raises: [].} =
    proc waitOwned(): Future[void] {.async.} =
      await runtime.serverValue.join()
    {.cast(gcsafe).}:
      return waitOwned()

  proc closeRuntime(): Future[void] {.
      closure, gcsafe, raises: [].} =
    proc closeOwned(): Future[void] {.async.} =
      await runtime.serverValue.close()
      await runtime.routerValue.close()
      await runtime.webhookClient.stop()
      await runtime.webhookTransport.close()
    {.cast(gcsafe).}:
      return closeOwned()

  app.configureLifecycle(initAppLifecycle(
    startRuntime, waitRuntime, closeRuntime))

func localAddress*[S](runtime: InteractionHttpRuntime[S]): TransportAddress =
  ## Returns the bound interaction-listener address.
  if runtime.isNil or runtime.serverValue.isNil:
    raise newException(ValueError, "HTTP runtime is not initialized")
  runtime.serverValue.localAddress()
