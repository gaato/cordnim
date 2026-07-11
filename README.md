# cordnim

cordnim is a typed Discord application runtime for Nim 2.2. The 0.1 release
can run HTTP interactions end to end with Chronos. It also provides Discord
REST scheduling, Gateway WebSocket transport, protocol codecs, and state
machines for applications that need lower-level control.

The API remains unstable before 1.0.

## Package map

| Import | Purpose |
| --- | --- |
| `cordnim` | Typed IDs and secrets, commands, components, and the webhook-only runtime |
| `cordnim/interactions` | Interaction exchange, HTTP server, router, verification, and webhook responses |
| `cordnim/rest` | Chronos HTTP transport, rate-limit scheduler, request deadlines, and checked errors |
| `cordnim/gateway` | WebSocket transport plus Gateway v10 payload, session, heartbeat, identify, shard, and reconnect state |
| `cordnim/raw` | Generated Discord HTTP v10 models, route metadata, and the generic request escape hatch |

Import the lower-level modules by name. Their wire types stay out of the main
`cordnim` namespace.

The 0.1 release does not include a complete Gateway shard runner. The transport
and state machines are present; an owner still needs to join HELLO, heartbeat,
IDENTIFY or RESUME, compression, reconnect, and event dispatch. Voice media,
streaming multipart uploads, and high-level wrappers for the full raw route
inventory also remain outside this release.

## Requirements

- Nim 2.2.10 or a newer 2.2 patch release
- ORC (`--mm:orc`)
- Chronos 4.2 or 4.3
- libsodium when building the optional HTTP verifier with
  `-d:cordnimSodium`

Nimble declares package dependencies. `atlas.lock` pins the development
checkouts under `deps/`.

## Run an HTTP interaction app

The example reads the Discord application public key from the environment,
binds `/interactions` on port 8080, and lets the app own startup and shutdown.

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

`newInteractionHttpRuntime` accepts only `webhookOnly` app configurations. A
hybrid app needs one composite lifecycle that owns both this HTTP path and its
Gateway event session.

`ctx.reply` selects the initial response. The HTTP server commits that response
after Chronos writes it to the client. Calls to `ctx.editOriginal` and
`ctx.followup` wait for the delivery receipt, so webhook requests cannot pass
the initial acknowledgement.

Handlers may keep returning `CommandResult` for result-based dispatch. Once a
handler selects a response through `CommandCtx`, the selected response owns the
wire output and the returned result becomes diagnostic data for middleware.

## Components and persistent routes

Components V2 builders validate and serialize message trees. Modal forms
return a validation result that can contain more than one problem. A
`TypedRouteCodec[T]` signs versioned, expiring `custom_id` payloads, and
`ComponentRouter` dispatches decoded actions after a restart.

Applications provide signing-key storage and durable route registration. The
0.1 package has no database adapter or collector-style route registry.

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
from the environment or a literal `.env` assignment. It parses `.env` as text.

```fish
cp .env.example .env
chmod 600 .env
```

## Development

Replay the pinned dependency graph before building a fresh checkout:

```fish
atlas --noexec rep atlas.lock
nimble check
nimble apiCheck
nimble test
nimble schemaCheck
nimble docs
```

See [docs/architecture.md](docs/architecture.md) for ownership boundaries and
[docs/security.md](docs/security.md) for verification, delivery, retry, and
credential rules.
