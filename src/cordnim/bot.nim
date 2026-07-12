## High-level composition for a complete Discord Gateway bot.
##
## `newGatewayBotRuntime` owns the authenticated REST scheduler and connection
## pool, `/gateway/bot` bootstrap, shard fleet, interaction dispatcher, and typed
## event router as one `DiscordApp` lifecycle component. Applications register
## handlers on the returned runtime, then call `app.run()`.
##
## Single-process coordination is an explicit constructor argument. A deployment
## with more than one process must supply a distributed `GatewayCoordination`;
## Cordnim never silently promotes the in-memory adapter across hosts.

import std/options

import chronos

import cordnim/[app, build_info, events]
import cordnim/api/gateway_bootstrap
import cordnim/app/[gateway_config, gateway_interactions]
import cordnim/components/routes
import cordnim/core/secrets
import cordnim/gateway/[chronos_runtime, coordination, dispatch,
  dispatch_runtime, payloads, runtime, session, shard_runner, sharding,
  url, websocket_chronos]
import cordnim/interactions/dispatcher
import cordnim/rest/[chronos_driver, http_transport]

type
  GatewayBotCoordinationKind = enum
    gbckUnset,
    gbckSingleProcess,
    gbckExternal

  GatewayBotCoordination* = object ## Deliberate shard-coordination selection.
    case kind: GatewayBotCoordinationKind
    of gbckSingleProcess:
      leaseTtlMs: int64
    of gbckExternal:
      externalValue: GatewayCoordination
    of gbckUnset:
      discard

  GatewayBotOptions* = object ## Sharding, queues, and connection tuning.
    processIndex*: uint16 ## Zero-based index of this process.
    processCount*: uint16 ## Number of cooperating processes.
    shardCount*: Option[uint16] ## Override; `none` uses Discord's recommendation.
    eventPolicy*: EventPolicy ## Bounded non-interaction event concurrency.
    runnerTuning*: GatewayRunnerTuning ## Compression and runner timing.
    restartPolicy*: GatewayRestartPolicy ## Finite per-shard restart budget.
    identifyProperties*: GatewayIdentifyProperties ## Discord client metadata.
    gatewayBotInfo*: Option[GatewayBotInfo] ## Injected bootstrap for tests.
    clock*: GatewayClock ## Monotonic runner and local coordination clock.
    sleeper*: GatewaySleeper ## Cancellation-transparent runner delay.
    jitter*: GatewayJitter ## Bounded reconnect and heartbeat jitter.
    transportFactory*: GatewayTransportFactory ## Fresh WebSocket drivers.
    interactionMaxConcurrent*: int ## Independent interaction ACK workers.
    maxGatewayMessageBytes*: int ## Aggregate WebSocket message bound.
    discordApiBaseUrl*: string ## REST origin, overridable for local integration.
    maxRestResponseBytes*: int ## Maximum REST response body size.

  GatewayBotRuntime*[S] = ref object ## Complete app-owned Gateway composition.
    appValue: DiscordApp[S]
    tokenValue: Secret[BotToken]
    coordinationChoice: GatewayBotCoordination
    optionsValue: GatewayBotOptions
    eventRouterValue: GatewayEventRouter[S]
    interactionDispatcherValue: InteractionDispatcher[S]
    httpTransport: DiscordHttpTransport
    restClientValue: ChronosRestClient
    gatewayRuntimeValue: GatewayRuntime
    dispatchObserver: DispatchErrorObserver
    shardObserver: GatewayShardErrorObserver
    runtimeObserver: GatewayRuntimeObserver

const
  DefaultGatewayBotLeaseTtlMs* = 90_000'i64
    ## Local shard lease lifetime; renewal occurs well before expiry.
  DefaultGatewayBotQueueCapacity* = 64
    ## Maximum queued events in each default partition lane.
  DefaultGatewayBotPartitions* = 4
    ## Default number of per-shard ordered event partitions.

