## Owned HTTP interaction runtime for webhook-only and hybrid applications.
##
## This factory wires the high-level app to verified Chronos HTTP ingress and
## an unauthenticated interaction-webhook REST client through one
## `InteractionDispatcher`. A hybrid application attaches this component and an
## independent Gateway event runtime to the same `DiscordApp`; the app starts
## and closes both components as one owner.

import std/options

import chronos

import cordnim/app
import cordnim/components/routes
import cordnim/rest
import ./[http_server, verification]
import ./dispatcher {.all.}
import ./webhook_completion {.all.}

type InteractionHttpRuntime*[S] = ref object ## Resources owned by one HTTP
                                               ## interaction component.
    appValue: DiscordApp[S]
    dispatcherValue: InteractionDispatcher[S]
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
    routeEnvelope = none(RouteCodec);
    handlerFailureObserver: RetainedFailureObserver = nil;
    commandFailureObserver: DeferredFailureObserver = nil;
    routeClock: InteractionWallClock = systemInteractionUnixSeconds;
): InteractionHttpRuntime[S] =
  ## Binds and attaches the complete HTTP interaction transport lifecycle.
  ##
  ## Supplying `routeEnvelope` enables persistent component and modal routing;
  ## register component, modal, and autocomplete handlers on `runtime.dispatcher`
  ## before starting the app. The same REST client carries auto-defer
  ## completions, original-response edits, and follow-ups for every interaction
  ## class.
  if app.isNil:
    raise newException(ValueError, "HTTP runtime requires an application")
  if app.config.interactionIngress != ingressHttp:
    raise newException(ValueError,
      "HTTP interaction runtime requires HTTP interaction ingress")
  if app.lifecycleState != alsReady:
    raise newException(AppLifecycleError,
      "application runtime components can only be attached while ready")

  let httpTransport = newWebhookHttpTransport(
    discordApiBaseUrl, maxResponseBodyBytes)
  let restClient = newChronosRestClient(httpTransport.asRestTransport())

  let interactionDispatcher = newInteractionDispatcherWithSenderFactory(
    app,
    senderFactory = interactionWebhookSenderFactory(restClient),
    commandFailureObserver = commandFailureObserver,
    handlerFailureObserver = handlerFailureObserver,
    routeEnvelope = routeEnvelope,
    routeClock = routeClock)
  let interactionServer = newInteractionHttpServer(
    bindAddress,
    verification,
    interactionDispatcher.asHttpHandler(),
    endpointPath)

  result = InteractionHttpRuntime[S](
    appValue: app,
    dispatcherValue: interactionDispatcher,
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
      await runtime.dispatcherValue.close()
      await runtime.webhookClient.stop()
      await runtime.webhookTransport.close()
    {.cast(gcsafe).}:
      return closeOwned()

  app.configureLifecycle(initAppLifecycle(
    startRuntime, waitRuntime, closeRuntime))

func dispatcher*[S](runtime: InteractionHttpRuntime[S]):
    InteractionDispatcher[S] =
  ## Returns the owned dispatcher so component, modal, and autocomplete handlers
  ## can be registered before the application starts.
  if runtime.isNil or runtime.dispatcherValue.isNil:
    raise newException(ValueError, "HTTP runtime is not initialized")
  runtime.dispatcherValue

func localAddress*[S](runtime: InteractionHttpRuntime[S]): TransportAddress =
  ## Returns the bound interaction-listener address.
  if runtime.isNil or runtime.serverValue.isNil:
    raise newException(ValueError, "HTTP runtime is not initialized")
  runtime.serverValue.localAddress()
