## Public command metadata, invocation values, and asynchronous dispatch
## contracts.
##
## Command metadata is plain data so the compiler-generated manifest can be
## inspected, serialized, and tested without starting a Discord connection.

import std/[algorithm, hashes, json, options, strutils, unicode]
import chronos

import cordnim/app/context as appcontext
import cordnim/core/[bits, ids, permissions]
import cordnim/interactions/context
import cordnim/interactions/responder
import ./name_grammar
from cordnim/components/forms import ModalSpec

export Visibility, InteractionResponseState

type
  DiscordLocale* = enum ## Discord client locale identifiers used verbatim as
                        ## localization-dictionary keys and interaction locale
                        ## values. The enum value string is the Discord wire
                        ## code; see the Discord "Locales" reference table.
    dlIndonesian = "id"
    dlDanish = "da"
    dlGerman = "de"
    dlEnglishUk = "en-GB"
    dlEnglishUs = "en-US"
    dlSpanish = "es-ES"
    dlSpanishLatam = "es-419"
    dlFrench = "fr"
    dlCroatian = "hr"
    dlItalian = "it"
    dlLithuanian = "lt"
    dlHungarian = "hu"
    dlDutch = "nl"
    dlNorwegian = "no"
    dlPolish = "pl"
    dlPortugueseBrazilian = "pt-BR"
    dlRomanian = "ro"
    dlFinnish = "fi"
    dlSwedish = "sv-SE"
    dlVietnamese = "vi"
    dlTurkish = "tr"
    dlCzech = "cs"
    dlGreek = "el"
    dlBulgarian = "bg"
    dlRussian = "ru"
    dlUkrainian = "uk"
    dlHindi = "hi"
    dlThai = "th"
    dlChineseChina = "zh-CN"
    dlJapanese = "ja"
    dlChineseTaiwan = "zh-TW"
    dlKorean = "ko"

  LocalizationMap* = object ## Deterministic Discord localization dictionary.
                            ##
                            ## Entries are stored sorted by locale wire code and
                            ## deduplicated, so serialization and hashing of a
                            ## manifest do not depend on insertion order.
    entries: seq[tuple[locale: DiscordLocale, value: string]]

  CommandChannelType* = enum ## Discord channel types accepted by a `CHANNEL`
                             ## command option's `channel_types` constraint.
                             ## Ordinals are the Discord wire values.
    cctGuildText = 0
    cctDm = 1
    cctGuildVoice = 2
    cctGroupDm = 3
    cctGuildCategory = 4
    cctGuildAnnouncement = 5
    cctAnnouncementThread = 10
    cctPublicThread = 11
    cctPrivateThread = 12
    cctGuildStageVoice = 13
    cctGuildDirectory = 14
    cctGuildForum = 15
    cctGuildMedia = 16

  CommandSpecError* = object of CatchableError
    ## A command schema violated a Discord structural or naming rule at
    ## construction time.

type
  CommandKind* = enum ## Discord application command kinds.
    ckChatInput, ## A slash command with typed options.
    ckUser, ## A command shown in a user's context menu.
    ckMessage ## A command shown in a message's context menu.

  CommandKey* = object ## Stable identity of one application command.
    kind*: CommandKind ## Discord command kind.
    name*: string ## Command name within that kind.

  CommandOptionKind* = enum ## Discord application command option kinds.
    cokString, ## A UTF-8 string option.
    cokInteger, ## An integer option.
    cokBoolean, ## A boolean option.
    cokUser, ## A user snowflake or resolved user.
    cokChannel, ## A channel snowflake or resolved channel.
    cokRole, ## A role snowflake or resolved role.
    cokMentionable, ## A user-or-role option.
    cokNumber, ## A floating-point option.
    cokAttachment, ## An attachment option.
    cokSubCommand, ## A nested subcommand (structural, holds scalar options).
    cokSubCommandGroup ## A nested subcommand group (holds only subcommands).

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

  CommandChoiceValueKind* = enum ## Wire value type of an option choice.
    ccvString, ## String choice value.
    ccvInteger, ## Integer choice value.
    ccvNumber ## Floating-point choice value.

  CommandChoice* = object ## One statically declared Discord option choice.
    name*: string ## User-facing choice name.
    nameLocalizations*: LocalizationMap ## Per-locale choice names.
    case kind*: CommandChoiceValueKind ## Value discriminator matching the
                                       ## option kind.
    of ccvString:
      stringValue*: string ## String choice value (max 100 characters).
    of ccvInteger:
      integerValue*: int64 ## Integer choice value.
    of ccvNumber:
      numberValue*: float ## Floating-point choice value.

  CommandOptionSpec* = object ## Generated schema for one typed procedure
                              ## parameter or one structural subcommand node.
    name*: string ## Discord option name.
    description*: string ## User-facing option description.
    nameLocalizations*: LocalizationMap ## Per-locale option/subcommand names.
    descriptionLocalizations*: LocalizationMap ## Per-locale descriptions.
    kind*: CommandOptionKind ## Discord wire option kind.
    required*: bool ## Whether the option must be present (scalar options only).
    minimumInt*: Option[int64] ## Inclusive integer minimum for range types.
    maximumInt*: Option[int64] ## Inclusive integer maximum for range types.
    minimumNumber*: Option[float] ## Inclusive minimum for number options.
    maximumNumber*: Option[float] ## Inclusive maximum for number options.
    minLength*: Option[int] ## Minimum length for string options.
    maxLength*: Option[int] ## Maximum length for string options.
    channelTypes*: seq[CommandChannelType] ## Channel-kind constraint; valid
                                           ## only for channel options.
    autocomplete*: bool ## Whether the option resolves values by autocomplete;
                        ## mutually exclusive with `choices`.
    choices*: seq[CommandChoice] ## Enum choices in declaration order.
    options*: seq[CommandOptionSpec] ## Nested options for subcommand and
                                     ## subcommand-group kinds.

  CommandSpec* = object ## Complete generated schema for an application command.
    name*: string ## Discord command name.
    description*: string ## User-facing command description.
    nameLocalizations*: LocalizationMap ## Per-locale command names.
    descriptionLocalizations*: LocalizationMap ## Per-locale command
                                               ## descriptions; never emitted
                                               ## for context-menu commands.
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
    kind*: CommandKind ## Command kind supplied by Discord.
    name*: string ## Command name supplied by the interaction router.
    options*: JsonNode ## Object containing Discord option values by name.
    userId*: UserId ## Invoking user snowflake.
    guildId*: Option[GuildId] ## Guild snowflake when invoked in a guild.
    context*: InvocationContext ## Installation, surface, and effective
                                ## permissions.
    locale*: Option[DiscordLocale] ## Selected language of the invoking user.
    guildLocale*: Option[DiscordLocale] ## Guild's preferred locale, when the
                                        ## interaction ran in a guild. Kept
                                        ## distinct from `locale`.
    target*: Option[CommandTarget] ## User or message selected by a context
                                   ## command.
    resolved*: JsonNode ## Lossless resolved command entities from Discord.

  CommandResultKind* = enum ## Outcome returned by a generated command adapter.
    crSucceeded, ## The handler completed successfully.
    crRejected, ## Middleware or the handler rejected the invocation.
    crInvalidOptions, ## Option decoding or validation failed.
    crNotFound ## No registered command matched the invocation identity.

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

