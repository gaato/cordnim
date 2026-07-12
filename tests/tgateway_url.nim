## Tests for canonical Gateway v10 URL construction.

import std/strutils

import cordnim/gateway/url

block forces_version_and_encoding_and_replaces_query:
  # A stale v=9 in the base must not survive normalization.
  let u = buildGatewayUrl("wss://gateway.discord.gg/?v=9&encoding=etf")
  doAssert u == "wss://gateway.discord.gg/?v=10&encoding=json"

block preserves_host_port_and_path:
  let u = buildGatewayUrl("wss://gateway.discord.gg:443/gw")
  doAssert u == "wss://gateway.discord.gg:443/gw?v=10&encoding=json"

block empty_path_is_preserved_verbatim:
  let u = buildGatewayUrl("wss://gateway.discord.gg")
  doAssert u == "wss://gateway.discord.gg?v=10&encoding=json"

block optional_zlib_stream_compression:
  let u = buildGatewayUrl("wss://gateway.discord.gg/", zlibStream = true)
  doAssert u == "wss://gateway.discord.gg/?v=10&encoding=json&compress=zlib-stream"

block initial_and_resume_urls_share_identical_query:
  # The resume URL (a different host) must carry the same query so a RESUME
  # reconnects with an identical wire contract.
  let initial = buildGatewayUrl("wss://gateway.discord.gg/", zlibStream = true)
  let resume = buildGatewayUrl(
    "wss://us-east1-b.gateway.discord.gg/", zlibStream = true)
  proc queryOf(s: string): string = s[s.find('?') .. ^1]
  doAssert queryOf(initial) == queryOf(resume)
  doAssert queryOf(resume) == "?v=10&encoding=json&compress=zlib-stream"

block plain_ws_allowed_only_to_loopback:
  doAssert buildGatewayUrl("ws://127.0.0.1:8080/").startsWith("ws://127.0.0.1:8080/")
  doAssert buildGatewayUrl("ws://localhost:9/") == "ws://localhost:9/?v=10&encoding=json"
  doAssert buildGatewayUrl("ws://[::1]:7/").startsWith("ws://[::1]:7/")
  doAssertRaises GatewayUrlError:
    discard buildGatewayUrl("ws://gateway.discord.gg/")

block ipv6_host_is_bracketed:
  let u = buildGatewayUrl("wss://[2001:db8::1]:443/")
  doAssert u == "wss://[2001:db8::1]:443/?v=10&encoding=json"

block rejects_userinfo_fragment_scheme_and_missing_host:
  doAssertRaises GatewayUrlError:
    discard buildGatewayUrl("wss://user:pass@gateway.discord.gg/")
  doAssertRaises GatewayUrlError:
    discard buildGatewayUrl("wss://gateway.discord.gg/#frag")
  doAssertRaises GatewayUrlError:
    discard buildGatewayUrl("https://gateway.discord.gg/")
  doAssertRaises GatewayUrlError:
    discard buildGatewayUrl("wss:///onlypath")
  doAssertRaises GatewayUrlError:
    discard buildGatewayUrl("")

block userinfo_password_is_not_echoed_in_the_error:
  try:
    discard buildGatewayUrl("wss://user:sup3rsecret@gateway.discord.gg/")
    doAssert false
  except GatewayUrlError as err:
    doAssert err.msg.find("sup3rsecret") == -1

block plain_ws_loopback_matches_exact_allow_set:
  # Plain ws is allowed only for the exact hosts the driver and REST accept.
  doAssert buildGatewayUrl("ws://127.0.0.1/").startsWith("ws://127.0.0.1/")
  doAssert buildGatewayUrl("ws://localhost/") == "ws://localhost/?v=10&encoding=json"
  doAssert buildGatewayUrl("ws://[::1]:7/").startsWith("ws://[::1]:7/")
  # Spoofed prefixes, trailing labels, out-of-range octets, and other
  # 127.0.0.0/8 addresses are rejected for plain ws.
  for spoof in [
      "ws://127.evil.example/", "ws://127.0.0.1.evil/", "ws://127.0.0.256/",
      "ws://127.0.0/", "ws://127.0.0.1.1/", "ws://127.0.0.99999/",
      "ws://0127.0.0.1/", "ws://localhost.evil/", "ws://126.0.0.1/",
      "ws://128.0.0.1/", "ws://127.0.0.2/", "ws://127.255.255.254/"]:
    doAssertRaises GatewayUrlError:
      discard buildGatewayUrl(spoof)

echo "tgateway_url: all blocks passed"
