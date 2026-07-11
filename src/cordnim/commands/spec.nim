## Public command metadata, invocation values, and asynchronous dispatch
## contracts.
##
## Command metadata is plain data so the compiler-generated manifest can be
## inspected, serialized, and tested without starting a Discord connection.

import std/[json, options]
import chronos

import cordnim/app/context as appcontext
import cordnim/core/[bits, ids, permissions]
import cordnim/interactions/context
import cordnim/interactions/responder

export Visibility, InteractionResponseState

type
  CommandKind* = enum ## Discord application command kinds.
    ckChatInput, ## A slash command with typed options.
    ckUser, ## A command shown in a user's context menu.
    ckMessage ## A command shown in a message's context menu.

  CommandOptionKind* = enum ## Discord application command option kinds.
    cokString, ## A UTF-8 string option.
    cokInteger, ## An integer option.
    cokBoolean, ## A boolean option.
    cokUser, ## A user snowflake or resolved user.
    cokChannel, ## A channel snowflake or resolved channel.
    cokRole, ## A role snowflake or resolved role.
    cokMentionable, ## A user-or-role option.
    cokNumber, ## A floating-point option.
    cokAttachment ## An attachment option.

  CommandInstallContext* = enum ## Where an application command may be
                                ## installed.
    guildInstall, ## Installation owned by a guild.
    userInstall ## Installation owned by a user.

  CommandInteractionContext* = enum ## Surfaces where a command may be invoked.
    guildChannel, ## A channel belonging to a guild.
    botDm, ## A direct message with the installed bot user.
    privateChannel ## A private channel available to a user-installed app.

  CommandAckKind* = enum ## Initial-response policy generated into command
                         ## metadata.
    ackManual, ## The handler must acknowledge the interaction itself.
    ackAutoDefer ## The runtime may create a deferred message response.

  CommandChoice* = object ## One statically generated Discord option choice.
    name*: string ## User-facing choice name.
    value*: string ## Stable wire value accepted by the decoder.

  CommandOptionSpec* = object ## Generated schema for one typed procedure
                              ## parameter.
    name*: string ## Discord option name.
    description*: string ## User-facing option description.
    kind*: CommandOptionKind ## Discord wire option kind.
    required*: bool ## Whether the option must be present.
    minimumInt*: Option[int64] ## Inclusive integer minimum for range types.
    maximumInt*: Option[int64] ## Inclusive integer maximum for range types.
    choices*: seq[CommandChoice] ## Enum choices in declaration order.

  CommandSpec* = object ## Complete generated schema for an application command.
    name*: string ## Discord command name.
    description*: string ## User-facing command description.
    kind*: CommandKind ## Discord command kind.
    installs*: set[CommandInstallContext] ## Supported installation owners.
    contexts*: set[CommandInteractionContext] ## Supported invocation surfaces.
    ack*: CommandAckKind ## Initial-response policy.
    autoDeferAfterMs*: int ## Auto-defer delay in milliseconds.
    ephemeral*: bool ## Whether an auto-defer is ephemeral.
    requiredBotPermissions*: Permissions ## Known bot permissions used by the
                                         ## handler.
    options*: seq[CommandOptionSpec] ## Typed command options.

  CommandTargetKind* = enum ## Context-menu command target category.
    ctkUser, ## Selected user target.
    ctkMessage ## Selected message target.

  CommandTarget* = object ## Typed target selected for a context-menu command.
    case kind*: CommandTargetKind ## User or message discriminator.
    of ctkUser:
      targetUserId*: UserId ## Selected user snowflake.
    of ctkMessage:
      targetMessageId*: MessageId ## Selected message snowflake.

  CommandInvocation* = object ## Transport-independent dispatcher input.
    name*: string ## Command name supplied by the interaction router.
    options*: JsonNode ## Object containing Discord option values by name.
    userId*: UserId ## Invoking user snowflake.
    guildId*: Option[GuildId] ## Guild snowflake when invoked in a guild.
    context*: InvocationContext ## Installation, surface, and effective
                                ## permissions.
    target*: Option[CommandTarget] ## User or message selected by a context
                                   ## command.
    resolved*: JsonNode ## Lossless resolved command entities from Discord.

  CommandResultKind* = enum ## Outcome returned by a generated command adapter.
    crSucceeded, ## The handler completed successfully.
    crRejected, ## Middleware or the handler rejected the invocation.
    crInvalidOptions, ## Option decoding or validation failed.
    crNotFound ## No registered command matched the invocation name.

  CommandResult* = object ## Transport-neutral result from command dispatch.
    kind*: CommandResultKind ## Outcome classification.
    message*: string ## Optional response or diagnostic message.
    payload*: JsonNode ## Optional complete Discord message data object.

  CommandCtx*[S] = object ## Typed command context supplied to generated
                          ## handlers.
    serviceValue: ref S
    responseContextValue: appcontext.Context
    invocationValue: CommandInvocation

  CommandHandler*[S] = proc (
      services: ref S;
      context: appcontext.Context;
      invocation: CommandInvocation
    ): Future[CommandResult] {.closure.} ## Type-erased Chronos adapter
                                        ## generated from a typed command
                                        ## procedure.
    ##
    ## Once a handler selects an initial response through `context`, ingress
    ## treats that response as authoritative and ignores its `CommandResult`.

  CommandResponseUnavailableError* = object of CatchableError
    ## A result-only dispatch attempted response transport I/O.

  CommandSet*[S] = object ## Explicit registry produced by `commandSet`.
    schemas: seq[CommandSpec]
    handlers: seq[CommandHandler[S]]

