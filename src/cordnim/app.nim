## Typed Discord application composition and middleware dispatch.
##
## An application chooses exactly one interaction ingress. Optional Gateway
## event subscriptions are configured independently, so an HTTP interaction
## application may still consume voice or guild events without accepting the
## same interaction twice.

import chronos

import cordnim/commands

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
    enabled*: bool ## Whether the application opens an event session.
    intents*: set[GatewayIntent] ## Intents requested for subscribed events.

  AppMode* = enum ## Operational shape derived from ingress and event settings.
    webhookOnly, ## HTTP interactions without a Gateway event session.
    gatewayOnly, ## Gateway interaction ingress, with optional other events.
    hybrid ## HTTP interactions plus an independent Gateway event session.

  AppConfig* = object ## Application transport selection value.
    interactionIngress*: InteractionIngress ## Exclusive interaction source.
    gatewayEvents*: GatewaySubscriptions ## Independent Gateway event feed.

  MiddlewareDecisionKind* = enum ## Result of a middleware pre-dispatch hook.
    mdContinue, ## Continue to the next middleware or handler.
    mdStop ## Return the supplied result immediately.

  MiddlewareDecision* = object ## Typed middleware pre-dispatch decision.
    kind*: MiddlewareDecisionKind ## Continue or stop classification.
    result*: CommandResult ## Result used only when `kind` is `mdStop`.

  BeforeCommand*[S] = proc (
      services: S;
      invocation: var CommandInvocation
    ): MiddlewareDecision {.closure.} ## Pre-dispatch hook that may normalize
                                      ## input or stop execution.

  AfterCommand*[S] = proc (services: S; invocation: CommandInvocation;
      commandResult: var CommandResult) {.closure.} ## Post-dispatch hook that
      ## may annotate the transport-neutral result.

  CommandMiddleware*[S] = object ## Named pair of command middleware hooks.
    name*: string ## Diagnostic middleware name.
    before*: BeforeCommand[S] ## Optional pre-dispatch hook.
    after*: AfterCommand[S] ## Optional post-dispatch hook.

  DiscordApp*[S] = ref object ## Long-lived application runtime with typed
                              ## services.
    services*: S ## Application dependency container.
    config*: AppConfig ## Transport and event configuration.
    commands*: CommandSet[S] ## Explicit generated command registry.
    middleware: seq[CommandMiddleware[S]]

func gatewaySubscriptions*(intents: set[GatewayIntent] = {}):
    GatewaySubscriptions =
  ## Enables the independent Gateway event session with the requested intents.
  GatewaySubscriptions(enabled: true, intents: intents)

func noGatewayEvents*(): GatewaySubscriptions =
  ## Disables non-interaction Gateway event subscriptions.
  GatewaySubscriptions(enabled: false, intents: {})

func hasGatewayEvents*(subscriptions: GatewaySubscriptions): bool =
  ## Reports whether subscriptions request a session or any intent.
  subscriptions.enabled or subscriptions.intents != {}

func initAppConfig*(interactionIngress: InteractionIngress,
                    gatewayEvents = noGatewayEvents()): AppConfig =
  ## Creates an application configuration with one interaction ingress.
  AppConfig(
    interactionIngress: interactionIngress,
    gatewayEvents: gatewayEvents
  )

func appMode*(config: AppConfig): AppMode =
  ## Derives the operational mode without conflating events and interactions.
  case config.interactionIngress
  of ingressGateway:
    gatewayOnly
  of ingressHttp:
    if config.gatewayEvents.hasGatewayEvents: hybrid else: webhookOnly

func requiresGatewayConnection*(config: AppConfig): bool =
  ## Reports whether either interaction ingress or event subscriptions need
  ## Gateway.
  config.interactionIngress == ingressGateway or
    config.gatewayEvents.hasGatewayEvents

func continueDispatch*(): MiddlewareDecision =
  ## Creates a middleware decision that continues dispatch.
  MiddlewareDecision(kind: mdContinue)

func stopDispatch*(commandResult: CommandResult): MiddlewareDecision =
  ## Creates a middleware decision that skips the handler.
  MiddlewareDecision(kind: mdStop, result: commandResult)

proc newDiscordApp*[S](services: sink S, config: AppConfig,
                       commands: sink CommandSet[S]): DiscordApp[S] =
  ## Creates an application runtime with an explicit command registry.
  new result
  result.services = services
  result.config = config
  result.commands = commands

proc use*[S](app: DiscordApp[S], middleware: sink CommandMiddleware[S]) =
  ## Appends middleware in outer-to-inner execution order.
  if app.isNil:
    raise newException(ValueError, "cannot add middleware to a nil DiscordApp")
  app.middleware.add(middleware)

func middlewareCount*[S](app: DiscordApp[S]): int =
  ## Returns the number of registered middleware entries.
  if app.isNil: 0 else: app.middleware.len

proc dispatch*[S](app: DiscordApp[S],
                  invocation: sink CommandInvocation): Future[CommandResult] {.
                  async.} =
  ## Runs middleware and awaits one transport-neutral command invocation.
  if app.isNil:
    raise newException(ValueError, "cannot dispatch through a nil DiscordApp")

  var mutableInvocation = invocation
  var entered = 0
  var stopped = false
  for middleware in app.middleware:
    if middleware.before != nil:
      let decision = middleware.before(app.services, mutableInvocation)
      inc entered
      if decision.kind == mdStop:
        result = decision.result
        stopped = true
        break
    else:
      inc entered

  if not stopped:
    result = await app.commands.dispatch(app.services, mutableInvocation)

  # Unwind only middleware whose pre-hook was entered. Reverse order mirrors
  # resource-scoped middleware while keeping control flow explicit.
  if entered > 0:
    for index in countdown(entered - 1, 0):
      let after = app.middleware[index].after
      if after != nil:
        after(app.services, mutableInvocation, result)

type
  AppRunBody*[S] = proc (app: DiscordApp[S]): Future[void]
    {.closure.} ## Chronos application body executed inside the caller-owned
                ## runtime.

proc run*[S](app: DiscordApp[S], body: AppRunBody[S]): Future[void] {.async.} =
  ## Executes an application body on Chronos without hiding its await boundary.
  await body(app)
