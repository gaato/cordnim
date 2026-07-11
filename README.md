# cordnim

cordnim is a type-safe Discord application runtime for Nim 2.2. It keeps the
complete Discord protocol reachable through `cordnim/raw`, while the higher
layers prevent invalid interaction responses, component trees, and identifier
mix-ups before a request is sent.

The project is interaction-first. An application can receive interactions over
HTTP without opening a Gateway connection, subscribe to Gateway events without
accepting interactions there, or run both transports while keeping one command
model.

## Status

The repository is in its first alpha. Public APIs can still change.

| Area | Available now | Still on the roadmap |
| --- | --- | --- |
| Raw HTTP | 242 pinned stable operations and 538 lossless JSON-backed schemas | Rich high-level models for every resource |
| REST | Chronos HTTP/TLS, dynamic buckets, priorities, deadlines, bounded retries, checked errors | Streaming multipart transport integration |
| Interactions | Signed HTTP ingress, replay protection, shared HTTP/Gateway command routing, command auto-defer, typed response capability, persistent component router | Component auto-defer, autocomplete routing, and modal-submit orchestration |
| Commands | Typed proc compiler, option decoding, typed user/message context targets, deterministic manifest/diff/sync | Nested subcommands, localization, autocomplete transformers |
| Components | Separate Legacy/V2 types, all current message shapes, all 10 modal field kinds, signed typed persistent routes | Stored-route adapters and collector ergonomics |
| Gateway | Gateway v10 typed payload codecs plus session/resume, heartbeat, close, shard, identify, queue, and dispatch state machines | Supervised WebSocket/compression transport |
| Voice | Voice Gateway v8 codecs, DAVE state, official libdave binding | UDP/media transport, Opus pipeline, mixer, FFmpeg adapter |

Unknown protocol fields, enum values, and flag bits are retained at the raw
boundary rather than making a Discord addition a decode failure.

## Package layout

- `cordnim/raw` exposes the pinned Discord HTTP v10 schema and a generic request
  escape hatch.
- `cordnim/rest`, `cordnim/interactions`, and `cordnim/gateway` implement the
  runtime and its deadlines, rate limits, sessions, and cancellation boundaries.
- `cordnim/commands` and `cordnim/components` compile declarations into command
  manifests, dispatchers, and validated Discord UI payloads.
- `cordnim_voice` is a separate package. It binds the official `libdave` C API;
  the core package does not install native Voice dependencies.

## Requirements

- Nim 2.2.10 or a newer 2.2 patch release
- ORC (`--mm:orc`) for production builds
- Chronos 4.x as the supported async runtime

Dependencies are declared through Nimble and pinned for development with Atlas.
`atlas.lock`, `deps/atlas.config`, and the generated `nim.cfg` paths are
committed together so CI can detect dependency drift.

## First application

```nim
import chronos
import cordnim

type Services = object
  greeting: string

proc hello(ctx: CommandCtx[Services], name: string): Future[CommandResult]
    {.async, discordCommand(
      name = "hello",
      description = "Say hello",
      installs = {guildInstall, userInstall},
      contexts = {guildChannel, botDm, privateChannel},
      ack = ackAutoDefer
    ).} =
  let message = v2Message:
    container:
      text "## " & ctx.services.greeting & ", " & name
      actions:
        button "Continue", "example:continue"
  return succeededPayload(message.toJson())

let app = newDiscordApp(
  Services(greeting: "Hello"),
  initAppConfig(ingressHttp),
  commandSet(hello)
)
```

The string `custom_id` above is suitable only for a short example. Persistent
interfaces should use `TypedRouteCodec[T]` and `routedButton`, which authenticate
the route, expiry, version, and typed payload and can recover it after restart.

Use `ingressGateway` instead of `ingressHttp` when interactions arrive through
Gateway. The generated command and handler stay the same.

## Operator CLI

The executable is named `cordnim`, matching the package and avoiding a generic
`discordctl` binary name.

```fish
cordnim schema
cordnim doctor --offline
cordnim commands diff --current current.json --desired manifest.json
cordnim commands sync --manifest manifest.json --application 123 --dry-run
cordnim commands sync --manifest manifest.json --application 123 --apply --yes
```

Network command sync is a dry run unless both `--apply` and `--yes` are present.
The CLI reads `DISCORD_BOT_TOKEN` from the environment or a literal `.env`
assignment. It never executes `.env` as shell code. Keep the local file private:

```fish
cp .env.example .env
chmod 600 .env
```

## Development

With dependencies installed:

```fish
atlas --noexec rep atlas.lock
nimble test
nimble schemaCheck
nimble docs
```

Tests and doc generation use ORC. Build products belong under `build/`,
`htmldocs/`, or the system temporary directory and are ignored by Git.

See [docs/architecture.md](docs/architecture.md) for the public boundaries and
[docs/security.md](docs/security.md) for the threat model and secret-handling
defaults.