# --- Discord locales and localization dictionaries ---

func isDiscordLocale*(text: string): bool =
  ## Reports whether `text` is a known Discord locale wire code.
  for locale in DiscordLocale:
    if $locale == text:
      return true
  false

func tryParseDiscordLocale*(text: string): Option[DiscordLocale] =
  ## Parses a Discord locale wire code, returning `none` for unknown codes.
  for locale in DiscordLocale:
    if $locale == text:
      return some(locale)
  none(DiscordLocale)

proc parseDiscordLocale*(text: string): DiscordLocale =
  ## Parses a Discord locale wire code or raises `ValueError`.
  let parsed = tryParseDiscordLocale(text)
  if parsed.isNone:
    raise newException(ValueError, "unknown Discord locale: " & text)
  parsed.unsafeGet()

func compareLocale(left, right: tuple[locale: DiscordLocale, value: string]):
    int =
  cmp($left.locale, $right.locale)

func initLocalizationMap*(): LocalizationMap =
  ## Creates an empty localization dictionary.
  LocalizationMap()

func initLocalizationMap*(
    pairs: openArray[(DiscordLocale, string)]): LocalizationMap =
  ## Creates a localization dictionary from locale/value pairs.
  ##
  ## Entries are sorted by locale wire code for deterministic serialization; a
  ## repeated locale raises `CommandSpecError`.
  var seen: set[DiscordLocale]
  for pair in pairs:
    if pair[0] in seen:
      raise newException(CommandSpecError,
        "duplicate localization locale: " & $pair[0])
    seen.incl(pair[0])
    result.entries.add((pair[0], pair[1]))
  result.entries.sort(compareLocale)

func len*(map: LocalizationMap): int =
  ## Returns the number of localized entries.
  map.entries.len

func contains*(map: LocalizationMap, locale: DiscordLocale): bool =
  ## Reports whether `locale` has a localized value.
  for entry in map.entries:
    if entry.locale == locale:
      return true
  false

func `[]`*(map: LocalizationMap, locale: DiscordLocale): string =
  ## Returns the localized value for `locale` or raises `KeyError`.
  for entry in map.entries:
    if entry.locale == locale:
      return entry.value
  raise newException(KeyError, "no localization for locale " & $locale)

func getOrDefault*(map: LocalizationMap, locale: DiscordLocale,
                   fallback = ""): string =
  ## Returns the localized value for `locale`, or `fallback` when absent.
  for entry in map.entries:
    if entry.locale == locale:
      return entry.value
  fallback

iterator pairs*(map: LocalizationMap):
    tuple[locale: DiscordLocale, value: string] =
  ## Iterates entries in deterministic locale-code order.
  for entry in map.entries:
    yield entry

func `==`*(left, right: LocalizationMap): bool =
  ## Compares localization dictionaries by their canonical entries.
  left.entries == right.entries

func toJson*(map: LocalizationMap): JsonNode =
  ## Serializes the dictionary as a Discord localization object.
  result = newJObject()
  for entry in map.entries:
    result[$entry.locale] = %entry.value

# --- Discord wire type conversions ---

func discordType*(kind: CommandKind): int =
  ## Returns the Discord application-command type number.
  case kind
  of ckChatInput: 1
  of ckUser: 2
  of ckMessage: 3

func discordType*(kind: CommandOptionKind): int =
  ## Returns the Discord application-command-option type number.
  case kind
  of cokSubCommand: 1
  of cokSubCommandGroup: 2
  of cokString: 3
  of cokInteger: 4
  of cokBoolean: 5
  of cokUser: 6
  of cokChannel: 7
  of cokRole: 8
  of cokMentionable: 9
  of cokNumber: 10
  of cokAttachment: 11

func toCommandKind*(wire: int): CommandKind =
  ## Parses a Discord command type number or raises `ValueError`.
  case wire
  of 1: ckChatInput
  of 2: ckUser
  of 3: ckMessage
  else:
    raise newException(ValueError, "unknown Discord command type: " & $wire)

func toCommandOptionKind*(wire: int): CommandOptionKind =
  ## Parses a Discord command-option type number or raises `ValueError`.
  case wire
  of 1: cokSubCommand
  of 2: cokSubCommandGroup
  of 3: cokString
  of 4: cokInteger
  of 5: cokBoolean
  of 6: cokUser
  of 7: cokChannel
  of 8: cokRole
  of 9: cokMentionable
  of 10: cokNumber
  of 11: cokAttachment
  else:
    raise newException(ValueError,
      "unknown Discord command option type: " & $wire)

func toCommandChannelType*(wire: int): CommandChannelType =
  ## Parses a Discord channel type number or raises `ValueError`.
  case wire
  of 0: cctGuildText
  of 1: cctDm
  of 2: cctGuildVoice
  of 3: cctGroupDm
  of 4: cctGuildCategory
  of 5: cctGuildAnnouncement
  of 10: cctAnnouncementThread
  of 11: cctPublicThread
  of 12: cctPrivateThread
  of 13: cctGuildStageVoice
  of 14: cctGuildDirectory
  of 15: cctGuildForum
  of 16: cctGuildMedia
  else:
    raise newException(ValueError, "unknown Discord channel type: " & $wire)

# --- Name validation shared by the compiler and explicit builders ---

func chatInputNameAllows(value: int): bool =
  ## Reports whether `value` is an allowed chat-input name code point.
  for bounds in chatInputNameRanges:
    if value < bounds[0]:
      return false # ranges are sorted ascending
    if value <= bounds[1]:
      return true
  false

func validChatInputName*(name: string): bool =
  ## Reports whether `name` matches Discord's chat-input command and option name
  ## grammar `^[-_'\p{L}\p{N}\p{sc=Deva}\p{sc=Thai}]{1,32}$` with the
  ## lowercase constraint. Membership uses the generated Unicode 15.1 table in
  ## `name_grammar`, so validation is not limited by the standard library's
  ## older Unicode data; the same table backs localized-name checks.
  if name.runeLen notin 1..32:
    return false
  for character in name.runes:
    if not chatInputNameAllows(int(character)):
      return false
  true

func validContextMenuName*(name: string): bool =
  ## Reports whether `name` is a valid 1-32 visible context-menu name.
  if name.runeLen notin 1..32 or name.strip().len == 0:
    return false
  for character in name.runes:
    let value = int(character)
    if value < 0x20 or value in 0x7f..0x9f:
      return false
  true

func validCommandName*(name: string, kind: CommandKind): bool =
  ## Reports whether `name` satisfies Discord's naming rule for `kind`.
  case kind
  of ckChatInput: validChatInputName(name)
  of ckUser, ckMessage: validContextMenuName(name)

func sortedChannelTypes(types: openArray[CommandChannelType]):
    seq[CommandChannelType] =
  for value in types:
    if value notin result:
      result.add(value)
  result.sort()

# --- Construction-time schema validation ---

