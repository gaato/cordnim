## Typed Discord application composition and middleware dispatch.
##
## An application chooses exactly one interaction ingress. Optional Gateway
## event subscriptions are configured independently, so an HTTP interaction
## application may still consume voice or guild events without accepting the
## same interaction twice.

import chronos

import cordnim/commands
import cordnim/commands/spec as commandspec
import cordnim/app/context as appcontext

type
  InteractionIngress* = enum ## Exclusive source of Discord interactions.
    ingressHttp, ## Verify and receive interactions over HTTP webhooks.
    ingressGateway ## Receive interactions from the Gateway connection.

  GatewayIntent* = enum ## Gateway intent groups available to event
                        ## subscriptions.
    giGuilds, ## Guild lifecycle and channel events.
    giGuildMembers, ## Guild member events; privileged when applicable.
    giGuildModeration, ## Bans and moderation-related guild events.
    giGuildExpressions, ## Emoji, sticker, and soundboard expression events.
    giGuildIntegrations, ## Guild integration events.
    giGuildWebhooks, ## Webhook update events.
    giGuildInvites, ## Invite lifecycle events.
    giGuildVoiceStates, ## Voice-state events required for voice connections.
    giGuildPresences, ## Presence events; privileged when applicable.
    giGuildMessages, ## Messages created in guild channels.
    giGuildMessageReactions, ## Reactions in guild channels.
    giGuildMessageTyping, ## Typing events in guild channels.
    giDirectMessages, ## Messages created in direct messages.
    giDirectMessageReactions, ## Reactions in direct messages.
    giDirectMessageTyping, ## Typing events in direct messages.
    giMessageContent, ## Message content fields; privileged when applicable.
    giGuildScheduledEvents, ## Scheduled-event lifecycle events.
    giAutoModerationConfig, ## Auto Moderation rule configuration events.
    giAutoModerationExecution, ## Auto Moderation action execution events.
    giGuildMessagePolls, ## Poll vote events in guild channels.
    giDirectMessagePolls ## Poll vote events in direct messages.

  GatewaySubscriptions* = object ## Optional non-interaction Gateway event feed.
    gatewayEnabled: bool
    gatewayIntents: set[GatewayIntent]

  AppMode* = enum ## Operational shape derived from ingress and event settings.
    webhookOnly, ## HTTP interactions without a Gateway event session.
    gatewayOnly, ## Gateway interaction ingress, with optional other events.
    hybrid ## HTTP interactions plus an independent Gateway event session.

  AppConfig* = object ## Immutable application transport selection value.
    ingressValue: InteractionIngress
    gatewaySubscriptionsValue: GatewaySubscriptions

  AppLifecycleStart* = proc (): Future[void]
    {.closure, gcsafe, raises: [CatchableError].}
    ## Starts every transport owned by an application runtime.

  AppLifecycleWait* = proc (): Future[void]
    {.closure, gcsafe, raises: [CatchableError].}
    ## Waits until an owned transport stops or fails.

  AppLifecycleClose* = proc (): Future[void]
    {.closure, gcsafe, raises: [CatchableError].}
    ## Stops and joins every transport owned by an application runtime.

  AppLifecycle* = object ## Complete transport lifecycle bound to an app.
    startHook: AppLifecycleStart
    waitHook: AppLifecycleWait
    closeHook: AppLifecycleClose

  AppLifecycleState* = enum ## Observable high-level runtime state.
    alsReady, ## Constructed but not started.
    alsStarting, ## Running the configured start operation.
    alsRunning, ## Transports started and the app may dispatch events.
    alsClosing, ## Stopping and joining owned transports.
    alsClosed ## Lifecycle resources have been released.

  AppLifecycleError* = object of CatchableError
    ## Invalid or unavailable application lifecycle operation.

  MiddlewareDecisionKind* = enum ## Result of a middleware pre-dispatch hook.
    mdContinue, ## Continue to the next middleware or handler.
    mdStop ## Return the supplied result immediately.

  MiddlewareDecision* = object ## Typed middleware pre-dispatch decision.
    kind*: MiddlewareDecisionKind ## Continue or stop classification.
    result*: CommandResult ## Result used only when `kind` is `mdStop`.

  BeforeCommand*[S] = proc (
      services: ref S;
      invocation: var CommandInvocation
    ): MiddlewareDecision {.closure.} ## Pre-dispatch hook that may normalize
                                      ## input or stop execution. `services`
                                      ## points at the app-owned allocation.

  AfterCommand*[S] = proc (services: ref S; invocation: CommandInvocation;
      commandResult: var CommandResult) {.closure.} ## Post-dispatch hook that
      ## may annotate the transport-neutral result using the same service
      ## allocation seen by the handler.

  CommandMiddleware*[S] = object ## Named pair of command middleware hooks.
    name*: string ## Diagnostic middleware name.
    before*: BeforeCommand[S] ## Optional pre-dispatch hook.
    after*: AfterCommand[S] ## Optional post-dispatch hook.

  DiscordApp*[S] = ref object ## Long-lived application runtime with typed
                              ## services.
    serviceValue: ref S
    configValue: AppConfig
    commandSetValue: CommandSet[S]
    middleware: seq[CommandMiddleware[S]]
    lifecycleValue: AppLifecycle
    lifecycleConfigured: bool
    stateValue: AppLifecycleState
    startTask: Future[void]
    waitTask: Future[void]
    closeTask: Future[void]