proc initCommandCtx*[S](services: ref S, context: appcontext.Context,
                        invocation: sink CommandInvocation): CommandCtx[S] =
  ## Creates a generated-handler view over one app-owned service allocation.
  if services.isNil:
    raise newException(ValueError, "command services are unavailable")
  CommandCtx[S](
    serviceValue: services,
    responseContextValue: context,
    invocationValue: invocation
  )

func responseContext*[S](context: CommandCtx[S]): appcontext.Context =
  ## Returns the ingress-owned response-capable interaction context.
  context.responseContextValue

func services*[S](context: CommandCtx[S]): lent S =
  ## Borrows the application dependency container.
  context.serviceValue[]

func invocation*[S](context: CommandCtx[S]): lent CommandInvocation =
  ## Borrows the transport-neutral command invocation.
  context.invocationValue

proc responseState*[S](context: CommandCtx[S]): InteractionResponseState =
  ## Loads the authoritative initial-response state.
  if context.responseContextValue.isNil:
    raise newException(CommandResponseUnavailableError,
      "result-only command dispatch cannot inspect interaction responses")
  context.responseContextValue.responseState()

func requireResponseContext[S](context: CommandCtx[S]): appcontext.Context =
  if context.responseContextValue.isNil:
    raise newException(CommandResponseUnavailableError,
      "result-only command dispatch cannot send interaction responses")
  context.responseContextValue

proc reply*[S](context: CommandCtx[S], body: sink JsonNode,
               visibility = vPublic): Future[void] =
  ## Selects an immediate initial message; ingress confirms delivery later.
  appcontext.reply(context.requireResponseContext(), body, visibility)

proc reply*[S](context: CommandCtx[S], content: string,
               visibility = vPublic): Future[void] =
  ## Selects a plain-content initial message; ingress confirms delivery later.
  appcontext.reply(context.requireResponseContext(), content, visibility)

proc deferReply*[S](context: CommandCtx[S],
                    visibility = vPublic): Future[void] =
  ## Selects a deferred response; ingress confirms delivery later.
  appcontext.deferReply(context.requireResponseContext(), visibility)

proc updateMessage*[S](context: CommandCtx[S], body: sink JsonNode):
    Future[void] =
  ## Selects an immediate component-message update for later delivery.
  appcontext.updateMessage(context.requireResponseContext(), body)

proc showModal*[S](context: CommandCtx[S], body: sink JsonNode): Future[void] =
  ## Selects a modal as the initial response for later delivery.
  appcontext.showModal(context.requireResponseContext(), body)

proc editOriginal*[S](context: CommandCtx[S], body: sink JsonNode):
    Future[void] =
  ## Edits the original response after acknowledgement.
  appcontext.editOriginal(context.requireResponseContext(), body)

proc followup*[S](context: CommandCtx[S], body: sink JsonNode,
                  visibility = vPublic): Future[void] =
  ## Sends a follow-up through ingress-owned transport.
  appcontext.followup(context.requireResponseContext(), body, visibility)

proc followup*[S](context: CommandCtx[S], content: string,
                  visibility = vPublic): Future[void] =
  ## Sends a plain-content follow-up through ingress-owned transport.
  appcontext.followup(context.requireResponseContext(), content, visibility)

func surface*[S](context: CommandCtx[S]): InteractionSurface =
  ## Returns the Discord surface where this command was invoked.
  context.invocationValue.context.surface

func integrationOwners*[S](context: CommandCtx[S]):
    lent seq[IntegrationOwner] =
  ## Borrows the principals that authorized this application installation.
  context.invocationValue.context.integrationOwners

func invokingUser*[S](context: CommandCtx[S]): UserId =
  ## Returns the user who invoked the command, not its installation owner.
  context.invocationValue.context.invokingUserId

func appPermissions*[S](context: CommandCtx[S]): Permissions =
  ## Returns arbitrary-width effective application permissions.
  context.invocationValue.context.appPermissions

