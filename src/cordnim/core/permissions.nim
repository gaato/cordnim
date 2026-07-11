## Known Discord permission bits layered on arbitrary-width storage.
##
## `Permission` names current documented bit positions. `DiscordBits` remains
## open-ended, so future permissions round-trip even before this enum updates.

import ./bits

type
  Permission* {.pure.} = enum ## Discord permission bit positions documented on
                              ## 2026-07-11.
    createInstantInvite = 0 ## Create instant invites.
    kickMembers = 1 ## Kick guild members.
    banMembers = 2 ## Ban guild members.
    administrator = 3 ## Bypass channel overwrites and grant all
                      ## permissions.
    manageChannels = 4 ## Manage channels.
    manageGuild = 5 ## Manage guild settings.
    addReactions = 6 ## Add new reactions.
    viewAuditLog = 7 ## Read the audit log.
    prioritySpeaker = 8 ## Use priority speaker.
    stream = 9 ## Stream video or an activity.
    viewChannel = 10 ## View a channel.
    sendMessages = 11 ## Send messages outside threads.
    sendTtsMessages = 12 ## Send text-to-speech messages.
    manageMessages = 13 ## Manage other users' messages.
    embedLinks = 14 ## Embed links.
    attachFiles = 15 ## Attach files.
    readMessageHistory = 16 ## Read prior messages.
    mentionEveryone = 17 ## Mention everyone, here, and all roles.
    useExternalEmojis = 18 ## Use emojis from other guilds.
    viewGuildInsights = 19 ## View guild analytics.
    connect = 20 ## Join voice or stage channels.
    speak = 21 ## Speak in voice channels.
    muteMembers = 22 ## Server-mute members.
    deafenMembers = 23 ## Server-deafen members.
    moveMembers = 24 ## Move members between voice channels.
    useVad = 25 ## Use voice activity detection.
    changeNickname = 26 ## Change one's own nickname.
    manageNicknames = 27 ## Change other members' nicknames.
    manageRoles = 28 ## Manage roles and permission overwrites.
    manageWebhooks = 29 ## Manage webhooks.
    manageGuildExpressions = 30 ## Manage all guild expressions.
    useApplicationCommands = 31 ## Invoke application commands.
    requestToSpeak = 32 ## Request stage speaker status.
    manageEvents = 33 ## Manage all scheduled events.
    manageThreads = 34 ## Manage threads.
    createPublicThreads = 35 ## Create public threads.
    createPrivateThreads = 36 ## Create private threads.
    useExternalStickers = 37 ## Use stickers from other guilds.
    sendMessagesInThreads = 38 ## Send messages in threads.
    useEmbeddedActivities = 39 ## Use embedded Activities.
    moderateMembers = 40 ## Time out members.
    viewCreatorMonetizationAnalytics = 41 ## View monetization analytics.
    useSoundboard = 42 ## Use the guild soundboard.
    createGuildExpressions = 43 ## Create one's own guild expressions.
    createEvents = 44 ## Create scheduled events.
    useExternalSounds = 45 ## Use soundboard sounds from other guilds.
    sendVoiceMessages = 46 ## Send voice messages.
    sendPolls = 49 ## Create polls.
    useExternalApps = 50 ## Allow user-installed apps to respond publicly.
    pinMessages = 51 ## Pin and unpin messages.
    bypassSlowmode = 52 ## Bypass channel slowmode.

  Permissions* = DiscordBits[Permission] ## Arbitrary-width permission value
                                         ## preserving all unknown bits.

proc parsePermissions*(text: string): Permissions =
  ## Parses Discord's decimal string-serialized permission value.
  parseDiscordBits[Permission](text)