func gatewaySubscriptions*(intents: set[GatewayIntent] = {}):
    GatewaySubscriptions =
  ## Enables the independent Gateway event session with the requested intents.
  GatewaySubscriptions(gatewayEnabled: true, gatewayIntents: intents)

func noGatewayEvents*(): GatewaySubscriptions =
  ## Disables non-interaction Gateway event subscriptions.
  GatewaySubscriptions(gatewayEnabled: false, gatewayIntents: {})

func enabled*(subscriptions: GatewaySubscriptions): bool =
  ## Reports whether the independent Gateway event session is enabled.
  subscriptions.gatewayEnabled

func intents*(subscriptions: GatewaySubscriptions): set[GatewayIntent] =
  ## Returns the intents requested for the independent Gateway event session.
  subscriptions.gatewayIntents

func hasGatewayEvents*(subscriptions: GatewaySubscriptions): bool =
  ## Reports whether subscriptions enable an independent Gateway session.
  subscriptions.gatewayEnabled

func initAppConfig*(interactionIngress: InteractionIngress,
                    gatewayEvents = noGatewayEvents()): AppConfig =
  ## Creates an application configuration with one interaction ingress.
  AppConfig(
    ingressValue: interactionIngress,
    gatewaySubscriptionsValue: gatewayEvents
  )

func interactionIngress*(config: AppConfig): InteractionIngress =
  ## Returns the one configured source of interaction dispatches.
  config.ingressValue

func gatewayEvents*(config: AppConfig): GatewaySubscriptions =
  ## Returns independent non-interaction Gateway event subscriptions.
  config.gatewaySubscriptionsValue

func appMode*(config: AppConfig): AppMode =
  ## Derives the operational mode without conflating events and interactions.
  case config.ingressValue
  of ingressGateway:
    gatewayOnly
  of ingressHttp:
    if config.gatewaySubscriptionsValue.hasGatewayEvents:
      hybrid
    else:
      webhookOnly

func requiresGatewayConnection*(config: AppConfig): bool =
  ## Reports whether either interaction ingress or event subscriptions need
  ## Gateway.
  config.ingressValue == ingressGateway or
    config.gatewaySubscriptionsValue.hasGatewayEvents

proc initAppLifecycle*(start: AppLifecycleStart, wait: AppLifecycleWait,
                       close: AppLifecycleClose): AppLifecycle =
  ## Binds the complete lifecycle of caller-constructed HTTP or Gateway I/O.
  ##
  ## The callbacks normally close over an interaction server, command router,
  ## Gateway connection, or a composite that owns all three. `run` calls them
  ## in start/wait/close order and guarantees `close` after a successful start.
  ##
  ## `close` must be idempotent. A failed or cancelled close attempt leaves the
  ## application in `alsClosing`, and a later `close` call invokes the hook
  ## again so partially released resources can finish cleanup.
  if start.isNil:
    raise newException(ValueError, "application start operation is required")
  if wait.isNil:
    raise newException(ValueError, "application wait operation is required")
  if close.isNil:
    raise newException(ValueError, "application close operation is required")
  AppLifecycle(startHook: start, waitHook: wait, closeHook: close)

func lifecycleComplete(lifecycle: AppLifecycle): bool =
  not lifecycle.startHook.isNil and not lifecycle.waitHook.isNil and
    not lifecycle.closeHook.isNil