const
  discordMinSafeInteger = -9007199254740991'i64
    ## Discord INTEGER option lower bound (-(2^53 - 1)).
  discordMaxSafeInteger = 9007199254740991'i64
    ## Discord INTEGER option upper bound (2^53 - 1).
  discordMinSafeNumber = -9007199254740992.0
    ## Discord NUMBER option lower bound (-2^53), inclusive.
  discordMaxSafeNumber = 9007199254740992.0
    ## Discord NUMBER option upper bound (2^53), inclusive.
  discordMaxStringLength = 6000 ## Discord STRING length ceiling.
  discordMaxCommandChars = 8000
    ## Discord CHAT_INPUT aggregate character budget across the command, its
    ## options, subcommands, groups, and choices.

func isFiniteNumber(value: float): bool =
  ## Returns whether `value` is neither NaN nor an infinity.
  value == value and value != Inf and value != -Inf

proc validateLocalizationLengths(map: LocalizationMap, minLen, maxLen: int,
                                 what: string) =
  for locale, value in map:
    if value.runeLen < minLen or value.runeLen > maxLen:
      raise newException(CommandSpecError,
        what & " localization for " & $locale & " must contain " &
          $minLen & "-" & $maxLen & " characters")

proc validateNameLocalizations(map: LocalizationMap, kind: CommandKind,
                               what: string) =
  # Localized names follow the same length and character rule as the default
  # name for the command kind.
  for locale, value in map:
    if not validCommandName(value, kind):
      raise newException(CommandSpecError,
        what & " localization for " & $locale &
          " must follow Discord's name rules")

proc validateSiblingLocalizedNames(options: openArray[CommandOptionSpec]) =
  # Discord requires each localized option or subcommand name to be distinct
  # from every sibling's default name and from every sibling's effective name
  # within the same locale.
  var locales: seq[DiscordLocale]
  for option in options:
    for locale, _ in option.nameLocalizations:
      if locale notin locales:
        locales.add(locale)
  for locale in locales:
    var effective: seq[string]
    for option in options:
      let name = option.nameLocalizations.getOrDefault(locale, option.name)
      if name in effective:
        raise newException(CommandSpecError,
          "option name '" & name & "' is not unique for locale " & $locale)
      effective.add(name)
    for index in 0 ..< options.len:
      if locale notin options[index].nameLocalizations:
        continue
      let localized = options[index].nameLocalizations[locale]
      for other in 0 ..< options.len:
        if other != index and options[other].name == localized:
          raise newException(CommandSpecError,
            "localized option name '" & localized & "' for locale " &
              $locale & " collides with a sibling's default name")

proc validateOptionRanges(option: CommandOptionSpec) =
  if option.minimumInt.isSome:
    let value = option.minimumInt.unsafeGet()
    if value < discordMinSafeInteger or value > discordMaxSafeInteger:
      raise newException(CommandSpecError,
        "option '" & option.name & "' integer minimum is out of range")
  if option.maximumInt.isSome:
    let value = option.maximumInt.unsafeGet()
    if value < discordMinSafeInteger or value > discordMaxSafeInteger:
      raise newException(CommandSpecError,
        "option '" & option.name & "' integer maximum is out of range")
  if option.minimumInt.isSome and option.maximumInt.isSome and
      option.minimumInt.unsafeGet() > option.maximumInt.unsafeGet():
    raise newException(CommandSpecError,
      "option '" & option.name & "' integer minimum exceeds its maximum")
  if option.minimumNumber.isSome:
    let value = option.minimumNumber.unsafeGet()
    if not isFiniteNumber(value):
      raise newException(CommandSpecError,
        "option '" & option.name & "' number minimum must be finite")
    if value < discordMinSafeNumber or value > discordMaxSafeNumber:
      raise newException(CommandSpecError,
        "option '" & option.name & "' number minimum is out of range")
  if option.maximumNumber.isSome:
    let value = option.maximumNumber.unsafeGet()
    if not isFiniteNumber(value):
      raise newException(CommandSpecError,
        "option '" & option.name & "' number maximum must be finite")
    if value < discordMinSafeNumber or value > discordMaxSafeNumber:
      raise newException(CommandSpecError,
        "option '" & option.name & "' number maximum is out of range")
  if option.minimumNumber.isSome and option.maximumNumber.isSome and
      option.minimumNumber.unsafeGet() > option.maximumNumber.unsafeGet():
    raise newException(CommandSpecError,
      "option '" & option.name & "' number minimum exceeds its maximum")
  if option.minLength.isSome:
    let value = option.minLength.unsafeGet()
    if value < 0 or value > discordMaxStringLength:
      raise newException(CommandSpecError,
        "option '" & option.name & "' min_length must be within 0..6000")
  if option.maxLength.isSome:
    let value = option.maxLength.unsafeGet()
    if value < 1 or value > discordMaxStringLength:
      raise newException(CommandSpecError,
        "option '" & option.name & "' max_length must be within 1..6000")
  if option.minLength.isSome and option.maxLength.isSome and
      option.minLength.unsafeGet() > option.maxLength.unsafeGet():
    raise newException(CommandSpecError,
      "option '" & option.name & "' min_length exceeds its max_length")

proc validateOptionChoices(option: CommandOptionSpec) =
  for choice in option.choices:
    if choice.name.runeLen notin 1..100:
      raise newException(CommandSpecError,
        "choice name '" & choice.name & "' must be 1-100 characters")
    validateLocalizationLengths(choice.nameLocalizations, 1, 100,
      "choice name")
    case option.kind
    of cokString:
      if choice.kind != ccvString:
        raise newException(CommandSpecError,
          "string option '" & option.name & "' requires string choices")
      if choice.stringValue.runeLen > 100:
        raise newException(CommandSpecError,
          "string choice value must be at most 100 characters")
    of cokInteger:
      if choice.kind != ccvInteger:
        raise newException(CommandSpecError,
          "integer option '" & option.name & "' requires integer choices")
      if choice.integerValue < discordMinSafeInteger or
          choice.integerValue > discordMaxSafeInteger:
        raise newException(CommandSpecError,
          "integer choice value is out of Discord's safe range")
    of cokNumber:
      if choice.kind != ccvNumber:
        raise newException(CommandSpecError,
          "number option '" & option.name & "' requires number choices")
      if not isFiniteNumber(choice.numberValue):
        raise newException(CommandSpecError,
          "number choice value must be finite")
      if choice.numberValue < discordMinSafeNumber or
          choice.numberValue > discordMaxSafeNumber:
        raise newException(CommandSpecError,
          "number choice value is out of Discord's range")
    else: discard

