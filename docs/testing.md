# Testing Cordnim applications

`cordnim/testing` supplies deterministic application, REST, Gateway, clock,
entropy, cassette, and teardown helpers. These helpers use the same public
runtime boundaries as production code; they do not open Discord connections.

## Keep build output outside a small tmpfs

The aggregate runner compiles each `tests/t*.nim` file independently. Its
default cache and executable root is the ignored `build/test-leaves` directory,
not `/tmp`. Override it when another persistent volume is more appropriate:

```fish
mkdir -p $HOME/.cache/cordnim-test-build
set -lx CORDNIM_TEST_BUILD_DIR $HOME/.cache/cordnim-test-build
nimble test
```

Set `TMPDIR` as well when the compiler or a native dependency uses a small
system temporary directory for work outside the configured Nim cache.

For one file, keep both the Nim cache and executable on persistent storage:

```fish
set name tapi_channels
mkdir -p $HOME/.cache/cordnim-build/$name
nim c -r --mm:orc --path:src \
  --nimcache:$HOME/.cache/cordnim-build/$name/cache \
  --out:$HOME/.cache/cordnim-build/$name/$name tests/$name.nim
```

## Scripted REST

`ScriptedRestTransport` consumes an ordered list of expected requests. A matcher
can pin the route, auth requirement, headers, body kind, body JSON, or rendered
path. The transport records a sanitized copy for later assertions.

```nim
import chronos

import cordnim/api/channels
import cordnim/rest
import cordnim/testing

let scripted = newScriptedRestTransport()
scripted.expectRequest(
  transportResponse(204),
  matchRoute("POST /channels/{channel_id}/typing")
)

let client = newChronosRestClient(scripted.asRestTransport())
client.start()
waitFor client.triggerTyping(ChannelId.parseId("42"))
waitFor client.stop()

doAssert scripted.observedRequests()[0].authRequirement == darBot
scripted.assertSatisfied()
```

Observed webhook paths, authorization headers, and recognized secret JSON keys
are redacted. Returned observations are owned copies, so mutating one cannot
change the transport's retained record. Register application-specific secret
values with `withSecretValues` when they may appear inside otherwise ordinary
text.

## Scripted Gateway

`ScriptedGatewayTransport` supplies HELLO, dispatch, reconnect, close, and
transport-failure steps without a WebSocket. Use it to test IDENTIFY/RESUME,
heartbeats, close policy, bounded queue behavior, and shutdown. The scripted
driver records sanitized outbound payloads and close information.

Gateway payload fixtures should be complete enough for the decoder under test.
Use the semantic model tests for field/nullability failures and the runner tests
for ownership or reconnect behavior; combining both in one large fixture makes
failures harder to locate.

## Application harness and time

`AppHarness` dispatches commands through a real `DiscordApp` with deterministic
services and records invocations. `FakeClock` advances only when the test asks;
it is suitable for deadlines, cooldowns, route expiry, and retry timing. Use the
runtime's monotonic clock abstraction for request deadlines and the injected
Unix-seconds clock for signed identifiers that survive a restart.

Do not use wall-clock sleeps to test acknowledgement, heartbeat, bucket reset,
or collector behavior. A passing sleep-based test can still hide an ownership
race on a slower CI runner.

## Cassettes and fixtures

Cassettes store canonical, redacted request/response observations. They are test
inputs, not a credential vault. Keep raw Discord payloads, interaction tokens,
authorization headers, and user OAuth access tokens out of committed fixtures.
The cassette loader rejects unsupported versions and non-redacted secret fields.

Prefer small fixture constructors for strict semantic responses. A test should
state whether it exercises the context-neutral decoder or an endpoint-specific
`decodeXResponse` contract.

## Verification levels

Use the smallest check that covers the change, then run the aggregate gates:

```fish
nimble apiCheck
nimble schemaCheck
nimble test
nimble docs
```

Protocol and ownership changes should also run focused tests under release and
danger optimization. Sanitizer fuzz targets cover interaction verification,
signed component routes, and generated raw parsers; see `.github/workflows/fuzz.yml`
for the bounded CI invocation.