func continueDispatch*(): MiddlewareDecision =
  ## Creates a middleware decision that continues dispatch.
  MiddlewareDecision(kind: mdContinue)

func stopDispatch*(commandResult: CommandResult): MiddlewareDecision =
  ## Creates a middleware decision that skips the handler.
  MiddlewareDecision(kind: mdStop, result: commandResult)

proc newDiscordApp*[S](services: sink S, config: AppConfig,
                       commands: sink CommandSet[S],
                       lifecycle = AppLifecycle()): DiscordApp[S] =
  ## Creates an application runtime with an explicit command registry.
  new result
  new result.serviceValue
  result.serviceValue[] = services
  result.configValue = config
  result.commandSetValue = commands
  result.lifecycleValue = lifecycle
  result.lifecycleConfigured = lifecycle.lifecycleComplete
  result.stateValue = alsReady

func services*[S](app: DiscordApp[S]): lent S =
  ## Borrows the application dependency container.
  app.serviceValue[]

func config*[S](app: DiscordApp[S]): AppConfig =
  ## Returns the application's immutable transport configuration.
  app.configValue

func commands*[S](app: DiscordApp[S]): lent CommandSet[S] =
  ## Borrows the immutable generated command registry.
  app.commandSetValue

func hasLifecycle*[S](app: DiscordApp[S]): bool =
  ## Reports whether transport lifecycle operations were supplied.
  not app.isNil and app.lifecycleConfigured

func lifecycleState*[S](app: DiscordApp[S]): AppLifecycleState =
  ## Returns the current high-level application lifecycle state.
  if app.isNil: alsClosed else: app.stateValue

proc configureLifecycle*[S](app: DiscordApp[S], lifecycle: AppLifecycle) =
  ## Attaches caller-constructed transports once before application startup.
  ##
  ## Runtime factories use this after their callbacks can safely capture the
  ## constructed app. Lifecycle replacement after configuration or startup is
  ## rejected so transport ownership cannot change underneath dispatch.
  if app.isNil:
    raise newException(AppLifecycleError,
      "cannot configure a nil DiscordApp")
  if not lifecycle.lifecycleComplete:
    raise newException(ValueError,
      "application lifecycle requires start, wait, and close operations")
  if app.stateValue != alsReady:
    raise newException(AppLifecycleError,
      "application lifecycle can only be configured while ready")
  if app.lifecycleConfigured:
    raise newException(AppLifecycleError,
      "application transport lifecycle is already configured")
  app.lifecycleValue = lifecycle
  app.lifecycleConfigured = true

proc use*[S](app: DiscordApp[S], middleware: sink CommandMiddleware[S]) =
  ## Appends middleware in outer-to-inner execution order.
  if app.isNil:
    raise newException(ValueError, "cannot add middleware to a nil DiscordApp")
  app.middleware.add(middleware)

func middlewareCount*[S](app: DiscordApp[S]): int =
  ## Returns the number of registered middleware entries.
  if app.isNil: 0 else: app.middleware.len

proc dispatchCore[S](app: DiscordApp[S],
                     responseContext: appcontext.Context,
                     invocation: sink CommandInvocation):
                     Future[CommandResult] {.async.} =
  if app.isNil:
    raise newException(ValueError, "cannot dispatch through a nil DiscordApp")

  var mutableInvocation = invocation
  var entered = 0
  var stopped = false
  for middleware in app.middleware:
    if middleware.before != nil:
      let decision = middleware.before(app.serviceValue, mutableInvocation)
      inc entered
      if decision.kind == mdStop:
        result = decision.result
        stopped = true
        break
    else:
      inc entered

  if not stopped:
    result = await commandspec.dispatchWithServices(app.commandSetValue,
      app.serviceValue, responseContext, mutableInvocation)

  # Unwind only middleware whose pre-hook was entered. Reverse order mirrors
  # resource-scoped middleware while keeping control flow explicit.
  if entered > 0:
    for index in countdown(entered - 1, 0):
      let after = app.middleware[index].after
      if after != nil:
        after(app.serviceValue, mutableInvocation, result)

proc dispatch*[S](app: DiscordApp[S],
                  context: appcontext.Context,
                  invocation: sink CommandInvocation): Future[CommandResult] {.
                  async.} =
  ## Runs middleware and a command with ingress-owned response authority.
  ##
  ## The app's stored services are authoritative; response context never
  ## carries a dependency-container copy. If the handler selects an initial
  ## response, ingress ignores its returned `CommandResult`.
  if context.isNil:
    raise newException(ValueError, "command response context is required")
  return await app.dispatchCore(context, invocation)