func `$`*[S](runtime: GatewayBotRuntime[S]): string =
  ## Renders lifecycle metadata without traversing credentials or transports.
  if runtime.isNil:
    "GatewayBotRuntime(nil)"
  else:
    "GatewayBotRuntime(state: " & $runtime.appValue.lifecycleState & ")"

func repr*[S](runtime: GatewayBotRuntime[S]): string =
  ## Uses the credential-free runtime representation.
  $runtime

func singleProcessGateway*(
    leaseTtlMs = DefaultGatewayBotLeaseTtlMs,
): GatewayBotCoordination =
  ## Selects in-memory coordination for exactly one application process.
  if leaseTtlMs <= 0:
    raise newException(ValueError, "Gateway lease TTL must be positive")
  GatewayBotCoordination(kind: gbckSingleProcess, leaseTtlMs: leaseTtlMs)

func externalGateway*(
    coordination: GatewayCoordination,
): GatewayBotCoordination =
  ## Selects a caller-owned distributed coordination adapter.
  if coordination.isNil:
    raise newException(ValueError,
      "external Gateway coordination must not be nil")
  GatewayBotCoordination(kind: gbckExternal, externalValue: coordination)

func initGatewayBotOptions*(
    processIndex = 0'u16;
    processCount = 1'u16;
    shardCount = none(uint16);
    eventPolicy = partitionedPolicy(
      DefaultGatewayBotQueueCapacity,
      DefaultGatewayBotPartitions);
    runnerTuning = defaultGatewayRunnerTuning();
    restartPolicy = GatewayRestartPolicy();
    identifyProperties = initGatewayIdentifyProperties(
      hostOS, CordnimServerIdent, CordnimServerIdent);
    gatewayBotInfo = none(GatewayBotInfo);
    clock: GatewayClock = chronosGatewayClock;
    sleeper: GatewaySleeper = chronosGatewaySleep;
    jitter: GatewayJitter = secureGatewayJitter;
    transportFactory: GatewayTransportFactory = nil;
    interactionMaxConcurrent = 4;
    maxGatewayMessageBytes = defaultGatewayMessageBytes;
    discordApiBaseUrl = DiscordApiBaseUrl;
    maxRestResponseBytes = 16 * 1_024 * 1_024,
): GatewayBotOptions =
  ## Creates production defaults with bounded per-guild event ordering.
  let selectedTransportFactory = if transportFactory.isNil:
      chronosGatewayTransportFactory(maxGatewayMessageBytes)
    else:
      transportFactory
  GatewayBotOptions(
    processIndex: processIndex,
    processCount: processCount,
    shardCount: shardCount,
    eventPolicy: eventPolicy,
    runnerTuning: runnerTuning,
    restartPolicy: restartPolicy,
    identifyProperties: identifyProperties,
    gatewayBotInfo: gatewayBotInfo,
    clock: clock,
    sleeper: sleeper,
    jitter: jitter,
    transportFactory: selectedTransportFactory,
    interactionMaxConcurrent: interactionMaxConcurrent,
    maxGatewayMessageBytes: maxGatewayMessageBytes,
    discordApiBaseUrl: discordApiBaseUrl,
    maxRestResponseBytes: maxRestResponseBytes,
  )

func events*[S](runtime: GatewayBotRuntime[S]): GatewayEventRouter[S] =
  ## Returns the typed event registry; register handlers before `app.run()`.
  if runtime.isNil or runtime.eventRouterValue.isNil:
    raise newException(ValueError, "Gateway bot runtime is not initialized")
  runtime.eventRouterValue

func interactions*[S](runtime: GatewayBotRuntime[S]):
    InteractionDispatcher[S] =
  ## Returns the Gateway interaction registry for commands, components, modals,
  ## and autocomplete.
  ##
  ## Hybrid applications configured with HTTP interaction ingress use the
  ## dispatcher owned by `InteractionHttpRuntime` instead.
  if runtime.isNil:
    raise newException(ValueError, "Gateway bot runtime is not initialized")
  if runtime.interactionDispatcherValue.isNil:
    raise newException(ValueError,
      "Gateway bot interactions require Gateway interaction ingress")
  runtime.interactionDispatcherValue

