# Operating Cordnim applications

Cordnim runtime objects have explicit owners. Construct them on one Chronos
event loop, attach the required components before starting `DiscordApp`, and let
the application close those components in reverse attachment order.

## Build identity

The Nimble package version is a packaging placeholder until a release version is
assigned. Runtime diagnostics use `CordnimBuildLabel`, whose default value is
`development`.

Set a deployment label at compile time:

```fish
nim c --mm:orc -d:CordnimBuildLabel=2026-07-12.1 src/bot.nim
```

The label appears in the embedded HTTP server identity and the Discord REST
User-Agent. It is not an API compatibility promise and it does not identify the
pinned Discord schema. Record `discordSchemaRevision` separately when a process
persists raw payloads or reports a protocol problem.

## Dependency checkout

`atlas.lock` records the development dependency commits and the generated Atlas
section of `nim.cfg`. Reproduce an existing lock without running dependency
build hooks:

```fish
atlas --noexec rep atlas.lock
```

After changing `cordnim.nimble`, resolve the manifest and refresh the lock:

```fish
atlas --noexec install
atlas pin atlas.lock
atlas changed atlas.lock
```

Review the resulting `atlas.lock` and `nim.cfg` changes. Do not edit either file
to manufacture a dependency state that Atlas did not resolve.

## Lifecycle ownership

`newDiscordApp` starts in `alsReady`. Runtime factories attach complete
start/wait/close triples while the app remains ready. `run` starts them in
attachment order and always runs shutdown after a successful start. `close`
cancels and joins retained work, then closes components in reverse order.

The HTTP interaction runtime owns its listener, dispatcher, webhook REST
scheduler, and HTTP connection pool. It closes them in that order. A Gateway
runtime owns every shard runner; each runner owns its transport, compression
context, identify lease, heartbeat work, and bounded dispatch runtime.

Do not close an underlying transport directly while its scheduler, dispatcher,
or shard runner can still use it. Prefer the top-level owner's `close` operation
and wait for it to finish.

## Event-loop confinement

The application, interaction dispatcher, REST scheduler, Gateway runtime,
caches, and collectors are designed for one Chronos event loop. Their public
types do not add cross-thread locking. Passing one of these objects to another
OS thread requires an application-owned synchronization boundary.

Long-running command, component, modal, autocomplete, and Gateway event
handlers should yield to Chronos. A blocking handler delays acknowledgement,
heartbeat, rate-limit, and shutdown work on the same loop.

## Deadlines and overload

Interaction acknowledgement uses a monotonic deadline and keeps a send margin
for the ingress adapter. Auto-defer, handler completion, and autocomplete race
against that same deadline. Once an initial response is selected, its delivery
receipt remains pending until HTTP or Gateway confirms the send.

Gateway dispatch is bounded. A shard advances its resumable sequence only after
the dispatch runtime admits the event. A full queue is an explicit overload
condition: the shard aborts the connection and attempts a resumable reconnect.
It does not drop an event or wait indefinitely in the WebSocket reader.

Shard lease TTLs are interpreted against the runner's monotonic clock. Lease
renewal, session reads, and checkpoints have deadlines within the current TTL.
Lease loss, expiry, rejected fencing operations, and ambiguous checkpoint writes
all fail closed and abort the transport. Connect, HELLO, IDENTIFY, and RESUME
also observe the abort signal. A coordination backend must therefore tolerate
cancelled RPCs and enforce the fencing token even if a cancelled request arrives
late.

REST request deadlines and Discord bucket resets use monotonic time. Persistent
component route expiry uses an injected Unix-seconds clock because the signed
identifier crosses process restarts. Tests should inject both clock classes
instead of sleeping against wall time.

## Cache and collector policy

The Gateway entity cache is selective. Enable only the entity classes required
by the application, and choose full, bounded LRU, bounded TTL, or disabled
storage for each class. Cache entries are semantic JSON snapshots, not mutable
aliases into a dispatch payload.

Collectors are short-lived, process-local queues. Closing a collector releases
its queued values and wakes waiters. A collector does not make a component route
durable; use a signed typed route when a button or modal must survive a restart.

## Diagnostics

Log stable error categories, correlation IDs, shard IDs, route templates, queue
depths, and retry counts. Do not log exception messages from application
handlers or backends. They can contain credentials or request data.

Keep these values out of diagnostics:

- bot, interaction, webhook, and route-signing secrets;
- rendered webhook paths and query strings;
- authorization, signature, and cookie headers;
- raw request, response, interaction, and Gateway payloads.

`Secret[T]`, `RawRequest.$`, interaction failure observers, and Gateway failure
metadata provide redacted defaults. Application observers must preserve that
boundary.

## Verification before publishing

Run the dependency, API, generated-schema, test, and documentation checks from
a clean dependency checkout:

```fish
atlas --noexec rep atlas.lock
nimble apiCheck
nimble schemaCheck
nimble test
nimble docs
pushd voice
nimble apiCheck
nimble docs
popd
python3 tools/check_doc_contract.py htmldocs
python3 tools/check_doc_links.py voice/htmldocs
```

The core docs task removes only `htmldocs`, runs one `nim doc --project` from
`cordnim/doc_index`, then derives required HTML pages from `publicEntries` in
`cordnim.nimble`. A new public entry therefore fails documentation generation
until its source compiles and its page exists; CI does not maintain a second
handwritten page list.

Protocol and ownership-sensitive focused tests should also pass with release
checks and danger optimizations. Keep their compiler caches and executables in a
build directory on persistent storage rather than a small tmpfs.

Release tooling must assign the public version and build label deliberately.
The current packaging placeholder must not be published as if it were a settled
compatibility version.
