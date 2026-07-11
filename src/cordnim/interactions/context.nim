## Installation and invocation context for interactions.

import std/options

import cordnim/core/[ids, permissions]

type
  InteractionSurface* = enum ## Discord surface where an interaction ran.
    isGuildChannel,  ## Channel associated with a guild.
    isBotDm,         ## Direct message with the installed bot user.
    isPrivateChannel ## Private channel without a guild context.

  InstallationKind* = enum ## Principal that authorized the application.
    iiGuildInstall, ## A guild owns the application integration.
    iiUserInstall   ## A Discord user owns the application integration.

  IntegrationOwner* = object ## One authorization owner from interaction data.
    case kind*: InstallationKind ## Guild or user installation class.
    of iiGuildInstall:
      guildId*: GuildId           ## Guild that authorized the application.
    of iiUserInstall:
      userId*: UserId             ## User that authorized the application.

  EffectiveVisibility* = object ## Resolved visibility for one response request.
    requested*: bool ## Whether the caller requested a public response.
    # A boolean keeps this wire-neutral and avoids a dependency cycle with the
    # response-state module.
    ephemeral*: bool ## Whether Discord requires an ephemeral response.
    reason*: Option[string] ## Explanation for a visibility override.

  ResponsePolicy* = object ## Visibility limits computed from Discord context.
    publicResponseAllowed*: bool ## Whether a public response is legal here.
    reason*: Option[string] ## Why public output is unavailable.

  InvocationContext* = object ## Identities and permissions for one invocation.
    surface*: InteractionSurface ## Surface where the command was invoked.
    integrationOwners*: seq[IntegrationOwner]
      ## Authorization owners reported by Discord.
    invokingUserId*: UserId ## User who actually invoked the interaction.
    guildId*: Option[GuildId] ## Guild where the invocation happened, if any.
    appPermissions*: Permissions ## Effective application permissions.
    memberPermissions*: Option[Permissions]
      ## Effective invoking-member permissions when available.
    followupBudget*: Option[int]
      ## Known follow-up limit for user-installed apps, when constrained.
    responsePolicy*: ResponsePolicy ## Effective response constraints.

func hasOwner*(context: InvocationContext, kind: InstallationKind): bool =
  ## Reports whether Discord lists an authorization owner of `kind`.
  for owner in context.integrationOwners:
    if owner.kind == kind:
      return true

func actualVisibility*(context: InvocationContext,
                       requestedPublic: bool): EffectiveVisibility =
  ## The ingress decoder derives `responsePolicy` from Discord's interaction
  ## context. This helper never guesses from the invoking user or integration
  ## owner, which are deliberately separate identities.
  if requestedPublic and not context.responsePolicy.publicResponseAllowed:
    EffectiveVisibility(
      requested: true,
      ephemeral: true,
      reason: context.responsePolicy.reason
    )
  else:
    EffectiveVisibility(requested: requestedPublic, ephemeral: not requestedPublic)
