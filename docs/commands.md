# Commands

Cordnim compiles typed Nim procedures into Discord application command schemas
and dispatch tables. Macro expansion creates values and handler adapters. It
does not register commands, open a socket, or read credentials.

## Declare a command

`discordCommand` supplies the fields that do not come from the Nim signature.
The procedure parameters become scalar command options.

```nim
import chronos
import cordnim/[app, commands]

type Services = object
  greeting: string

proc hello(ctx: CommandCtx[Services], name: string): Future[CommandResult]
    {.async, discordCommand(
      name = "hello",
      description = "Greet one person",
      installs = {guildInstall, userInstall},
      contexts = {guildChannel, botDm, privateChannel}
    ).} =
  await ctx.reply(ctx.services.greeting & ", " & name)
  return succeeded()

let commands = commandSet(hello)
```

`commandSet` rejects duplicate `(kind, name)` keys. A chat-input command, user
command, and message command may share a name because Discord treats their kinds
as separate identities.

The compiler validates the generated `CommandSpec`. Invalid descriptions,
option ordering, localizations, choices, or numeric bounds fail during program
construction or macro expansion, before command synchronization can make a
network request.

## Names, options, and localization

Chat-input command, subcommand, and option names follow Discord's Unicode name
rule. Cordnim uses a pinned Unicode property table for letters, numbers,
Devanagari, and Thai script characters, then enforces lowercase forms where a
lowercase mapping exists. User and message command names may contain spaces and
mixed case.

`tools/gen_name_grammar.py` records the Unicode 15.1 data version and the digest
of the official Script-property source. `nimble schemaCheck` verifies the
checked-in range table without downloading mutable Unicode data.

`LocalizationMap` stores known Discord locales in deterministic locale-code
order. Localized command and option names follow the same rule as the default
name. Cordnim also checks effective sibling names per locale, including a
localized name that collides with another sibling's default.

`CommandChoice` and `AutocompleteChoice` keep string, integer, and number values
as distinct variants. Integer values use Discord's safe integer bounds. Number
values reject infinities, NaN, and values outside Discord's documented range.
String lengths count Unicode characters where Discord defines a character
limit. A chat-input schema also has an 8,000-character aggregate budget across
command, option, subcommand, group, and choice fields. For a localized field,
the budget counts the longest of its default and localized values.

Use `initCommandOption`, `initSubcommand`, and `initSubcommandGroup` when a
command needs an explicit nested schema. A group contains subcommands, and a
subcommand contains scalar options. Cordnim rejects deeper or mixed structural
nesting.

## Autocomplete routes

Autocomplete registration includes the complete option path. Repeated leaf
option names under different subcommands can use different handlers.

```nim
import std/options

dispatcher.registerAutocomplete(
  initCommandKey(ckChatInput, "admin"),
  "query",
  suggestUsers,
  group = some("members"),
  subcommand = some("find")
)
```

Discord must mark one leaf option as focused. Cordnim rejects payloads
with zero or several focused options. The interaction runtime applies the same
acknowledgement deadline and delivery rules to autocomplete over HTTP and
Gateway ingress.

## Manifest and synchronization

`initCommandManifest` produces a deterministic document from a `CommandSet`.
The manifest records the pinned Discord schema revision and Cordnim runtime
metadata alongside the command payload. `manifestHash` changes when a managed
field changes.

The operator CLI keeps state-changing synchronization behind two flags:

```fish
cordnim commands diff --current current.json --desired manifest.json
cordnim commands sync --manifest manifest.json --application 123 --dry-run
cordnim commands sync --manifest manifest.json --application 123 --apply --yes
```

Global synchronization sends `integration_types` and `contexts`. Guild command
endpoints omit those global-only fields. Normalization removes Discord-owned IDs,
versions, localized response projections, and documented default values before
diffing. List requests set `with_localizations=true`, so the comparison uses the
complete localization dictionaries instead of the requester's localized
projection.

The CLI reads `DISCORD_BOT_TOKEN` or `DISCORD_TOKEN` from the environment or a
literal `.env` assignment. It parses the file as text and never executes it.

## Dispatch and response ownership

`CommandCtx[S]` borrows the service allocation owned by `DiscordApp[S]`.
Copying a command context does not copy `S` or create another response right.

The transport decoder distinguishes an omitted option array from a present but
malformed one. Generated adapters make the same distinction for their JSON
object input. Wrong container types, malformed children, duplicate names, and
wrong scalar kinds become `InteractionDecodeError` or `crInvalidOptions`; they
never fall through to a handler as an empty option set.

Handlers may return `CommandResult`, select a response through the context, or
use both. A selected context response controls the wire callback. Middleware can
still inspect the returned result.

`ackAutoDefer` starts a deadline-clamped defer task. The router retains that task
and any handler tail in its task scope. `close` cancels and joins the scope. A
deferred original-message edit waits until the ingress confirms the initial
callback delivery.

Command handler exceptions cross the application boundary as redacted error
categories. Failure observers receive correlation IDs and phases, without the
handler message, interaction token, or request body.

Discord's current command fields and limits remain authoritative. See the
[Application Commands documentation](https://docs.discord.com/developers/interactions/application-commands)
when adding a new option or command field.
