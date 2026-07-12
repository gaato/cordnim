# cordnim

cordnim is a typed Discord application runtime for Nim 2.2. It compiles command
and form declarations, runs interactions over HTTP or Gateway ingress,
schedules Discord REST requests, and supervises resumable Gateway shards with
bounded dispatch and selective entity caching.

No release version has been assigned. The Nimble version is a packaging
placeholder, and breaking API changes remain allowed while the design settles.

## Package map

| Import | Purpose |
| --- | --- |
| `cordnim` | Application composition, typed IDs and secrets, commands, components, and HTTP interaction runtime |
| `cordnim/api` | Typed REST operations with endpoint-owned auth, status, and retry contracts |
| `cordnim/models` | Strict semantic Discord resources with retained unknown fields |
| `cordnim/interactions` | Shared HTTP/Gateway dispatcher, response authority, verification, and persistent routes |
| `cordnim/rest` | Chronos HTTP transport, dynamic rate-limit scheduler, replayable multipart requests, and checked errors |
| `cordnim/gateway` | Gateway v10 transport, compression, session and shard runners, coordination, dispatch, and entity cache |
| `cordnim/raw` | Generated Discord HTTP v10 models, route metadata, and the generic request escape hatch |
| `cordnim/cache` | Policy-driven cache stores and cache/REST entity resolution |
| `cordnim/observability` | Redacted logging and metric contracts |
| `cordnim/testing` | Application test harness and deterministic fake clock |

Import the lower-level modules by name. Their wire types stay out of the main
`cordnim` namespace.

The Gateway runtime owns URL construction, zlib-stream decompression, HELLO and
heartbeat processing, IDENTIFY or RESUME, reconnect policy, bounded event
dispatch, and multi-shard supervision. Distributed coordination is an
injectable lease and fencing contract; Cordnim ships a process-local adapter,
not a production Redis or etcd backend.

Voice media and high-level wrappers for the full raw HTTP route inventory remain
outside the current scope. The separate `cordnim_voice` package contains Voice
Gateway v8 and DAVE protocol state, but not UDP media transport, an Opus
pipeline, jitter buffering, or mixing.

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

`newInteractionHttpRuntime` requires HTTP interaction ingress. A hybrid app can
also enable Gateway event subscriptions and attach its Gateway runtime before
calling `app.run`; `DiscordApp` starts attached components in order and closes
them in reverse order.

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

Applications provide signing-key storage and retain old verification keys for
their planned route lifetime. Typed routes survive restart when the next process
has the same keys and migration decoder. `Collector[T]` is available for
bounded, short-lived in-process flows; it is not persistent route storage.

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
