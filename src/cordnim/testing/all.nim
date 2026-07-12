## Public deterministic testing kit for Cordnim.
##
## The kit lets tests drive real transport, Gateway, and command code without
## sockets, wall-clock time, randomness, or filesystem access:
##
## - `app_harness` records command invocations through a real `DiscordApp`.
## - `fake_clock` is a manually advanced monotonic clock (`ManualClock`).
## - `entropy` is a deterministic byte and nonce source with exhaustion checks.
## - `canonical_json` compares JSON independent of object key order.
## - redaction strips known credential fields and registered literal secrets.
## - `fixtures` builds representative interaction and Gateway payloads.
## - `scripted_rest` implements the `RestTransport` contract from a script.
## - `scripted_gateway` implements the `GatewayTransportDriver` contract.
## - `cassette` records and replays REST/Gateway traffic in a redacted form.
## - teardown checks scripts, pending receives, and REST client lifecycle.

import ./[app_harness, canonical_json, cassette, entropy, fake_clock,
  fixtures, redaction, scripted_gateway, scripted_rest, teardown]

export app_harness, canonical_json, cassette, entropy, fake_clock, fixtures,
  redaction, scripted_gateway, scripted_rest, teardown
