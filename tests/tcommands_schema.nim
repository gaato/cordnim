## Command macro schema and typed dispatch tests.

import std/[json, options, strutils, unicode, unittest]
import chronos

import cordnim/commands
import cordnim/core/[bits, ids, permissions]

type
  Environment = enum
    staging
    production

  TestServices = object
    prefix: string

proc deploy(ctx: CommandCtx[TestServices], environment: Environment,
            replicas: range[1..20], dryRun = false,
            note: Option[string] = none(string)): CommandResult
    {.discordCommand(
      name = "deploy",
      description = "Deploy an application",
      installs = {guildInstall, userInstall},
      contexts = {guildChannel, privateChannel},
      ack = ackAutoDefer,
      autoDeferAfterMs = 1_500,
      ephemeral = true,
      requiredBotPermissions = {
        Permission.sendMessages, Permission.attachFiles
      }
    ).} =
  let suffix = if note.isSome: ":" & note.get() else: ""
  succeeded(ctx.services.prefix & $environment & ":" & $replicas &
    ":" & $dryRun & suffix)

proc about(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(
      name = "about",
      description = "Show application information",
      contexts = {botDm, guildChannel}
    ).} =
  succeeded(ctx.services.prefix & $ctx.invocation.userId)

proc asyncStatus(ctx: CommandCtx[TestServices], value: string):
    Future[CommandResult]
    {.async, discordCommand(
      name = "async_status",
      description = "Exercise an asynchronous command"
    ).} =
  await sleepAsync(0.milliseconds)
  return succeeded(ctx.services.prefix & value)

proc localized(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(
      name = "配備",
      description = "アプリケーションを配備します"
    ).} =
  succeeded(ctx.services.prefix)

proc inspectSlash(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(name = "inspect", description = "Inspect a resource").} =
  succeeded("slash")

proc inspectUser(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(name = "inspect", kind = ckUser).} =
  succeeded("user")

proc inspectMessage(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(name = "inspect", kind = ckMessage).} =
  succeeded("message")

proc inspectMixedCase(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(name = "Inspect User", kind = ckUser).} =
  succeeded("mixed")

proc duplicateInspect(ctx: CommandCtx[TestServices]): CommandResult
    {.discordCommand(name = "inspect", description = "Duplicate key").} =
  succeeded()

proc badOrder(ctx: CommandCtx[TestServices], optional = "x",
              required: int): CommandResult
    {.discordCommand(name = "bad_order", description = "Bad ordering").} =
  succeeded()

static:
  doAssert not compiles(commandSet(inspectSlash, duplicateInspect))
  # Discord requires required options to precede optional ones.
  doAssert not compiles(commandSet(badOrder))

let commandsUnderTest = commandSet(deploy, about)

