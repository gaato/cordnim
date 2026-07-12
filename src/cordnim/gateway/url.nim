## Canonical Discord Gateway v10 WebSocket URL construction.
##
## Discord hands back two endpoints a shard must connect to: the initial Gateway
## URL (from `/gateway/bot`, supplied to the runner) and, after READY, a
## `resume_gateway_url` used for RESUME. Both must be normalized identically so a
## RESUME reaches the same session with the same wire contract as the original
## connection. This module owns that normalization and refuses unsafe shapes.
##
## The canonical form keeps the base scheme, host, optional port, and path, and
## replaces the query with exactly `v=10&encoding=json` plus an optional
## `compress=zlib-stream`. A base URL's own query is discarded so a stale `v=9`
## or a mismatched `compress` can never leak into the connection, and so the
## initial and resume URLs are byte-for-byte comparable in their query.

import std/[strutils, uri]

type
  GatewayUrlError* = object of CatchableError ## The supplied Gateway base URL is
    ## malformed or unsafe to connect to. The message names the violated rule and
    ## never embeds credentials, because rejected userinfo is dropped before the
    ## message is built.

const
  gatewayApiVersion* = "10" ## Gateway API version Cordnim speaks.
  gatewayEncoding* = "json" ## Only JSON encoding is supported.
  gatewayZlibStreamParam* = "zlib-stream" ## Transport-compression query value.

func isLoopbackHost(host: string): bool {.raises: [].} =
  ## Tests whether `host` is a loopback address that plain `ws` may target.
  ##
  ## Plain `ws` exposes the token on the wire, so it is confined to loopback while
  ## `wss` is unrestricted. The allow-set is exactly the one the WebSocket driver
  ## (`websocket_chronos`) and the REST transport enforce: `localhost`,
  ## `127.0.0.1`, and `::1`. A spoofed name like
  ## `127.evil.example`, a trailing-labelled `127.0.0.1.evil`, or any other
  ## 127.0.0.0/8 address is rejected by every transport layer.
  host.toLowerAscii() in ["localhost", "127.0.0.1", "::1", "[::1]"]

func authority(parsed: Uri): string {.raises: [].} =
  ## Renders `host[:port]`, bracketing an IPv6 literal host.
  result =
    if ':' in parsed.hostname and not parsed.hostname.startsWith("["):
      "[" & parsed.hostname & "]"
    else:
      parsed.hostname
  if parsed.port.len > 0:
    result.add ":"
    result.add parsed.port

proc buildGatewayUrl*(
    base: string; zlibStream = false): string {.raises: [GatewayUrlError].} =
  ## Returns the canonical Gateway URL for `base`, forcing v=10 and JSON.
  ##
  ## Preserves the base scheme/host/port/path; replaces the query with
  ## `v=10&encoding=json` and, when `zlibStream`, `compress=zlib-stream`. Raises
  ## `GatewayUrlError` for a non-`ws`/`wss` scheme, embedded userinfo, a fragment,
  ## a missing host, or a non-loopback plain-`ws` target.
  if base.len == 0:
    raise newException(GatewayUrlError, "gateway URL must not be empty")
  let parsed = parseUri(base)
  let scheme = parsed.scheme.toLowerAscii()
  if scheme != "ws" and scheme != "wss":
    raise newException(GatewayUrlError, "gateway URL scheme must be ws or wss")
  # Reject userinfo before any diagnostic is built so a password cannot surface
  # in an error message or a log line.
  if parsed.username.len > 0 or parsed.password.len > 0:
    raise newException(
      GatewayUrlError, "gateway URL must not contain userinfo")
  if parsed.anchor.len > 0:
    raise newException(
      GatewayUrlError, "gateway URL must not contain a fragment")
  if parsed.hostname.len == 0:
    raise newException(GatewayUrlError, "gateway URL must have a host")
  if scheme == "ws" and not isLoopbackHost(parsed.hostname):
    raise newException(
      GatewayUrlError, "plain ws is permitted only to a loopback host")

  var query = "v=" & gatewayApiVersion & "&encoding=" & gatewayEncoding
  if zlibStream:
    query.add "&compress=" & gatewayZlibStreamParam
  scheme & "://" & authority(parsed) & parsed.path & "?" & query