proc validateScalarOption(option: CommandOptionSpec) =
  if option.kind in {cokSubCommand, cokSubCommandGroup}:
    raise newException(CommandSpecError,
      "option '" & option.name & "' is not a scalar option")
  if not validChatInputName(option.name):
    raise newException(CommandSpecError,
      "option name '" & option.name & "' must be 1-32 lowercase characters")
  if option.description.runeLen notin 1..100:
    raise newException(CommandSpecError,
      "option '" & option.name & "' description must be 1-100 characters")
  validateNameLocalizations(option.nameLocalizations, ckChatInput,
    "option name")
  validateLocalizationLengths(option.descriptionLocalizations, 1, 100,
    "option description")
  if option.channelTypes.len > 0 and option.kind != cokChannel:
    raise newException(CommandSpecError,
      "option '" & option.name &
        "' declares channel_types but is not a channel option")
  if option.autocomplete and
      option.kind notin {cokString, cokInteger, cokNumber}:
    raise newException(CommandSpecError,
      "option '" & option.name &
        "' enables autocomplete but is not a string, integer, or number")
  if option.autocomplete and option.choices.len > 0:
    raise newException(CommandSpecError,
      "option '" & option.name & "' cannot combine autocomplete and choices")
  if option.choices.len > 25:
    raise newException(CommandSpecError,
      "option '" & option.name & "' declares more than 25 choices")
  if option.choices.len > 0 and
      option.kind notin {cokString, cokInteger, cokNumber}:
    raise newException(CommandSpecError,
      "option '" & option.name & "' declares choices for a non-choice kind")
  if (option.minimumInt.isSome or option.maximumInt.isSome) and
      option.kind != cokInteger:
    raise newException(CommandSpecError,
      "option '" & option.name &
        "' declares an integer range but is not an integer option")
  if (option.minimumNumber.isSome or option.maximumNumber.isSome) and
      option.kind != cokNumber:
    raise newException(CommandSpecError,
      "option '" & option.name &
        "' declares a number range but is not a number option")
  if (option.minLength.isSome or option.maxLength.isSome) and
      option.kind != cokString:
    raise newException(CommandSpecError,
      "option '" & option.name &
        "' declares a length range but is not a string option")
  validateOptionRanges(option)
  validateOptionChoices(option)

proc validateScalarOptions(options: openArray[CommandOptionSpec]) =
  var seenNames: seq[string]
  var sawOptional = false
  for option in options:
    if option.kind in {cokSubCommand, cokSubCommandGroup}:
      raise newException(CommandSpecError,
        "option '" & option.name &
          "' mixes a subcommand with scalar options at one level")
    validateScalarOption(option)
    if option.name in seenNames:
      raise newException(CommandSpecError,
        "duplicate option name '" & option.name & "' at one level")
    seenNames.add(option.name)
    if option.required and sawOptional:
      raise newException(CommandSpecError,
        "required option '" & option.name &
          "' must be declared before optional options")
    if not option.required:
      sawOptional = true
  validateSiblingLocalizedNames(options)

proc validateStructuralName(option: CommandOptionSpec, label: string) =
  if not validChatInputName(option.name):
    raise newException(CommandSpecError,
      label & " name '" & option.name & "' must be 1-32 lowercase characters")
  if option.description.runeLen notin 1..100:
    raise newException(CommandSpecError,
      label & " '" & option.name & "' description must be 1-100 characters")
  validateNameLocalizations(option.nameLocalizations, ckChatInput,
    label & " name")
  validateLocalizationLengths(option.descriptionLocalizations, 1, 100,
    label & " description")

proc validateSubcommand(option: CommandOptionSpec) =
  validateStructuralName(option, "subcommand")
  for child in option.options:
    if child.kind in {cokSubCommand, cokSubCommandGroup}:
      raise newException(CommandSpecError,
        "subcommand '" & option.name & "' cannot nest further subcommands")
  if option.options.len > 25:
    raise newException(CommandSpecError,
      "subcommand '" & option.name & "' declares more than 25 options")
  validateScalarOptions(option.options)

proc validateSubcommandGroup(option: CommandOptionSpec) =
  validateStructuralName(option, "subcommand group")
  if option.options.len == 0:
    raise newException(CommandSpecError,
      "subcommand group '" & option.name & "' must contain a subcommand")
  if option.options.len > 25:
    raise newException(CommandSpecError,
      "subcommand group '" & option.name & "' declares more than 25 members")
  var seenNames: seq[string]
  for child in option.options:
    if child.kind != cokSubCommand:
      raise newException(CommandSpecError,
        "subcommand group '" & option.name & "' may contain only subcommands")
    validateSubcommand(child)
    if child.name in seenNames:
      raise newException(CommandSpecError,
        "duplicate subcommand name '" & child.name & "' in group '" &
          option.name & "'")
    seenNames.add(child.name)
  validateSiblingLocalizedNames(option.options)

proc validateCommandOptions(options: openArray[CommandOptionSpec]) =
  if options.len == 0:
    return
  if options.len > 25:
    raise newException(CommandSpecError,
      "command declares more than 25 top-level options")
  let structural = options[0].kind in {cokSubCommand, cokSubCommandGroup}
  if not structural:
    validateScalarOptions(options)
    return
  var seenNames: seq[string]
  for option in options:
    case option.kind
    of cokSubCommand: validateSubcommand(option)
    of cokSubCommandGroup: validateSubcommandGroup(option)
    else:
      raise newException(CommandSpecError,
        "command mixes subcommands with scalar option '" & option.name & "'")
    if option.name in seenNames:
      raise newException(CommandSpecError,
        "duplicate subcommand name '" & option.name & "'")
    seenNames.add(option.name)
  validateSiblingLocalizedNames(options)

func localizedMax(default: string, map: LocalizationMap): int =
  # Discord counts the longer of the default and any single localization for a
  # localizable field, never their sum.
  result = default.runeLen
  for _, value in map:
    result = max(result, value.runeLen)

func optionCharBudget(option: CommandOptionSpec): int =
  result = localizedMax(option.name, option.nameLocalizations) +
    localizedMax(option.description, option.descriptionLocalizations)
  for choice in option.choices:
    result += localizedMax(choice.name, choice.nameLocalizations)
    if choice.kind == ccvString:
      result += choice.stringValue.runeLen
  for child in option.options:
    result += optionCharBudget(child)

func commandCharBudget*(spec: CommandSpec): int =
  ## Returns the Discord CHAT_INPUT aggregate character count for `spec`,
  ## counting max(default, longest localization) per localizable field and
  ## recursing through options, subcommands, groups, and choices.
  result = localizedMax(spec.name, spec.nameLocalizations) +
    localizedMax(spec.description, spec.descriptionLocalizations)
  for option in spec.options:
    result += optionCharBudget(option)