func rest*[S](runtime: GatewayBotRuntime[S]): ChronosRestClient =
  ## Returns the owned semantic REST client.
  ##
  ## It is running during application handlers and stops when the app closes.
  if runtime.isNil or runtime.restClientValue.isNil:
    raise newException(ValueError, "Gateway bot runtime is not initialized")
  runtime.restClientValue

proc validate(options: GatewayBotOptions;
              coordination: GatewayBotCoordination) =
  if options.processCount == 0 or options.processIndex >= options.processCount:
    raise newException(ValueError,
      "Gateway process index must belong to a positive process count")
  if options.shardCount.isSome and options.shardCount.get() == 0:
    raise newException(ValueError, "Gateway shard count must be positive")
  if options.eventPolicy.laneQueueCapacity <= 0 or
      options.eventPolicy.maxConcurrent <= 0:
    raise newException(ValueError, "Gateway event policy must be initialized")
  if options.interactionMaxConcurrent <= 0:
    raise newException(ValueError,
      "Gateway interaction concurrency must be positive")
  if options.maxGatewayMessageBytes <= 0 or options.maxRestResponseBytes <= 0:
    raise newException(ValueError, "Gateway transport bounds must be positive")
  if options.clock.isNil or options.sleeper.isNil or options.jitter.isNil or
      options.transportFactory.isNil:
    raise newException(ValueError,
      "Gateway runtime dependencies must not be nil")
  case coordination.kind
  of gbckUnset:
    raise newException(ValueError,
      "choose singleProcessGateway() or externalGateway()")
  of gbckSingleProcess:
    if options.processCount != 1:
      raise newException(ValueError,
        "single-process Gateway coordination requires processCount = 1")
  of gbckExternal:
    if coordination.externalValue.isNil:
      raise newException(ValueError,
        "external Gateway coordination must not be nil")