suite "command compiler":
  test "accepts Discord-supported uncased Unicode command metadata":
    let localizedCommands = commandSet(localized)
    check localizedCommands.specs[0].name == "配備"
    check localizedCommands.specs[0].description == "アプリケーションを配備します"

  test "sorts explicit registrations and generates option schema":
    check commandsUnderTest.len == 2
    check commandsUnderTest.specs[0].name == "about"
    check commandsUnderTest.specs[1].name == "deploy"

    let deploySpec = commandsUnderTest.specs[1]
    check deploySpec.installs == {guildInstall, userInstall}
    check deploySpec.contexts == {guildChannel, privateChannel}
    check deploySpec.ack == ackAutoDefer
    check deploySpec.autoDeferAfterMs == 1_500
    check deploySpec.requiredBotPermissions.contains(Permission.sendMessages)
    check deploySpec.requiredBotPermissions.contains(Permission.attachFiles)
    check deploySpec.options.len == 4
    check deploySpec.options[0].kind == cokString
    check deploySpec.options[0].choices.len == 2
    check deploySpec.options[1].kind == cokInteger
    check deploySpec.options[1].minimumInt == some(1'i64)
    check deploySpec.options[1].maximumInt == some(20'i64)
    check not deploySpec.options[2].required
    check deploySpec.options[2].name == "dry_run"
    check not deploySpec.options[3].required

  test "keys commands by kind and permits context-menu display names":
    let commands = commandSet(
      inspectMessage, inspectMixedCase, inspectUser, inspectSlash)
    check commands.len == 4
    check commands.specs[0].key == initCommandKey(ckChatInput, "inspect")
    check commands.specs[1].key == initCommandKey(ckUser, "Inspect User")
    check commands.specs[2].key == initCommandKey(ckUser, "inspect")
    check commands.specs[3].key == initCommandKey(ckMessage, "inspect")

    let userResult = waitFor commands.dispatch(
      TestServices(),
      CommandInvocation(
        kind: ckUser,
        name: "inspect",
        options: newJObject(),
        userId: toId(UserId, 42)
      )
    )
    let messageResult = waitFor commands.dispatch(
      TestServices(),
      CommandInvocation(
        kind: ckMessage,
        name: "inspect",
        options: newJObject(),
        userId: toId(UserId, 42)
      )
    )
    check userResult.message == "user"
    check messageResult.message == "message"

  test "decodes typed values and applies defaults":
    let invocation = CommandInvocation(
      name: "deploy",
      options: %*{
        "environment": "staging",
        "replicas": 3
      },
      userId: toId(UserId, 42),
      guildId: some(toId(GuildId, 7))
    )
    let result = waitFor commandsUnderTest.dispatch(
      TestServices(prefix: "run:"), invocation)
    check result.kind == crSucceeded
    check result.message == "run:staging:3:false"

  test "reports a missing or out-of-range option without invoking handler":
    let missing = waitFor commandsUnderTest.dispatch(
      TestServices(),
      CommandInvocation(
        name: "deploy",
        options: %*{"environment": "production"},
        userId: toId(UserId, 42)
      )
    )
    check missing.kind == crInvalidOptions
    check "replicas" in missing.message

    let outside = waitFor commandsUnderTest.dispatch(
      TestServices(),
      CommandInvocation(
        name: "deploy",
        options: %*{"environment": "production", "replicas": 21},
        userId: toId(UserId, 42)
      )
    )
    check outside.kind == crInvalidOptions
    check "outside" in outside.message

  test "returns an explicit not-found result":
    let result = waitFor commandsUnderTest.dispatch(
      TestServices(),
      CommandInvocation(
        name: "missing",
        options: newJObject(),
        userId: toId(UserId, 42)
      )
    )
    check result.kind == crNotFound

  test "awaits a native Chronos command handler":
    let asyncCommands = commandSet(asyncStatus)
    let result = waitFor asyncCommands.dispatch(
      TestServices(prefix: "async:"),
      CommandInvocation(
        name: "async_status",
        options: %*{"value": "ready"},
        userId: toId(UserId, 42)
      )
    )
    check result.message == "async:ready"

suite "Discord locales":
  test "parses and rejects locale wire codes exactly":
    check parseDiscordLocale("en-US") == dlEnglishUs
    check parseDiscordLocale("es-419") == dlSpanishLatam
    check isDiscordLocale("zh-CN")
    check not isDiscordLocale("xx")
    check not isDiscordLocale("en_US")
    expect ValueError:
      discard parseDiscordLocale("en_US")

  test "localization maps reject duplicate locales and stay sorted":
    expect CommandSpecError:
      discard initLocalizationMap({dlJapanese: "配備", dlJapanese: "重複"})
    let map = initLocalizationMap({
      dlJapanese: "配備", dlEnglishUs: "deploy", dlGerman: "bereitstellen"
    })
    check map.len == 3
    check map.getOrDefault(dlJapanese) == "配備"
    check dlGerman in map
    var codes: seq[string]
    for locale, value in map:
      codes.add $locale
    # Sorted by wire code: de, en-US, ja.
    check codes == @["de", "en-US", "ja"]
    check map.toJson() == %*{
      "de": "bereitstellen", "en-US": "deploy", "ja": "配備"
    }

suite "explicit option builders":
  test "channel types are valid only on channel options":
    let channel = initCommandOption(cokChannel, "target", "Pick a channel",
      channelTypes = [cctGuildText, cctGuildVoice])
    check channel.channelTypes == @[cctGuildText, cctGuildVoice]
    expect CommandSpecError:
      discard initCommandOption(cokString, "s", "Not a channel",
        channelTypes = [cctGuildText])

  test "autocomplete excludes choices and non-scalar kinds":
    let auto = initCommandOption(cokString, "query", "Search",
      autocomplete = true)
    check auto.autocomplete
    expect CommandSpecError:
      discard initCommandOption(cokString, "q", "Bad",
        autocomplete = true, choices = [commandChoice("a", "a")])
    expect CommandSpecError:
      discard initCommandOption(cokBoolean, "flag", "Bad", autocomplete = true)

  test "integer ranges reject non-integer kinds":
    expect CommandSpecError:
      discard initCommandOption(cokString, "s", "Bad",
        minimumInt = some(1'i64))

suite "typed choices and numeric ranges":
  test "choice value kind must match the option kind":
    let stringChoice = initCommandOption(cokString, "mood", "Mood",
      choices = @[commandChoice("happy", "happy")])
    check stringChoice.choices[0].kind == ccvString
    let intChoice = initCommandOption(cokInteger, "count", "Count",
      choices = @[commandChoice("one", 1'i64)])
    check intChoice.choices[0].kind == ccvInteger
    check intChoice.choices[0].integerValue == 1
    expect CommandSpecError:
      discard initCommandOption(cokString, "s", "Bad",
        choices = @[commandChoice("n", 1'i64)])
    expect CommandSpecError:
      discard initCommandOption(cokNumber, "n", "Bad",
        choices = @[commandChoice("s", "text")])

  test "choice values respect Discord bounds and finiteness":
    expect CommandSpecError:
      discard initCommandOption(cokString, "s", "Bad",
        choices = @[commandChoice("long", repeat('a', 101))])
    expect CommandSpecError:
      discard initCommandOption(cokInteger, "n", "Bad",
        choices = @[commandChoice("big", 9007199254740992'i64)])
    expect CommandSpecError:
      discard initCommandOption(cokNumber, "n", "Bad",
        choices = @[commandChoice("nan", NaN)])
    expect CommandSpecError:
      discard initCommandOption(cokNumber, "n", "Bad",
        choices = @[commandChoice("huge", 1e300)])

  test "numeric and length ranges must be ordered and in bounds":
    expect CommandSpecError:
      discard initCommandOption(cokInteger, "n", "N",
        minimumInt = some(5'i64), maximumInt = some(1'i64))
    expect CommandSpecError:
      discard initCommandOption(cokInteger, "n", "N",
        minimumInt = some(9007199254740992'i64))
    expect CommandSpecError:
      discard initCommandOption(cokNumber, "n", "N",
        minimumNumber = some(5.0), maximumNumber = some(1.0))
    expect CommandSpecError:
      discard initCommandOption(cokNumber, "n", "N",
        minimumNumber = some(Inf))
    expect CommandSpecError:
      discard initCommandOption(cokNumber, "n", "N",
        minimumNumber = some(1e300)) # finite but beyond 2^53
    expect CommandSpecError:
      discard initCommandOption(cokString, "s", "S",
        minLength = some(10), maxLength = some(5))
    expect CommandSpecError:
      discard initCommandOption(cokString, "s", "S", maxLength = some(7000))
    # 2^53 is the inclusive NUMBER boundary and must be accepted.
    let bounded = initCommandOption(cokNumber, "n", "N",
      maximumNumber = some(9007199254740992.0))
    check bounded.maximumNumber == some(9007199254740992.0)

suite "localized name rules":
  test "localized option names follow the naming rule":
    expect CommandSpecError:
      discard initCommandOption(cokString, "s", "S",
        nameLocalizations = initLocalizationMap({dlEnglishUs: "Bad Name"}))

  test "sibling localized names must be unique per locale":
    let ok = initChatInputCommand("greet", "Greet", options = @[
      initCommandOption(cokString, "name", "Name",
        nameLocalizations = initLocalizationMap({dlFrench: "nom"})),
      initCommandOption(cokString, "city", "City",
        nameLocalizations = initLocalizationMap({dlFrench: "ville"}))
    ])
    check ok.options.len == 2
    expect CommandSpecError:
      discard initChatInputCommand("dup", "Dup", options = @[
        initCommandOption(cokString, "first", "First",
          nameLocalizations = initLocalizationMap({dlFrench: "second"})),
        initCommandOption(cokString, "second", "Second")
      ])

suite "Discord chat-input name grammar":
  test "accepts the ASCII apostrophe in default and localized names":
    check validChatInputName("l'ami")
    let option = initCommandOption(cokString, "opt", "Opt",
      nameLocalizations = initLocalizationMap({dlEnglishUs: "l'ami"}))
    check option.nameLocalizations.getOrDefault(dlEnglishUs) == "l'ami"

  test "accepts Unicode number letters and others but not cased forms":
    check validChatInputName("x" & $Rune(0x00B2)) # No superscript two
    check validChatInputName("x" & $Rune(0x2170)) # Nl small roman one
    check validChatInputName("x" & $Rune(0x3007)) # Nl ideographic zero
    # U+216B (ROMAN NUMERAL TWELVE) is cased with a lowercase variant U+217B.
    check not validChatInputName("x" & $Rune(0x216B))

  test "accepts non-ASCII Unicode digits":
    check validChatInputName("cmd" & $Rune(0x0665)) # Arabic-Indic digit five
    check validChatInputName("cmd" & $Rune(0xFF15)) # fullwidth digit five

  test "accepts Devanagari and Thai names with script marks":
    # Includes the combining virama U+094D, neither a letter nor a number.
    check validChatInputName("हिन्दी")
    # Includes the combining tone mark U+0E49.
    check validChatInputName("น้ำ")
    let option = initCommandOption(cokString, "opt", "Opt",
      nameLocalizations = initLocalizationMap({dlHindi: "हिन्दी"}))
    check dlHindi in option.nameLocalizations

  test "uses Script property, not Unicode blocks, for Devanagari and Thai":
    # U+0951..U+0954 are Script=Inherited Vedic marks (category Mn), not
    # Script=Devanagari, so they are rejected despite sitting in the block.
    check not validChatInputName("x" & $Rune(0x0951))
    check not validChatInputName("x" & $Rune(0x0954))
    # Devanagari Extended (U+A8E1 combining mark) and Extended-A (U+11B00 head
    # mark) are Script=Devanagari outside the base block and are accepted.
    check validChatInputName("x" & $Rune(0xA8E1))
    check validChatInputName("x" & $Rune(0x11B00))
    # Thai punctuation (U+0E4F, fongman) is Script=Thai and is accepted.
    check validChatInputName("x" & $Rune(0x0E4F))

  test "accepts letters added after the standard library's Unicode version":
    # U+10E80 (YEZIDI LETTER ELIF) was added in Unicode 13.0; the stdlib's
    # isAlpha (Unicode 12.0) misses it, but the generated 15.1 table accepts it.
    check validChatInputName("x" & $Rune(0x10E80))

  test "still rejects uppercase and titlecase characters":
    check not validChatInputName("Name")
    check not validChatInputName("na" & $Rune(0x0130) & "ve") # dotted capital I
    check not validChatInputName($Rune(0x01C5)) # titlecase Dž

# --- Additional hardening: validation completeness, uint, attachment ---

proc bigRange(ctx: CommandCtx[TestServices],
              amount: range[0'i64 .. 9007199254740992'i64]): CommandResult
    {.discordCommand(name = "big", description = "Out-of-range integer").} =
  succeeded()

proc uintOpt(ctx: CommandCtx[TestServices], count: uint): CommandResult
    {.discordCommand(name = "u", description = "Unsigned option").} =
  succeeded()

proc uint64Opt(ctx: CommandCtx[TestServices], count: uint64): CommandResult
    {.discordCommand(name = "u64", description = "Unsigned option").} =
  succeeded()

proc uint32Opt(ctx: CommandCtx[TestServices], count: uint32): CommandResult
    {.discordCommand(name = "u32", description = "Unsigned option").} =
  succeeded()

proc withAttachment(ctx: CommandCtx[TestServices], file: AttachmentId,
                    extra = none(AttachmentId)): CommandResult
    {.discordCommand(name = "upload", description = "Upload a file").} =
  succeeded($file.toUint64())

proc withOptionalAttachment(ctx: CommandCtx[TestServices],
                            file = none(AttachmentId)): CommandResult
    {.discordCommand(
      name = "optional_upload",
      description = "Optionally upload a file"
    ).} =
  succeeded(if file.isSome: $file.get().toUint64() else: "none")

static:
  # uint/uint64 exceed Discord's signed safe range and overflow BiggestInt.
  doAssert not compiles(commandSet(uintOpt))
  doAssert not compiles(commandSet(uint64Opt))
  # Bounded unsigned types that fit the safe range still compile.
  doAssert compiles(commandSet(uint32Opt))

let attachmentCommands = commandSet(withAttachment)
let optionalAttachmentCommands = commandSet(withOptionalAttachment)

proc bulkChoices(count, lastValueLen: int): seq[CommandChoice] =
  for _ in 0 ..< count - 1:
    result.add(commandChoice(repeat("n", 100), repeat("v", 100)))
  result.add(commandChoice(repeat("n", 100), repeat("v", lastValueLen)))

proc budgetSpec(lastValueLen: int): CommandSpec =
  initChatInputCommand("c", "d", options = @[
    initCommandOption(cokString, "aa", "d", choices = bulkChoices(25, 100)),
    initCommandOption(cokString, "bb", "d",
      choices = bulkChoices(15, lastValueLen))
  ])

suite "command validation completeness":
  test "initCommandSet validates macro-generated specs before use":
    expect CommandSpecError:
      discard commandSet(bigRange)

  test "commandCharBudget counts localization max and choice values":
    let spec = initChatInputCommand("cmd", "hello", options = @[
      initCommandOption(cokString, "opt", "d",
        choices = @[commandChoice("c", "vvvv")],
        nameLocalizations = initLocalizationMap({dlJapanese: "あいうえお"}))
    ])
    # command 3+5, option max(3,5)+1, choice 1+4 = 8 + 6 + 5.
    check commandCharBudget(spec) == 19

  test "enforces the 8000-character aggregate budget":
    let atLimit = budgetSpec(92)
    check commandCharBudget(atLimit) == 8000
    expect CommandSpecError:
      discard budgetSpec(93) # 8001

  test "private-channel context requires user install":
    check initChatInputCommand("ok", "d",
      contexts = {guildChannel, privateChannel},
      installs = {guildInstall, userInstall}).contexts ==
        {guildChannel, privateChannel}
    expect CommandSpecError:
      discard initChatInputCommand("bad", "d",
        contexts = {privateChannel}, installs = {guildInstall})

suite "attachment options":
  test "compile, serialize as type 11, and decode a snowflake":
    check attachmentCommands.specs[0].options[0].kind == cokAttachment
    check attachmentCommands.specs[0].options[1].kind == cokAttachment
    check not attachmentCommands.specs[0].options[1].required
    let manifest = initCommandManifest(attachmentCommands, "2026-07-12")
    let option = manifest.toJson()["commands"][0]["options"][0]
    check option["type"].getInt() == 11
    let result = waitFor attachmentCommands.dispatch(
      TestServices(),
      CommandInvocation(
        name: "upload",
        options: %*{"file": "123456789"},
        userId: toId(UserId, 1)
      )
    )
    check result.kind == crSucceeded
    check result.message == "123456789"

# Only exact Discord ID basenames are recognized.

type
  SuperUserId = distinct uint64
  MyAttachmentId = distinct uint64

proc superIdOpt(ctx: CommandCtx[TestServices], who: SuperUserId): CommandResult
    {.discordCommand(name = "super", description = "Suffix id type").} =
  succeeded()

proc myAttachmentOpt(ctx: CommandCtx[TestServices],
                     file: MyAttachmentId): CommandResult
    {.discordCommand(name = "myatt", description = "Suffix id type").} =
  succeeded()

static:
  # endsWith-style matching would misclassify these user-defined distinct types.
  doAssert not compiles(commandSet(superIdOpt))
  doAssert not compiles(commandSet(myAttachmentOpt))

suite "explicit spec invariants":
  test "rejects empty install or interaction context sets":
    expect CommandSpecError:
      discard initChatInputCommand("x", "d", installs = {})
    expect CommandSpecError:
      discard initChatInputCommand("x", "d", contexts = {})
    # A normal command with the builder defaults is accepted.
    check initChatInputCommand("x", "d").installs == {guildInstall}

suite "dispatch is defect-free on malformed options":
  test "nil or non-object options become invalidOptions, not a defect":
    # A required-option command with nil options.
    let nilResult = waitFor commandsUnderTest.dispatch(
      TestServices(),
      CommandInvocation(name: "deploy", userId: toId(UserId, 1)))
    check nilResult.kind == crInvalidOptions
    # Non-object options (a JSON array).
    let badResult = waitFor commandsUnderTest.dispatch(
      TestServices(),
      CommandInvocation(name: "deploy", options: %*[1, 2, 3],
        userId: toId(UserId, 1)))
    check badResult.kind == crInvalidOptions
    # A command with no options still succeeds with nil options.
    let okResult = waitFor commandsUnderTest.dispatch(
      TestServices(prefix: "p:"),
      CommandInvocation(name: "about", userId: toId(UserId, 5)))
    check okResult.kind == crSucceeded

  test "optional-only commands reject a present non-object option set":
    let result = waitFor optionalAttachmentCommands.dispatch(
      TestServices(),
      CommandInvocation(name: "optional_upload", options: %*[1, 2],
        userId: toId(UserId, 1)))
    check result.kind == crInvalidOptions