proc validate*(spec: CommandSpec) =
  ## Validates a command schema against Discord's structural and naming rules.
  ##
  ## Raises `CommandSpecError` on the first violation. `commandSet` performs the
  ## equivalent checks at compile time; call this when building specs at run
  ## time with the explicit constructors below.
  if not validCommandName(spec.name, spec.kind):
    raise newException(CommandSpecError,
      "command name '" & spec.name & "' is invalid for its kind")
  validateNameLocalizations(spec.nameLocalizations, spec.kind, "command name")
  if privateChannel in spec.contexts and userInstall notin spec.installs:
    raise newException(CommandSpecError,
      "command '" & spec.name & "' allows the private-channel context but is " &
        "not user-installable")
  if spec.installs.card == 0:
    raise newException(CommandSpecError,
      "command '" & spec.name & "' must declare at least one install context")
  if spec.contexts.card == 0:
    raise newException(CommandSpecError,
      "command '" & spec.name &
        "' must declare at least one interaction context")
  case spec.kind
  of ckChatInput:
    if spec.description.runeLen notin 1..100:
      raise newException(CommandSpecError,
        "chat-input command '" & spec.name &
          "' description must be 1-100 characters")
    validateLocalizationLengths(spec.descriptionLocalizations, 1, 100,
      "command description")
    validateCommandOptions(spec.options)
    if spec.commandCharBudget() > discordMaxCommandChars:
      raise newException(CommandSpecError,
        "chat-input command '" & spec.name & "' exceeds Discord's " &
          $discordMaxCommandChars & "-character budget")
  of ckUser, ckMessage:
    if spec.description.len != 0:
      raise newException(CommandSpecError,
        "context-menu command '" & spec.name & "' cannot have a description")
    if spec.descriptionLocalizations.len != 0:
      raise newException(CommandSpecError,
        "context-menu command '" & spec.name &
          "' cannot have description localizations")
    if spec.options.len != 0:
      raise newException(CommandSpecError,
        "context-menu command '" & spec.name & "' cannot declare options")

# --- Explicit, validated schema constructors ---

func commandChoice*(name, value: string,
                    nameLocalizations = initLocalizationMap()): CommandChoice =
  ## Creates a string-valued option choice with optional localized names.
  CommandChoice(kind: ccvString, name: name, stringValue: value,
    nameLocalizations: nameLocalizations)

func commandChoice*(name: string, value: int64,
                    nameLocalizations = initLocalizationMap()): CommandChoice =
  ## Creates an integer-valued option choice.
  CommandChoice(kind: ccvInteger, name: name, integerValue: value,
    nameLocalizations: nameLocalizations)

func commandChoice*(name: string, value: float,
                    nameLocalizations = initLocalizationMap()): CommandChoice =
  ## Creates a number-valued option choice.
  CommandChoice(kind: ccvNumber, name: name, numberValue: value,
    nameLocalizations: nameLocalizations)

proc initCommandOption*(
    kind: CommandOptionKind;
    name, description: string;
    required = false;
    choices: openArray[CommandChoice] = @[];
    channelTypes: openArray[CommandChannelType] = @[];
    autocomplete = false;
    minimumInt = none(int64); maximumInt = none(int64);
    minimumNumber = none(float); maximumNumber = none(float);
    minLength = none(int); maxLength = none(int);
    nameLocalizations = initLocalizationMap();
    descriptionLocalizations = initLocalizationMap()): CommandOptionSpec =
  ## Builds and validates one scalar chat-input option.
  ##
  ## Raises `CommandSpecError` for a subcommand kind (use `subCommand`), or when
  ## a constraint does not apply to `kind`, such as channel types on a
  ## non-channel option or autocomplete combined with choices.
  if kind in {cokSubCommand, cokSubCommandGroup}:
    raise newException(CommandSpecError,
      "use subCommand or subCommandGroup for structural options")
  result = CommandOptionSpec(
    kind: kind, name: name, description: description, required: required,
    nameLocalizations: nameLocalizations,
    descriptionLocalizations: descriptionLocalizations,
    minimumInt: minimumInt, maximumInt: maximumInt,
    minimumNumber: minimumNumber, maximumNumber: maximumNumber,
    minLength: minLength, maxLength: maxLength,
    channelTypes: sortedChannelTypes(channelTypes),
    autocomplete: autocomplete, choices: @choices)
  validateScalarOption(result)

proc subCommand*(name, description: string;
                 options: openArray[CommandOptionSpec] = @[];
                 nameLocalizations = initLocalizationMap();
                 descriptionLocalizations = initLocalizationMap()):
                 CommandOptionSpec =
  ## Builds and validates a subcommand holding scalar options.
  result = CommandOptionSpec(
    kind: cokSubCommand, name: name, description: description,
    nameLocalizations: nameLocalizations,
    descriptionLocalizations: descriptionLocalizations, options: @options)
  validateSubcommand(result)

proc subCommandGroup*(name, description: string;
                      subcommands: openArray[CommandOptionSpec];
                      nameLocalizations = initLocalizationMap();
                      descriptionLocalizations = initLocalizationMap()):
                      CommandOptionSpec =
  ## Builds and validates a subcommand group holding only subcommands.
  result = CommandOptionSpec(
    kind: cokSubCommandGroup, name: name, description: description,
    nameLocalizations: nameLocalizations,
    descriptionLocalizations: descriptionLocalizations, options: @subcommands)
  validateSubcommandGroup(result)

proc initChatInputCommand*(
    name, description: string;
    options: openArray[CommandOptionSpec] = @[];
    installs: set[CommandInstallContext] = {guildInstall};
    contexts: set[CommandInteractionContext] = {guildChannel};
    ack = ackManual;
    autoDeferAfterMs = 2_000;
    ephemeral = true;
    requiredBotPermissions = initDiscordBits[Permission]();
    nameLocalizations = initLocalizationMap();
    descriptionLocalizations = initLocalizationMap()): CommandSpec =
  ## Builds and validates a chat-input command schema, including any nested
  ## subcommand structure. Register it with `initCommandSet` and an explicit
  ## handler that routes on `resolveSubcommand`.
  result = CommandSpec(
    name: name, description: description, kind: ckChatInput,
    nameLocalizations: nameLocalizations,
    descriptionLocalizations: descriptionLocalizations,
    installs: installs, contexts: contexts, ack: ack,
    autoDeferAfterMs: autoDeferAfterMs, ephemeral: ephemeral,
    requiredBotPermissions: requiredBotPermissions, options: @options)
  validate(result)

proc initContextMenuCommand*(
    kind: CommandKind;
    name: string;
    installs: set[CommandInstallContext] = {guildInstall};
    contexts: set[CommandInteractionContext] = {guildChannel};
    ack = ackManual;
    autoDeferAfterMs = 2_000;
    ephemeral = true;
    requiredBotPermissions = initDiscordBits[Permission]();
    nameLocalizations = initLocalizationMap()): CommandSpec =
  ## Builds and validates a user or message context-menu command schema.
  ##
  ## Raises `CommandSpecError` when `kind` is `ckChatInput`; context-menu
  ## commands never carry a description or options.
  if kind == ckChatInput:
    raise newException(CommandSpecError,
      "initContextMenuCommand requires ckUser or ckMessage")
  result = CommandSpec(
    name: name, kind: kind, nameLocalizations: nameLocalizations,
    installs: installs, contexts: contexts, ack: ack,
    autoDeferAfterMs: autoDeferAfterMs, ephemeral: ephemeral,
    requiredBotPermissions: requiredBotPermissions)
  validate(result)

# --- Interaction locale decoding ---

proc decodeInteractionLocales*(interaction: JsonNode):
    tuple[locale, guildLocale: Option[DiscordLocale]] =
  ## Decodes the top-level `locale` and `guild_locale` interaction fields.
  ##
  ## Unknown or absent codes decode to `none`, keeping ingress tolerant of
  ## locales introduced after this build. The two fields never conflate.
  if interaction.isNil or interaction.kind != JObject:
    return
  if interaction.hasKey("locale") and interaction["locale"].kind == JString:
    result.locale = tryParseDiscordLocale(interaction["locale"].getStr())
  if interaction.hasKey("guild_locale") and
      interaction["guild_locale"].kind == JString:
    result.guildLocale =
      tryParseDiscordLocale(interaction["guild_locale"].getStr())