proc newGatewayBotRuntime*[S](
    app: DiscordApp[S];
    token: Secret[BotToken];
    coordination: GatewayBotCoordination;
    options = initGatewayBotOptions();
    routeEnvelope = none(RouteCodec);
    commandFailureObserver: DeferredFailureObserver = nil;
    interactionFailureObserver: RetainedFailureObserver = nil;
    dispatchErrorObserver: DispatchErrorObserver = nil;
    shardErrorObserver: GatewayShardErrorObserver = nil;
    gatewayRuntimeObserver: GatewayRuntimeObserver = nil;
    routeClock: InteractionWallClock = systemInteractionUnixSeconds,
): GatewayBotRuntime[S] =
  ## Creates and attaches a complete production Gateway runtime.
  ##
  ## Construction performs validation but no network I/O. `app.start()` starts
  ## REST, fetches `/gateway/bot`, constructs the planned shard fleet, and starts
  ## it. `app.close()` tears the fleet down before the dispatcher, REST scheduler,
  ## and HTTP connection pool. The app remains the sole lifecycle owner.
  if app.isNil:
    raise newException(ValueError,
      "Gateway bot runtime requires an application")
  if not app.config.requiresGatewayConnection():
    raise newException(ValueError,
      "Gateway bot runtime requires Gateway ingress or event subscriptions")
  if app.lifecycleState != alsReady:
    raise newException(AppLifecycleError,
      "application runtime components can only be attached while ready")
  options.validate(coordination)

  let transport = newDiscordHttpTransport(
    token, options.discordApiBaseUrl, options.maxRestResponseBytes)
  let client = newChronosRestClient(transport.asRestTransport())
  let eventRouter = newGatewayEventRouter(app)
  let interactionDispatcher =
    if app.config.interactionIngress == ingressGateway:
      newInteractionDispatcher(
        app,
        commandFailureObserver,
        interactionFailureObserver,
        routeEnvelope,
        routeClock)
    else:
      InteractionDispatcher[S](nil)

  result = GatewayBotRuntime[S](
    appValue: app,
    tokenValue: token,
    coordinationChoice: coordination,
    optionsValue: options,
    eventRouterValue: eventRouter,
    interactionDispatcherValue: interactionDispatcher,
    httpTransport: transport,
    restClientValue: client,
    dispatchObserver: dispatchErrorObserver,
    shardObserver: shardErrorObserver,
    runtimeObserver: gatewayRuntimeObserver,
  )
  let bot = result

  proc startRuntime(): Future[void] {.closure, gcsafe, raises: [].} =
    proc startOwned(): Future[void] {.async.} =
      bot.restClientValue.start()
      let bootstrap = if bot.optionsValue.gatewayBotInfo.isSome:
          bot.optionsValue.gatewayBotInfo.get()
        else:
          await bot.restClientValue.getGatewayBot()
      let totalShards = if bot.optionsValue.shardCount.isSome:
          bot.optionsValue.shardCount.get()
        else:
          bootstrap.recommendedShards
      let plan = planShards(
        totalShards,
        bot.optionsValue.processIndex,
        bot.optionsValue.processCount)
      let clock = bot.optionsValue.clock
      let coordinationValue = case bot.coordinationChoice.kind
        of gbckSingleProcess:
          newLocalGatewayCoordination(
            bot.optionsValue.clock,
            bot.coordinationChoice.leaseTtlMs,
            bootstrap.sessionStartLimit).asCoordination()
        of gbckExternal:
          bot.coordinationChoice.externalValue
        of gbckUnset:
          raise newException(ValueError,
            "Gateway coordination is not initialized")
      let transportFactory = bot.optionsValue.transportFactory
      let interactionSink = if bot.interactionDispatcherValue.isNil:
          GatewayInteractionSink(nil)
        else:
          gatewayInteractionSink(
            bot.interactionDispatcherValue, bot.restClientValue)
      let eventHandler = bot.eventRouterValue.asGatewayHandler()

      let runnerFactory: GatewayRunnerFactory = proc(
          shardId: ShardId
      ): GatewayShardRunner {.
          closure, gcsafe, raises: [ValueError, GatewayUrlError].} =
        let dispatch = newGatewayDispatchRuntime(
          bot.optionsValue.eventPolicy,
          eventHandler,
          bot.dispatchObserver)
        let runnerConfig = gatewayShardConfig(
          bot.appValue.config,
          bootstrap,
          plan,
          shardId,
          bot.tokenValue,
          bot.optionsValue.identifyProperties,
          bot.optionsValue.runnerTuning)
        newGatewayShardRunner(
          runnerConfig,
          coordinationValue,
          dispatch,
          transportFactory,
          clock,
          bot.optionsValue.sleeper,
          bot.optionsValue.jitter,
          bot.shardObserver,
          interactionSink,
          bot.optionsValue.interactionMaxConcurrent)

      bot.gatewayRuntimeValue = newGatewayRuntime(
        plan,
        runnerFactory,
        bot.optionsValue.restartPolicy,
        bot.runtimeObserver)
      bot.gatewayRuntimeValue.start()
    {.cast(gcsafe).}:
      return startOwned()

  proc waitRuntime(): Future[void] {.closure, gcsafe, raises: [].} =
    proc waitOwned(): Future[void] {.async.} =
      if not bot.gatewayRuntimeValue.isNil:
        await bot.gatewayRuntimeValue.join()
    {.cast(gcsafe).}:
      return waitOwned()

  proc closeRuntime(): Future[void] {.closure, gcsafe, raises: [].} =
    proc closeOwned(): Future[void] {.async.} =
      if not bot.gatewayRuntimeValue.isNil:
        await bot.gatewayRuntimeValue.close()
      if not bot.interactionDispatcherValue.isNil:
        await bot.interactionDispatcherValue.close()
      await bot.restClientValue.stop()
      await bot.httpTransport.close()
    {.cast(gcsafe).}:
      return closeOwned()

  app.configureLifecycle(initAppLifecycle(
    startRuntime, waitRuntime, closeRuntime))
