## Gateway intent-mask and application configuration tests.

import std/unittest

import cordnim/app
import cordnim/gateway/intents

suite "Gateway intents":
  test "maps every declared intent to Discord's documented bit":
    check giGuilds.intentBit == 1'u64 shl 0
    check giGuildMembers.intentBit == 1'u64 shl 1
    check giGuildModeration.intentBit == 1'u64 shl 2
    check giGuildExpressions.intentBit == 1'u64 shl 3
    check giGuildIntegrations.intentBit == 1'u64 shl 4
    check giGuildWebhooks.intentBit == 1'u64 shl 5
    check giGuildInvites.intentBit == 1'u64 shl 6
    check giGuildVoiceStates.intentBit == 1'u64 shl 7
    check giGuildPresences.intentBit == 1'u64 shl 8
    check giGuildMessages.intentBit == 1'u64 shl 9
    check giGuildMessageReactions.intentBit == 1'u64 shl 10
    check giGuildMessageTyping.intentBit == 1'u64 shl 11
    check giDirectMessages.intentBit == 1'u64 shl 12
    check giDirectMessageReactions.intentBit == 1'u64 shl 13
    check giDirectMessageTyping.intentBit == 1'u64 shl 14
    check giMessageContent.intentBit == 1'u64 shl 15
    check giGuildScheduledEvents.intentBit == 1'u64 shl 16
    check giAutoModerationConfig.intentBit == 1'u64 shl 20
    check giAutoModerationExecution.intentBit == 1'u64 shl 21
    check giGuildMessagePolls.intentBit == 1'u64 shl 24
    check giDirectMessagePolls.intentBit == 1'u64 shl 25

  test "combines application subscriptions without adding an ingress bit":
    let config = initAppConfig(
      ingressGateway,
      gatewaySubscriptions({giGuilds, giGuildMessages, giMessageContent})
    )
    check config.gatewayIntentMask == (
      (1'u64 shl 0) or (1'u64 shl 9) or (1'u64 shl 15)
    )

    let interactionOnly = initAppConfig(ingressGateway)
    check interactionOnly.gatewayIntentMask == 0'u64

  test "reports only the privileged subset":
    let requested = {
      giGuilds, giGuildMembers, giGuildPresences, giMessageContent
    }
    check requested.hasPrivileged
    check requested.privileged ==
      {giGuildMembers, giGuildPresences, giMessageContent}
    check not {giGuilds, giGuildMessages}.hasPrivileged