proc withInteractionLocales*(invocation: var CommandInvocation,
                             interaction: JsonNode) =
  ## Stores decoded interaction locales on `invocation`.
  ##
  ## The shared interaction router calls this helper after building the
  ## invocation, so it is the command locale path; `decodeAutocomplete` decodes
  ## locales through the same `decodeInteractionLocales`.
  let locales = decodeInteractionLocales(interaction)
  invocation.locale = locales.locale
  invocation.guildLocale = locales.guildLocale

func initCommandKey*(kind: CommandKind, name: string): CommandKey =
  ## Creates a command identity from its Discord kind and name.
  CommandKey(kind: kind, name: name)

func key*(spec: CommandSpec): CommandKey =
  ## Returns the identity used to register and synchronize `spec`.
  initCommandKey(spec.kind, spec.name)

func key*(invocation: CommandInvocation): CommandKey =
  ## Returns the identity used to dispatch `invocation`.
  initCommandKey(invocation.kind, invocation.name)

func `==`*(left, right: CommandKey): bool =
  ## Compares both the Discord kind and command name.
  left.kind == right.kind and left.name == right.name

func `<`*(left, right: CommandKey): bool =
  ## Orders command identities by kind and then name.
  ord(left.kind) < ord(right.kind) or
    (left.kind == right.kind and left.name < right.name)

func `<=`*(left, right: CommandKey): bool =
  ## Orders command identities by kind and then name.
  left == right or left < right

func hash*(command: CommandKey): Hash =
  ## Hashes both fields consistently with command-key equality.
  var value = hash(ord(command.kind))
  value = value !& hash(command.name)
  !$value

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

# Application commands omit UPDATE_MESSAGE because Discord permits callback type
# 7 only for component-based origins. The low-level Context retains it for
# component and modal exchanges.

proc showModal*[S](context: CommandCtx[S], modal: ModalSpec): Future[void] =
  ## Selects a validated modal schema as the initial response for later
  ## delivery. This is the standard modal path; the schema is validated before
  ## the exchange consumes response authority.
  appcontext.showModal(context.requireResponseContext(), modal)

proc showRawModal*[S](context: CommandCtx[S], body: sink JsonNode):
    Future[void] =
  ## Selects a caller-built modal JSON as the initial response, bypassing
  ## `ModalSpec` validation. Prefer `showModal` with a `ModalSpec`.
  appcontext.showRawModal(context.requireResponseContext(), body)

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

func locale*[S](context: CommandCtx[S]): Option[DiscordLocale] =
  ## Returns the invoking user's selected locale, when Discord supplied it.
  context.invocationValue.locale

func guildLocale*[S](context: CommandCtx[S]): Option[DiscordLocale] =
  ## Returns the guild's preferred locale, kept distinct from the user locale.
  context.invocationValue.guildLocale

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
  ##
  ## Every schema is run through `validate`, so the macro and explicit builder
  ## paths share one validator and an invalid command cannot reach manifest
  ## serialization or dispatch. A failure raises `CommandSpecError`.
  if specs.len != handlers.len:
    raise newException(ValueError,
      "each command schema must have exactly one handler")
  for spec in specs:
    validate(spec)
  for index in 1 ..< specs.len:
    for prior in 0 ..< index:
      if specs[index].key == specs[prior].key:
        raise newException(CommandSpecError,
          "duplicate command key '" & specs[index].name &
            "' of kind " & $specs[index].kind)
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

func notFound*(command: CommandKey): CommandResult =
  ## Creates a result for an unregistered command identity.
  CommandResult(kind: crNotFound,
    message: "unknown application command: " & command.name)

func len*[S](commands: CommandSet[S]): int =
  ## Returns the number of registered commands.
  commands.schemas.len

func specs*[S](commands: CommandSet[S]): lent seq[CommandSpec] =
  ## Borrows the deterministically ordered schemas without exposing mutation.
  commands.schemas

func find*[S](commands: CommandSet[S], command: CommandKey): int =
  ## Returns the sorted registry index for `command`, or `-1` when absent.
  for index, spec in commands.schemas:
    if spec.key == command:
      return index
  -1

func contains*[S](commands: CommandSet[S], command: CommandKey): bool =
  ## Reports whether `command` is registered.
  commands.find(command) >= 0

iterator items*[S](commands: CommandSet[S]): CommandSpec =
  ## Iterates over command schemas in deterministic kind-and-name order.
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
  let index = commands.find(invocation.key)
  if index < 0:
    return notFound(invocation.key)
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

# --- Nested subcommand routing ---

type
  SubcommandInvocation* = object ## Resolved chat-input subcommand path.
    group*: Option[string] ## Enclosing subcommand-group name, when nested.
    name*: string ## Invoked subcommand name.
    options*: JsonNode ## Leaf scalar option values as a name/value object.

func leafOptionValues(rawOptions: JsonNode): JsonNode =
  result = newJObject()
  if rawOptions.isNil or rawOptions.kind != JArray:
    return
  for option in rawOptions:
    if option.kind == JObject and option.hasKey("name") and
        option.hasKey("value"):
      result[option["name"].getStr()] = option["value"]

proc resolveSubcommand*(invocation: CommandInvocation):
    Option[SubcommandInvocation] =
  ## Reconstructs the invoked subcommand path from a chat-input invocation.
  ##
  ## The shared router stores each top-level option under its name, keeping the
  ## raw nested option array for subcommand and group options. This reads that
  ## structure and returns `none` when no subcommand was invoked. Handler
  ## routing stays explicit: switch on the returned `group` and `name`, then
  ## decode `options`.
  let options = invocation.options
  if options.isNil or options.kind != JObject or options.len != 1:
    return none(SubcommandInvocation)
  for name, node in options:
    if node.kind != JArray:
      return none(SubcommandInvocation)
    if node.len > 0 and node[0].kind == JObject and node[0].hasKey("type") and
        node[0]["type"].kind == JInt and node[0]["type"].getInt() in {1, 2}:
      for child in node:
        if child.kind == JObject and child.hasKey("name"):
          return some(SubcommandInvocation(
            group: some(name),
            name: child["name"].getStr(),
            options: leafOptionValues(child{"options"})))
      return none(SubcommandInvocation)
    return some(SubcommandInvocation(
      group: none(string),
      name: name,
      options: leafOptionValues(node)))

# --- Option-focused autocomplete ---