func responsePolicy*[S](context: CommandCtx[S]): ResponsePolicy =
  ## Returns the visibility policy derived from installation context.
  context.invocationValue.context.responsePolicy

func targetUser*[S](context: CommandCtx[S]): Option[UserId] =
  ## Returns the selected user only for a user context-menu command.
  if context.invocationValue.target.isSome and
      context.invocationValue.target.get().kind == ctkUser:
    some(context.invocationValue.target.get().targetUserId)
  else:
    none(UserId)

func targetMessage*[S](context: CommandCtx[S]): Option[MessageId] =
  ## Returns the selected message only for a message context-menu command.
  if context.invocationValue.target.isSome and
      context.invocationValue.target.get().kind == ctkMessage:
    some(context.invocationValue.target.get().targetMessageId)
  else:
    none(MessageId)

proc initCommandSet*[S](specs: sink seq[CommandSpec],
                        handlers: sink seq[CommandHandler[S]]): CommandSet[S] =
  ## Constructs a registry from schemas and their position-matched adapters.
  ##
  ## Most applications use `commandSet`; this constructor supports generated
  ## integrations that apply the same one-schema-per-handler invariant.
  if specs.len != handlers.len:
    raise newException(ValueError,
      "each command schema must have exactly one handler")
  CommandSet[S](schemas: specs, handlers: handlers)

func initCommandSet*[S](): CommandSet[S] =
  ## Creates an empty typed command registry.
  CommandSet[S](schemas: @[], handlers: @[])

func succeeded*(message = ""): CommandResult =
  ## Creates a successful command result.
  CommandResult(kind: crSucceeded, message: message)

proc succeededPayload*(payload: sink JsonNode): CommandResult =
  ## Creates a successful result from a complete Discord message data object.
  ##
  ## This is the bridge used by Components V2 serializers. The interaction
  ## router copies the object and still applies secure mention defaults.
  if payload.isNil or payload.kind != JObject:
    raise newException(ValueError,
      "command response payload must be a JSON object")
  CommandResult(kind: crSucceeded, payload: payload)

func rejected*(message: string): CommandResult =
  ## Creates a result for a deliberately rejected invocation.
  CommandResult(kind: crRejected, message: message)

func invalidOptions*(message: string): CommandResult =
  ## Creates a result for an option decoding or validation failure.
  CommandResult(kind: crInvalidOptions, message: message)

func notFound*(commandName: string): CommandResult =
  ## Creates a result for an unregistered command name.
  CommandResult(kind: crNotFound,
    message: "unknown application command: " & commandName)

func len*[S](commands: CommandSet[S]): int =
  ## Returns the number of registered commands.
  commands.schemas.len

func specs*[S](commands: CommandSet[S]): lent seq[CommandSpec] =
  ## Borrows the deterministically ordered schemas without exposing mutation.
  commands.schemas

func find*[S](commands: CommandSet[S], commandName: string): int =
  ## Returns the sorted registry index for `commandName`, or `-1` when absent.
  for index, spec in commands.schemas:
    if spec.name == commandName:
      return index
  -1

func contains*[S](commands: CommandSet[S], commandName: string): bool =
  ## Reports whether `commandName` is registered.
  commands.find(commandName) >= 0

iterator items*[S](commands: CommandSet[S]): CommandSpec =
  ## Iterates over command schemas in deterministic name order.
  for spec in commands.schemas:
    yield spec

proc dispatchWithServices*[S](commands: CommandSet[S],
                              services: ref S,
                              context: appcontext.Context,
                              invocation: CommandInvocation):
                              Future[CommandResult] {.async.} =
  ## Dispatches with app-owned services and optional response authority.
  ##
  ## When a handler selects an initial response, ingress must ignore the
  ## returned `CommandResult`; the selected exchange response owns the ACK.
  if services.isNil:
    raise newException(ValueError, "command services are unavailable")
  let index = commands.find(invocation.name)
  if index < 0:
    return notFound(invocation.name)
  return await commands.handlers[index](services, context, invocation)

proc dispatch*[S](commands: CommandSet[S], services: sink S,
                  context: appcontext.Context,
                  invocation: CommandInvocation): Future[CommandResult] {.
                  async.} =
  ## Dispatches directly with a service allocation owned by this operation.
  var serviceOwner: ref S
  new serviceOwner
  serviceOwner[] = services
  return await commands.dispatchWithServices(
    serviceOwner, context, invocation)

proc dispatch*[S](commands: CommandSet[S], services: sink S,
                  invocation: CommandInvocation): Future[CommandResult] {.
                  async.} =
  ## Dispatches without response transport for tests and result-only callers.
  ##
  ## Existing handlers that only return `CommandResult` remain supported. A
  ## handler that calls a response operation receives
  ## `CommandResponseUnavailableError` instead of silently discarding I/O.
  return await commands.dispatch(services, nil, invocation)
