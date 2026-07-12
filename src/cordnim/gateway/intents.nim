## Typed Discord Gateway intents and their IDENTIFY bit mask.
##
## The enum is application-facing configuration; `toMask` is the only wire
## conversion needed by IDENTIFY. Keeping the mapping here prevents app
## composition code from duplicating protocol bit positions.

type
  GatewayIntent* = enum ## Gateway event groups an application may request.
    giGuilds, ## Guild, channel, thread, and role lifecycle events.
    giGuildMembers, ## Guild member events; a privileged intent.
    giGuildModeration, ## Guild bans and audit-log entry events.
    giGuildExpressions, ## Emoji, sticker, and soundboard events.
    giGuildIntegrations, ## Guild integration events.
    giGuildWebhooks, ## Webhook update events.
    giGuildInvites, ## Invite lifecycle events.
    giGuildVoiceStates, ## Voice-state and voice-channel effect events.
    giGuildPresences, ## Presence events; a privileged intent.
    giGuildMessages, ## Message events in guild channels.
    giGuildMessageReactions, ## Reaction events in guild channels.
    giGuildMessageTyping, ## Typing events in guild channels.
    giDirectMessages, ## Message and pin events in direct messages.
    giDirectMessageReactions, ## Reaction events in direct messages.
    giDirectMessageTyping, ## Typing events in direct messages.
    giMessageContent, ## User-authored message fields; a privileged intent.
    giGuildScheduledEvents, ## Scheduled-event lifecycle events.
    giAutoModerationConfig, ## Auto Moderation rule configuration events.
    giAutoModerationExecution, ## Auto Moderation action events.
    giGuildMessagePolls, ## Poll vote events in guild channels.
    giDirectMessagePolls ## Poll vote events in direct messages.

const
  PrivilegedGatewayIntents* = {
    giGuildMembers, giGuildPresences, giMessageContent
  } ## Intents that may require approval in the Discord Developer Portal.

func intentBit*(intent: GatewayIntent): uint64 {.raises: [].} =
  ## Returns the exact bit Discord assigns to `intent` in IDENTIFY.
  case intent
  of giGuilds: 1'u64 shl 0
  of giGuildMembers: 1'u64 shl 1
  of giGuildModeration: 1'u64 shl 2
  of giGuildExpressions: 1'u64 shl 3
  of giGuildIntegrations: 1'u64 shl 4
  of giGuildWebhooks: 1'u64 shl 5
  of giGuildInvites: 1'u64 shl 6
  of giGuildVoiceStates: 1'u64 shl 7
  of giGuildPresences: 1'u64 shl 8
  of giGuildMessages: 1'u64 shl 9
  of giGuildMessageReactions: 1'u64 shl 10
  of giGuildMessageTyping: 1'u64 shl 11
  of giDirectMessages: 1'u64 shl 12
  of giDirectMessageReactions: 1'u64 shl 13
  of giDirectMessageTyping: 1'u64 shl 14
  of giMessageContent: 1'u64 shl 15
  of giGuildScheduledEvents: 1'u64 shl 16
  of giAutoModerationConfig: 1'u64 shl 20
  of giAutoModerationExecution: 1'u64 shl 21
  of giGuildMessagePolls: 1'u64 shl 24
  of giDirectMessagePolls: 1'u64 shl 25

func toMask*(intents: set[GatewayIntent]): uint64 {.raises: [].} =
  ## Combines a typed intent set into the integer sent with IDENTIFY.
  for intent in intents:
    result = result or intent.intentBit

func privileged*(intents: set[GatewayIntent]): set[GatewayIntent] {.
    raises: [].} =
  ## Returns only intents that may require Developer Portal approval.
  intents * PrivilegedGatewayIntents

func hasPrivileged*(intents: set[GatewayIntent]): bool {.raises: [].} =
  ## Reports whether `intents` contains at least one privileged intent.
  (intents * PrivilegedGatewayIntents) != {}