type
  CommandDecodeError* = object of CatchableError
    ## An interaction payload lacked required autocomplete command fields.

  AutocompleteValueKind* = enum ## Wire value type of an autocomplete choice.
    acvString, ## String suggestion value.
    acvInteger, ## Integer suggestion value.
    acvNumber ## Floating-point suggestion value.

  AutocompleteChoice* = object ## One suggestion for an autocomplete
                               ## interaction.
    name*: string ## User-facing suggestion label.
    nameLocalizations*: LocalizationMap ## Per-locale suggestion labels.
    case kind*: AutocompleteValueKind ## Value discriminator.
    of acvString:
      stringValue*: string ## Suggested string value.
    of acvInteger:
      integerValue*: int64 ## Suggested integer value.
    of acvNumber:
      numberValue*: float ## Suggested number value.

  AutocompleteRequest* = object ## Decoded option-focused autocomplete input.
    command*: CommandKey ## Command whose option is being completed.
    userId*: UserId ## Invoking user snowflake.
    guildId*: Option[GuildId] ## Guild snowflake, when in a guild.
    locale*: Option[DiscordLocale] ## Invoking user's locale.
    guildLocale*: Option[DiscordLocale] ## Guild's preferred locale.
    subcommand*: Option[SubcommandInvocation] ## Invoked subcommand path.
    options*: JsonNode ## All supplied option values by name.
    focusedName*: string ## Name of the option currently being typed.
    focusedKind*: Option[CommandOptionKind] ## Declared kind of the focused
                                            ## option, when Discord supplied a
                                            ## recognized option type.
    focusedValue*: JsonNode ## Partial value Discord sent for the focused
                            ## option.

  AutocompleteHandler*[S] = proc (services: ref S,
      request: AutocompleteRequest): Future[seq[AutocompleteChoice]]
    {.closure.} ## Produces suggestions for one focused option.

  AutocompleteRegistration[S] = object
    command: CommandKey
    group: Option[string]
    subcommand: Option[string]
    option: string
    handler: AutocompleteHandler[S]

  AutocompleteRegistry*[S] = object ## Explicit path-addressed autocomplete
                                    ## handler registry keyed by command,
                                    ## optional group/subcommand, and option.
    registrations: seq[AutocompleteRegistration[S]]

func initAutocompleteChoice*(name, value: string,
    nameLocalizations = initLocalizationMap()): AutocompleteChoice =
  ## Creates a string-valued autocomplete suggestion.
  AutocompleteChoice(kind: acvString, name: name, stringValue: value,
    nameLocalizations: nameLocalizations)

func initAutocompleteChoice*(name: string, value: int64,
    nameLocalizations = initLocalizationMap()): AutocompleteChoice =
  ## Creates an integer-valued autocomplete suggestion.
  AutocompleteChoice(kind: acvInteger, name: name, integerValue: value,
    nameLocalizations: nameLocalizations)

func initAutocompleteChoice*(name: string, value: float,
    nameLocalizations = initLocalizationMap()): AutocompleteChoice =
  ## Creates a number-valued autocomplete suggestion.
  AutocompleteChoice(kind: acvNumber, name: name, numberValue: value,
    nameLocalizations: nameLocalizations)

func toJson*(choice: AutocompleteChoice): JsonNode =
  ## Serializes one autocomplete choice with its typed value.
  result = newJObject()
  result["name"] = %choice.name
  if choice.nameLocalizations.len > 0:
    result["name_localizations"] = choice.nameLocalizations.toJson()
  case choice.kind
  of acvString: result["value"] = %choice.stringValue
  of acvInteger: result["value"] = %choice.integerValue
  of acvNumber: result["value"] = %choice.numberValue

func autocompleteResponse*(choices: openArray[AutocompleteChoice]): JsonNode =
  ## Builds a Discord type-8 autocomplete-result interaction response.
  ##
  ## Raises `CommandSpecError` when the choice count exceeds Discord's limit of
  ## 25, or when any choice name, localized name, string value, integer range,
  ## or number value violates Discord's limits, since the transport would
  ## otherwise reject the response.
  if choices.len > 25:
    raise newException(CommandSpecError,
      "autocomplete responses carry at most 25 choices")
  for choice in choices:
    if choice.name.runeLen notin 1..100:
      raise newException(CommandSpecError,
        "autocomplete choice name must be 1-100 characters")
    for locale, value in choice.nameLocalizations:
      if value.runeLen notin 1..100:
        raise newException(CommandSpecError,
          "autocomplete choice name localization for " & $locale &
            " must be 1-100 characters")
    case choice.kind
    of acvString:
      if choice.stringValue.runeLen > 100:
        raise newException(CommandSpecError,
          "autocomplete string value must be at most 100 characters")
    of acvInteger:
      if choice.integerValue < discordMinSafeInteger or
          choice.integerValue > discordMaxSafeInteger:
        raise newException(CommandSpecError,
          "autocomplete integer value is out of Discord's safe range")
    of acvNumber:
      if not isFiniteNumber(choice.numberValue):
        raise newException(CommandSpecError,
          "autocomplete number value must be finite")
      if choice.numberValue < discordMinSafeNumber or
          choice.numberValue > discordMaxSafeNumber:
        raise newException(CommandSpecError,
          "autocomplete number value is out of Discord's range")
  result = newJObject()
  result["type"] = %8
  var data = newJObject()
  var choiceArray = newJArray()
  for choice in choices:
    choiceArray.add(choice.toJson())
  data["choices"] = choiceArray
  result["data"] = data

func expectedChoiceKind(focused: Option[CommandOptionKind]):
    AutocompleteValueKind =
  if focused.isNone:
    raise newException(CommandSpecError,
      "autocomplete focused option kind is unknown")
  case focused.unsafeGet()
  of cokString: acvString
  of cokInteger: acvInteger
  of cokNumber: acvNumber
  else:
    raise newException(CommandSpecError,
      "autocomplete focused option kind must be string, integer, or number")

func autocompleteResponse*(request: AutocompleteRequest,
                           choices: openArray[AutocompleteChoice]): JsonNode =
  ## Builds a type-8 response whose choice value kinds must match the focused
  ## option's declared kind (STRING->string, INTEGER->integer, NUMBER->number).
  ##
  ## Raises `CommandSpecError` for a missing or unsupported focused kind, or a
  ## mismatched choice, before the callback is selected. This is the response
  ## builder ingress should use once it holds the decoded request.
  let expected = expectedChoiceKind(request.focusedKind)
  for choice in choices:
    if choice.kind != expected:
      raise newException(CommandSpecError,
        "autocomplete choice kind does not match the focused option kind")
  autocompleteResponse(choices)

func focusedText*(request: AutocompleteRequest): string =
  ## Returns the focused option's partial value as text.
  if request.focusedValue.isNil:
    ""
  elif request.focusedValue.kind == JString:
    request.focusedValue.getStr()
  else:
    $request.focusedValue

func initAutocompleteRegistry*[S](): AutocompleteRegistry[S] =
  ## Creates an empty autocomplete registry.
  AutocompleteRegistry[S]()

func len*[S](registry: AutocompleteRegistry[S]): int =
  ## Returns the number of registered handlers.
  registry.registrations.len

func find*[S](registry: AutocompleteRegistry[S], command: CommandKey,
              option: string, group = none(string),
              subcommand = none(string)): int =
  ## Returns the registration index for one focused option under its optional
  ## group/subcommand path, or `-1`. The path lets repeated leaf option names
  ## under different subcommands resolve to different providers.
  for index, registration in registry.registrations:
    if registration.command == command and registration.group == group and
        registration.subcommand == subcommand and
        registration.option == option:
      return index
  -1