proc dispatch*[S](app: DiscordApp[S],
                  invocation: sink CommandInvocation): Future[CommandResult] {.
                  async.} =
  ## Runs a result-only command without response transport.
  ##
  ## This compatibility overload supports tests and handlers that return a
  ## `CommandResult`. Response operations fail explicitly.
  return await app.dispatchCore(nil, invocation)

proc completedLifecycleOperation(): Future[void] {.raises: [].} =
  result = newFuture[void]("cordnim.app.complete")
  result.complete()

proc failedLifecycleOperation(message: string): Future[void] {.raises: [].} =
  result = newFuture[void]("cordnim.app.failure")
  result.fail(newException(AppLifecycleError, message))

proc closeConfigured[S](app: DiscordApp[S], joinStart: bool): Future[void] {.
                        async.} =
  if joinStart and not app.startTask.isNil and not app.startTask.finished:
    await cancelAndWait(app.startTask)
  if not app.waitTask.isNil and not app.waitTask.finished:
    await cancelAndWait(app.waitTask)
  await app.lifecycleValue.closeHook()
  app.stateValue = alsClosed

proc beginClose[S](app: DiscordApp[S], joinStart: bool): Future[void] =
  if not app.closeTask.isNil and not app.closeTask.finished:
    return app.closeTask
  app.stateValue = alsClosing
  app.closeTask = app.closeConfigured(joinStart)
  app.closeTask

proc startConfigured[S](app: DiscordApp[S]): Future[void] {.async.} =
  try:
    await app.lifecycleValue.startHook()
  except CatchableError as startError:
    # `close` owns cleanup when it requested this cancellation. Waiting for
    # that task here would deadlock because it first joins this start task.
    if app.stateValue == alsClosing and not app.closeTask.isNil:
      raise startError

    let cleanup = app.beginClose(joinStart = false)
    try:
      await noCancel(cleanup)
    except CatchableError:
      # Startup remains the primary error. Failed cleanup stays retryable via
      # the public close operation and leaves the state at `alsClosing`.
      discard
    raise startError

  if app.stateValue != alsStarting:
    raise newException(AppLifecycleError,
      "application startup was interrupted by close")
  app.stateValue = alsRunning

proc start*[S](app: DiscordApp[S]): Future[void] {.raises: [].} =
  ## Starts the configured application transports exactly once.
  ##
  ## Concurrent callers share the application-owned startup task and observe
  ## the same result.
  if app.isNil:
    return failedLifecycleOperation("cannot start a nil DiscordApp")
  if not app.lifecycleConfigured:
    return failedLifecycleOperation(
      "application transport lifecycle is not configured")
  case app.stateValue
  of alsReady:
    app.stateValue = alsStarting
    app.startTask = app.startConfigured()
    app.startTask
  of alsStarting:
    app.startTask
  of alsRunning:
    app.startTask
  of alsClosing, alsClosed:
    failedLifecycleOperation(
      "a closing or closed application cannot be started")

proc waitConfigured[S](app: DiscordApp[S]): Future[void] {.async.} =
  await app.lifecycleValue.waitHook()

proc waitOnce[S](app: DiscordApp[S]): Future[void] =
  if app.waitTask.isNil:
    app.waitTask = app.waitConfigured()
  app.waitTask

proc close*[S](app: DiscordApp[S]): Future[void] =
  ## Stops and joins configured transports.
  ##
  ## Concurrent callers share one close attempt. A failed or cancelled attempt
  ## remains `alsClosing`; calling `close` again retries the idempotent close
  ## hook instead of reporting a false `alsClosed` state.
  if app.isNil or app.stateValue == alsClosed:
    return completedLifecycleOperation()
  if not app.closeTask.isNil and not app.closeTask.finished:
    return app.closeTask
  if not app.lifecycleConfigured:
    app.stateValue = alsClosed
    return completedLifecycleOperation()

  app.beginClose(joinStart = true)

proc run*[S](app: DiscordApp[S]): Future[void] {.async.} =
  ## Starts transports, waits once for termination, and always closes resources.
  ##
  ## Concurrent calls share the application-owned start, wait, and close tasks.
  await app.start()
  try:
    await app.waitOnce()
  finally:
    await noCancel(app.close())
