# cordnim

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gaato/cordnim)

cordnim is a Discord application library for Nim 2.2. It provides typed slash
commands, components and modals, HTTP and Gateway interactions, rate-limited
REST calls, and resumable Gateway shards.

cordnim 0.1.0 is a preview release. Public APIs may change between releases.

## Packages

| Import | Purpose |
| --- | --- |
| `cordnim` | Build applications, commands, components, modals, and interaction handlers |
| `cordnim/bot` | Wire a complete Gateway bot with owned REST, interactions, and typed events |
| `cordnim/api` | Call Discord REST endpoints with typed request and response values |
| `cordnim/models` | Decode Discord resources while retaining unknown fields |
| `cordnim/gateway` | Run Gateway sessions, shards, event dispatch, and caching |
| `cordnim/testing` | Test applications with scripted requests and a fake clock |
| `cordnim/raw` | Access generated HTTP v10 routes when no high-level wrapper exists |

Voice support lives in the separate `cordnim_voice` package. See the
[architecture guide](docs/architecture.md) for the full module layout.

## Requirements

- Nim 2.2.10 or a newer 2.2 patch release
- ORC (`--mm:orc`)
- Chronos 4.2 or 4.3
- libsodium when building the optional HTTP verifier with
  `-d:cordnimSodium`

Nimble declares package dependencies. `atlas.lock` pins the development
checkouts under `deps/`.

## Run an HTTP interaction app

This example reads the Discord application public key from the environment and
serves `/interactions` on port 8080. `app.run()` starts the attached services and
shuts them down together.

```nim
import std/os

import chronos
import cordnim

type Services = object
  greeting: string

proc hello(ctx: CommandCtx[Services], name: string): Future[CommandResult]
    {.async, discordCommand(
      name = "hello",
      description = "Say hello",
      installs = {guildInstall, userInstall},
      contexts = {guildChannel, botDm, privateChannel}
    ).} =
  await ctx.reply(ctx.services.greeting & ", " & name)
  return succeeded()

let app = newDiscordApp(
  Services(greeting: "Hello"),
  initAppConfig(ingressHttp),
  commandSet(hello)
)

let publicKey = parseEd25519PublicKey(getEnv("DISCORD_PUBLIC_KEY"))
discard newInteractionHttpRuntime(
  app,
  initTAddress("127.0.0.1:8080"),
  sodiumVerificationConfig(publicKey)
)

waitFor app.run()
```

Build the example with the libsodium adapter enabled:

```fish
nim c -r --mm:orc -d:cordnimSodium bot.nim
```

Use Gateway ingress for event subscriptions, or combine it with HTTP ingress in
the same app. `ctx.reply` sends the initial interaction response;
`ctx.editOriginal` and `ctx.followup` are available afterward. The
[interactions guide](docs/interactions.md) covers routing, deferral, and response
lifecycle in detail.

## Run a Gateway bot

`newGatewayBotRuntime` owns REST bootstrap, WebSocket shards, interaction
callbacks, and shutdown. Register typed event and interaction handlers before
calling `app.run()`.

```nim
import std/os

import chronos
import cordnim
import cordnim/bot

type Services = object
  greeting: string

let app = newDiscordApp(
  Services(greeting: "Hello"),
  initAppConfig(
    ingressGateway,
    gatewaySubscriptions({giGuildMessages, giMessageContent})
  ),
  initCommandSet[Services]()
)

let token = initSecret[BotToken](getEnv("DISCORD_BOT_TOKEN"))
let bot = newGatewayBotRuntime(app, token, singleProcessGateway())

bot.events.onMessageCreate proc(
    ctx: GatewayEventContext[Services]; message: Message
): Future[void] {.async.} =
  echo ctx.services.greeting, ": ", message.content

waitFor app.run()
```

`singleProcessGateway()` guards the in-memory coordination boundary. Supply
`externalGateway(yourCoordination)` before setting `processCount` above one.
The event policy, shard plan, runner timing, observers, and production adapters
remain available through `initGatewayBotOptions`.

## Components and persistent routes

Components V2 builders validate message trees before serialization. Modal forms
report all validation problems at once. `TypedRouteCodec[T]` signs versioned,
expiring `custom_id` payloads, so component routes can survive a restart when
the next process has the same keys. Use `Collector[T]` for short-lived flows
that do not need persistence.

## Operator CLI

The `cordnim` executable supports schema inspection, offline checks, manifest
validation, and command synchronization.

```fish
cordnim schema
cordnim doctor --offline
cordnim manifest validate manifest.json
cordnim commands diff --current current.json --desired manifest.json
cordnim commands sync --manifest manifest.json --application 123 --dry-run
```

Command synchronization changes Discord state only when you pass both
`--apply` and `--yes`. The CLI reads `DISCORD_BOT_TOKEN` or `DISCORD_TOKEN`
from the environment or a literal `.env` assignment.

```fish
cp .env.example .env
chmod 600 .env
```

## Development

Restore the pinned dependencies before building a fresh checkout:

```fish
atlas --noexec rep atlas.lock
nimble apiCheck
nimble test
nimble schemaCheck
nimble docs
```

The guides cover [architecture](docs/architecture.md),
[semantic REST APIs](docs/api.md),
[commands](docs/commands.md), [components and forms](docs/components.md),
[interactions](docs/interactions.md), [REST](docs/rest.md),
[Gateway operation](docs/gateway.md), [raw schema generation](docs/raw-schema.md),
[testing](docs/testing.md), [runtime operations](docs/operations.md), and
[security](docs/security.md).