func contains*[S](registry: AutocompleteRegistry[S], command: CommandKey,
                  option: string, group = none(string),
                  subcommand = none(string)): bool =
  ## Reports whether a handler is registered for one focused-option path.
  registry.find(command, option, group, subcommand) >= 0

proc register*[S](registry: var AutocompleteRegistry[S], command: CommandKey,
                  option: string, handler: AutocompleteHandler[S],
                  group = none(string), subcommand = none(string)) =
  ## Registers a focused-option autocomplete handler for a command path.
  ##
  ## Raises `CommandSpecError` on a nil handler or a duplicate
  ## command/group/subcommand/option key, keeping dispatch deterministic.
  if handler.isNil:
    raise newException(CommandSpecError, "autocomplete handler is nil")
  if registry.contains(command, option, group, subcommand):
    raise newException(CommandSpecError,
      "duplicate autocomplete handler for option '" & option & "'")
  registry.registrations.add(AutocompleteRegistration[S](
    command: command, group: group, subcommand: subcommand,
    option: option, handler: handler))

proc dispatch*[S](registry: AutocompleteRegistry[S], services: ref S,
                  request: AutocompleteRequest):
                  Future[seq[AutocompleteChoice]] {.async.} =
  ## Dispatches to the handler for the focused option on its resolved path.
  ##
  ## Returns an empty suggestion list when no handler matches, so ingress can
  ## still send a valid, empty type-8 response.
  if services.isNil:
    raise newException(ValueError, "autocomplete services are unavailable")
  var group = none(string)
  var subcommand = none(string)
  if request.subcommand.isSome:
    group = request.subcommand.unsafeGet().group
    subcommand = some(request.subcommand.unsafeGet().name)
  let index = registry.find(request.command, request.focusedName, group,
    subcommand)
  if index < 0:
    return @[]
  return await registry.registrations[index].handler(services, request)

proc autocompleteUserId(interaction: JsonNode): UserId =
  var text = ""
  if interaction.hasKey("member") and interaction["member"].kind == JObject and
      interaction["member"].hasKey("user") and
      interaction["member"]["user"].kind == JObject and
      interaction["member"]["user"].hasKey("id"):
    text = interaction["member"]["user"]["id"].getStr()
  elif interaction.hasKey("user") and interaction["user"].kind == JObject and
      interaction["user"].hasKey("id"):
    text = interaction["user"]["id"].getStr()
  if text.len == 0:
    raise newException(CommandDecodeError, "autocomplete user ID is missing")
  parseId(UserId, text)

proc collectAutocompleteOptions(rawOptions: JsonNode,
                                request: var AutocompleteRequest,
                                focusedCount: var int) =
  if rawOptions.isNil or rawOptions.kind != JArray:
    return
  for option in rawOptions:
    if option.kind != JObject or not option.hasKey("name"):
      continue
    let name = option["name"].getStr()
    if option.hasKey("value"):
      request.options[name] = option["value"]
    let focused = option.hasKey("focused") and
      option["focused"].kind == JBool and option["focused"].getBool()
    if focused:
      inc focusedCount
      request.focusedName = name
      if option.hasKey("value"):
        request.focusedValue = option["value"]
      if option.hasKey("type") and option["type"].kind == JInt:
        try:
          request.focusedKind = some(toCommandOptionKind(option["type"].getInt()))
        except ValueError:
          discard

proc decodeAutocomplete*(interaction: JsonNode): AutocompleteRequest =
  ## Decodes a Discord type-4 autocomplete interaction into a typed request.
  ##
  ## Walks any subcommand or group path, records every supplied option value,
  ## and isolates the focused option's name, kind, and partial value. Raises
  ## `CommandDecodeError` when the payload is not an application-command
  ## autocomplete interaction or lacks required identity fields. Ingress owns
  ## the transport: pass the verified interaction JSON, then reply with
  ## `autocompleteResponse` over the dispatched suggestions.
  if interaction.isNil or interaction.kind != JObject or
      not interaction.hasKey("type") or interaction["type"].kind != JInt or
      interaction["type"].getInt() != 4:
    raise newException(CommandDecodeError,
      "interaction is not an application-command autocomplete")
  if not interaction.hasKey("data") or interaction["data"].kind != JObject:
    raise newException(CommandDecodeError, "autocomplete data is missing")
  let data = interaction["data"]
  if not data.hasKey("name") or data["name"].kind != JString:
    raise newException(CommandDecodeError,
      "autocomplete command name is missing")
  if not data.hasKey("type") or data["type"].kind != JInt:
    raise newException(CommandDecodeError,
      "autocomplete command type is missing")

  result.options = newJObject()
  result.focusedValue = newJNull()
  result.command = initCommandKey(toCommandKind(data["type"].getInt()),
    data["name"].getStr())
  let locales = decodeInteractionLocales(interaction)
  result.locale = locales.locale
  result.guildLocale = locales.guildLocale
  result.userId = autocompleteUserId(interaction)
  if interaction.hasKey("guild_id") and interaction["guild_id"].kind == JString:
    result.guildId = some(parseId(GuildId, interaction["guild_id"].getStr()))

  # data.options must be present; malformed wire JSON must never defect.
  if not data.hasKey("options") or data["options"].kind != JArray:
    raise newException(CommandDecodeError,
      "autocomplete data.options is missing or not an array")
  var leaf = data["options"]
  if leaf.len == 1 and leaf[0].kind == JObject and leaf[0].hasKey("type") and
      leaf[0]["type"].kind == JInt and leaf[0]["type"].getInt() in {1, 2}:
    let top = leaf[0]
    let topName = top{"name"}
    if topName.isNil or topName.kind != JString:
      raise newException(CommandDecodeError,
        "autocomplete subcommand name is missing")
    if top["type"].getInt() == 2:
      let inner = top{"options"}
      if inner.isNil or inner.kind != JArray or inner.len < 1 or
          inner[0].kind != JObject:
        raise newException(CommandDecodeError,
          "autocomplete subcommand group has no subcommand")
      let sub = inner[0]
      let subName = sub{"name"}
      if subName.isNil or subName.kind != JString:
        raise newException(CommandDecodeError,
          "autocomplete subcommand name is missing")
      let subOptions = sub{"options"}
      if subOptions.isNil or subOptions.kind != JArray:
        raise newException(CommandDecodeError,
          "autocomplete subcommand options are missing or not an array")
      result.subcommand = some(SubcommandInvocation(
        group: some(topName.getStr()),
        name: subName.getStr(),
        options: result.options))
      leaf = subOptions
    else:
      let subOptions = top{"options"}
      if subOptions.isNil or subOptions.kind != JArray:
        raise newException(CommandDecodeError,
          "autocomplete subcommand options are missing or not an array")
      result.subcommand = some(SubcommandInvocation(
        group: none(string),
        name: topName.getStr(),
        options: result.options))
      leaf = subOptions
  var focusedCount = 0
  collectAutocompleteOptions(leaf, result, focusedCount)
  if focusedCount != 1:
    raise newException(CommandDecodeError,
      "autocomplete requires exactly one focused option")
